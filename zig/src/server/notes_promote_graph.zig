//! Promotion ownership is durable before fitting; split, reversed and interrupted lesson rows keep their source key.
const std = @import("std");
const np = @import("notes_promote.zig");
const promote = @import("notes/promote.zig");
const ops = @import("notes/operations.zig");
const graph = @import("slide_graph.zig");
const Out = @import("slide_stream.zig").Out;
const Allocator = std.mem.Allocator;

pub const Admission = struct {
    p: *np.Promoter,
    key: []const u8,
    text: []const u8,

    pub fn enrollment(o: *Admission) Out.Enrollment {
        return .{ .ctx = o, .record = record };
    }

    fn record(ctx: *anyopaque, a: Allocator, facts: []const []const u8, source: []const u8) ![]const u32 {
        const o: *Admission = @ptrCast(@alignCast(ctx));
        const p = o.p;
        p.srv.notes_mutex.lockUncancelable(p.io);
        defer p.srv.notes_mutex.unlock(p.io);
        if (p.stop.load(.acquire) or p.erasing.load(.acquire) or o.key.len == 0) return error.ErasePending;
        const f = p.state.find(o.key) orelse return error.SourceGone;
        if (f.erased or !std.mem.eql(u8, f.text, o.text)) return error.SourceGone;
        const notes = try ops.list(p.store, a, false);
        const live = for (notes) |n| {
            if (std.mem.eql(u8, try np.keyOf(a, n), o.key) and std.mem.eql(u8, n.text, o.text)) break true;
        } else false;
        if (!live) return error.SourceGone;
        const ids = try a.alloc(u32, facts.len);
        for (facts, ids) |text, *id| id.* = try add(&p.srv.slide, text, source, o.key, np.clockMs(p.io));
        return ids;
    }
};

/// A failed graph commit never admits engine fitting; the unused ID remains reserved in memory.
pub fn add(g: *graph.Graph, text: []const u8, source: []const u8, key: []const u8, at: i64) !u32 {
    if (key.len == 0) return error.NoLessonIdentity;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const a = g.arena.allocator();
    const f: graph.Fact = .{
        .id = g.next,
        .text = try a.dupe(u8, text),
        .source = try a.dupe(u8, source),
        .promotion_key = try a.dupe(u8, key),
        .at = at,
        .state = .queued,
    };
    try g.facts.append(g.gpa, f);
    g.next += 1;
    try g.persist();
    return f.id;
}

pub fn placedFor(p: *np.Promoter, a: Allocator, text: []const u8) ![]const promote.Neuron {
    const op = p.state.open orelse return error.NoLessonIdentity;
    if (op.source_key.len == 0 and text.len > 0) return error.LegacyLessonIdentity;
    const g = &p.srv.slide;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    var out: std.ArrayList(promote.Neuron) = .empty;
    for (g.facts.items) |f| if (std.mem.eql(u8, f.promotion_key, op.source_key)) {
        for (f.neurons) |n| if (!promote.has(out.items, n)) try out.append(a, n);
    };
    return out.items;
}

fn includes(keys: []const []const u8, key: []const u8) bool {
    for (keys) |x| if (std.mem.eql(u8, x, key)) return true;
    return false;
}

/// Bind older rows by their recorded neuron identity before retirement removes that evidence.
pub fn capture(p: *np.Promoter, keys: []const []const u8) !void {
    const g = &p.srv.slide;
    const s = &p.state;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const a = s.alloc();
    for (g.facts.items) |*row| {
        if (row.promotion_key.len == 0) {
            for (s.facts.items) |f| if (includes(keys, f.key)) {
                const overlaps = for (row.neurons) |n| {
                    if (promote.has(f.neurons, n)) break true;
                } else false;
                if (overlaps) {
                    row.promotion_key = try g.arena.allocator().dupe(u8, f.key);
                    break;
                }
            };
        }
        if (row.promotion_key.len == 0 or !includes(keys, row.promotion_key)) continue;
        if (s.find(row.promotion_key) == null) try s.facts.append(a, .{
            .key = try a.dupe(u8, row.promotion_key),
            .text = "",
            .erased = true,
            .status = .freed,
        });
        const f = s.find(row.promotion_key).?;
        var ns: std.ArrayList(promote.Neuron) = .empty;
        try ns.appendSlice(a, f.neurons);
        var pocket: std.ArrayList(promote.Neuron) = .empty;
        try pocket.appendSlice(a, s.pocket);
        for (row.neurons) |n| {
            if (!promote.has(ns.items, n)) try ns.append(a, n);
            if (!promote.has(pocket.items, n)) try pocket.append(a, n);
        }
        f.neurons = ns.items;
        s.pocket = pocket.items;
    }
    try g.persist();
}

/// Under teacher.learning, take ownership of the stopped lesson before discarding its open text.
pub fn closeInterrupted(p: *np.Promoter) !void {
    const op = p.state.open orelse return;
    if (op.teaching.len > 0 and op.source_key.len == 0) return error.LegacyLessonIdentity;
    if (op.source_key.len > 0) try capture(p, &.{op.source_key});
    p.state.open = null;
    p.state.rebuild_next = true;
}

/// Physical retirement has succeeded; remove text and all derived fields before committing graph clearance.
pub fn scrub(p: *np.Promoter, keys: []const []const u8) !void {
    const g = &p.srv.slide;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    for (g.facts.items) |*f| if (f.promotion_key.len > 0 and includes(keys, f.promotion_key)) {
        f.* = .{ .id = f.id, .text = "", .source = "chat", .at = 0, .state = .deleted, .promotion_key = f.promotion_key };
        if (g.traced == f.id) {
            g.trace.clearRetainingCapacity();
            g.cuts.clearRetainingCapacity();
            g.traced = 0;
        }
    };
    if (keys.len > 0) {
        g.talks.list.clearRetainingCapacity();
        p.srv.teacher.forgetAnswers(p.io);
    }
    try g.persist();
}

/// A committed manual graph deletion invalidates prompt exclusion until a fenced rebuild retests the note.
pub fn invalidated(p: *np.Promoter, a: Allocator, key: []const u8) void {
    if (key.len == 0 or p.state.find(key) == null) return;
    p.state.rebuild_next = true;
    p.srv.promotion_pending.store(true, .release);
    p.clearPublished();
    const codec = @import("notes/promote_json.zig");
    codec.writeFile(a, p.path, codec.encode(&p.state, a) catch return) catch {};
}

/// Recover the fence even if the process died between graph deletion and the promotion state commit.
pub fn lost(p: *np.Promoter) bool {
    const g = &p.srv.slide;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    for (g.facts.items) |row| {
        if (row.promotion_key.len == 0 or (row.state != .deleted and row.state != .deleting)) continue;
        const f = p.state.find(row.promotion_key) orelse continue;
        if (f.erased or !promote.active(f.status)) continue;
        if (row.state == .deleting or f.neurons.len == 0) return true;
        for (f.neurons) |n| {
            const live = for (g.facts.items) |other| {
                if (std.mem.eql(u8, other.promotion_key, f.key) and promote.has(other.neurons, n)) break true;
            } else false;
            if (!live) return true;
        }
    }
    return false;
}
