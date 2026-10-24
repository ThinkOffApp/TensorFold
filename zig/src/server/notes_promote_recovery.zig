//! Settle controls and metadata without LLM questions; a future rebuild does not itself fence manual learning.
const np = @import("notes_promote.zig");
const promote = @import("notes/promote.zig");
const Backend = @import("notes_promote_backend.zig").Backend;
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn settle(p: *np.Promoter, a: Allocator, b: *Backend) !void {
    try @import("notes_promote_graph.zig").recoverOwned(p);
    try pruneDeleted(p, a, b);
    if (p.state.open) |op| {
        if (op.teaching.len > 0) {
            if (op.source_key.len == 0) return error.LegacyLessonIdentity;
            if (p.state.pocket.len > 0) try b.retire(a, p.state.pocket);
            p.state.pocket = &.{};
            for (p.state.facts.items) |*f| {
                f.neurons = &.{};
                if (promote.active(f.status)) {
                    f.status = .note;
                    f.alone = 0;
                }
            }
        }
        p.state.open = null;
        p.state.rebuild_next = true;
    }
    try b.persist(&p.state);
    if (!p.tryPublish()) return error.PublishPending;
    @import("slide_night.zig").acknowledged(p.srv);
}

/// A manual deletion freed these slots; retire and forget their stale addresses before admitting reuse.
fn pruneDeleted(p: *np.Promoter, a: Allocator, b: *Backend) !void {
    var gone: std.ArrayList(promote.Neuron) = .empty;
    const g = &p.srv.slide;
    {
        g.mutex.lockUncancelable(g.io);
        defer g.mutex.unlock(g.io);
        for (p.state.facts.items) |f| {
            const deleted = for (g.facts.items) |row| {
                if (std.mem.eql(u8, row.promotion_key, f.key) and (row.state == .deleted or row.state == .deleting)) break true;
            } else false;
            if (!deleted) continue;
            for (f.neurons) |n| {
                const live = for (g.facts.items) |row| {
                    if (row.state == .deleted or row.state == .deleting) continue;
                    if (std.mem.eql(u8, row.promotion_key, f.key) and promote.has(row.neurons, n)) break true;
                } else false;
                if (!live and !promote.has(gone.items, n)) try gone.append(a, n);
            }
        }
    }
    if (gone.items.len == 0) return;
    const sa = p.state.alloc();
    const pocket = try without(sa, p.state.pocket, gone.items);
    const facts = try sa.alloc([]const promote.Neuron, p.state.facts.items.len);
    for (p.state.facts.items, facts) |f, *ns| ns.* = try without(sa, f.neurons, gone.items);
    try b.retire(a, gone.items);
    p.state.pocket = pocket;
    for (p.state.facts.items, facts) |*f, ns| {
        if (f.neurons.len != ns.len and !f.erased) {
            f.status = .note;
            f.alone = 0;
        }
        f.neurons = ns;
    }
}

fn without(a: Allocator, old: []const promote.Neuron, gone: []const promote.Neuron) ![]const promote.Neuron {
    var keep: std.ArrayList(promote.Neuron) = .empty;
    for (old) |n| if (!promote.has(gone, n)) try keep.append(a, n);
    return keep.items;
}
