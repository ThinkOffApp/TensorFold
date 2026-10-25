//! Durable promotion erasure: scrub text first, retire recorded neurons, then publish and release the lesson fence.
const std = @import("std");
const json = @import("json");
const promote = @import("notes/promote.zig");
const scrub = @import("notes/promote_erase.zig");
const ops = @import("notes/operations.zig");
const np = @import("notes_promote.zig");
const Backend = @import("notes_promote_backend.zig").Backend;
const Allocator = std.mem.Allocator;

pub const Result = struct {
    pending: bool = true,
    state_clear: bool = false,
    neurons_clear: bool = false,
    report_clear: bool = false,
    graph_clear: bool = false,
    facts: usize = 0,
    neurons: usize = 0,
    pairs_reset: []const []const u8 = &.{},
    failed: ?[]const u8 = null,

    pub fn value(r: Result, a: Allocator) !json.Value {
        const o = try json.newObject(a);
        try o.put(a, "pending", .{ .bool = r.pending });
        try o.put(a, "facts", try json.intValue(a, r.facts));
        try o.put(a, "zeroed", try json.intValue(a, r.neurons));
        const pairs = try a.alloc(json.Value, r.pairs_reset.len);
        for (pairs, r.pairs_reset) |*v, key| v.* = .{ .string = key };
        try o.put(a, "pairs_reset", .{ .array = pairs });
        if (r.failed) |why| try o.put(a, "failed", .{ .string = why });
        return .{ .object = o };
    }
};

/// HTTP holds notes_mutex already; a busy learner leaves the persisted Notes erase intent for retry.
pub fn erased(p: *np.Promoter, a: Allocator, sources: []const []const u8) Result {
    p.srv.promotion_pending.store(true, .release);
    p.erasing.store(true, .release);
    p.clearPublished();
    if (!p.srv.teacher.learning.tryLock()) {
        return .{ .failed = "the learner is busy; promotion cleanup will retry before new lessons" };
    }
    defer p.srv.teacher.learning.unlock(p.io);
    const rest = missingHeld(p, a) catch return .{ .failed = "promotion cleanup could not list pending sources" };
    var all: std.ArrayList([]const u8) = .empty;
    all.appendSlice(a, sources) catch return .{ .failed = "out of memory preparing promotion erasure" };
    for (rest) |key| {
        var seen = false;
        for (all.items) |old| seen = seen or std.mem.eql(u8, old, key);
        if (!seen) all.append(a, key) catch return .{ .failed = "out of memory preparing promotion erasure" };
    }
    return clean(p, a, all.items, true);
}

/// Called under teacher.learning; the Notes snapshot is copied before any engine operation.
pub fn drain(p: *np.Promoter) bool {
    var arena = std.heap.ArenaAllocator.init(p.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = pendingSources(p, a) catch {
        p.srv.promotion_pending.store(true, .release);
        return false;
    };
    if (sources.len == 0 and !p.erasing.load(.acquire)) {
        if (p.state.open != null or p.rewind_pending) return false;
        if (p.publish_pending.load(.acquire) and !p.tryPublish()) return false;
        return p.acknowledge();
    }
    return !clean(p, a, sources, false).pending;
}

pub fn pendingSources(p: *np.Promoter, a: Allocator) ![]const []const u8 {
    p.srv.notes_mutex.lockUncancelable(p.io);
    defer p.srv.notes_mutex.unlock(p.io);
    return missingHeld(p, a);
}

fn missingHeld(p: *np.Promoter, a: Allocator) ![]const []const u8 {
    const listed = try ops.list(p.store, a, true);
    var held: std.StringHashMapUnmanaged(void) = .empty;
    for (listed) |v| try held.put(a, try np.keyOf(a, v), {});
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    if (p.store.journal) |j| for (j.erases.items) |intent| for (intent.removed) |key| try unique.put(a, key, {});
    for (p.state.facts.items) |f| {
        if ((!held.contains(f.key) and !f.erased) or (f.erased and f.neurons.len > 0)) try unique.put(a, f.key, {});
    }
    var keys: std.ArrayList([]const u8) = .empty;
    var it = unique.keyIterator();
    while (it.next()) |key| try keys.append(a, try a.dupe(u8, key.*));
    return keys.items;
}

fn clean(p: *np.Promoter, a: Allocator, sources: []const []const u8, notes_held: bool) Result {
    var out: Result = .{};
    p.srv.promotion_pending.store(true, .release);
    p.clearPublished();
    defer if (out.pending) p.srv.promotion_pending.store(true, .release);
    if (p.rewind_pending) {
        out.failed = "the interrupted night must finish its retained rewind before erasure";
        return out;
    }
    @import("notes_promote_graph.zig").closeInterrupted(p) catch {
        out.failed = "the interrupted lesson has no durable source identity; promotion cleanup remains pending";
        return out;
    };
    @import("notes_promote_graph.zig").capture(p, sources) catch {
        out.failed = "promotion graph ownership could not be committed; retry the same erase";
        return out;
    };
    for (p.state.facts.items) |f| for (sources) |key| if (std.mem.eql(u8, f.key, key)) {
        out.facts += 1;
        break;
    };
    const copied = scrub.start(&p.state, a, sources) catch {
        out.failed = "promotion metadata could not be scrubbed; retry the same erase";
        return out;
    };
    out.pairs_reset = copied.pairs_reset;
    out.neurons = copied.neurons.len;
    var b: Backend = .{ .p = p, .arena = a, .cleanup = true };
    b.persist(&p.state) catch {
        out.failed = "scrubbed promotion metadata could not be committed; retry the same erase";
        return out;
    };
    out.state_clear = true;
    @import("notes_promote_logs.zig").purge(a, p.io, p.store.snapshot_path orelse "") catch {
        out.failed = "the promotion probe log could not be purged; retry the same erase";
        return out;
    };
    if (notes_held) p.srv.notes_mutex.unlock(p.io);
    defer if (notes_held) p.srv.notes_mutex.lockUncancelable(p.io);
    if (copied.neurons.len > 0) b.retire(a, copied.neurons) catch {
        out.failed = "promotion neurons could not be zeroed and saved; retry the same erase";
        return out;
    };
    out.neurons_clear = true;
    @import("notes_promote_graph.zig").scrub(p, sources) catch {
        out.failed = "promotion graph text could not be removed and saved; retry the same erase";
        return out;
    };
    out.graph_clear = @import("notes_promote_graph.zig").clearScope(p);
    scrub.finished(&p.state, sources) catch {
        out.failed = "promotion retirement could not be recorded; retry the same erase";
        return out;
    };
    b.persist(&p.state) catch {
        out.failed = "retired promotion addresses could not be committed; new lessons remain blocked";
        return out;
    };
    p.srv.notes_mutex.lockUncancelable(p.io);
    defer p.srv.notes_mutex.unlock(p.io);
    if (p.store.journal) |j| for (j.erases.items) |intent| for (intent.removed) |key| {
        if (p.state.find(key)) |f| if (!f.erased or f.neurons.len > 0) {
            out.failed = "another note was erased while cleanup ran; retry promotion cleanup";
            return out;
        };
    };
    p.erasing.store(false, .release);
    out.report_clear = p.tryPublish();
    if (!out.report_clear) {
        out.failed = "the promotion report could not be published; retry the same erase";
        return out;
    }
    out.pending = false;
    if (!p.state.rebuild_next and !p.rewind_pending) _ = p.acknowledgeHeld();
    return out;
}
