//! A pocket kept whole at a mark and put back by a rewind: a refused night leaves nothing of itself in it.
const std = @import("std");

/// The lists a mark copies: the weights and counts, every neuron's record, the last fact's and last retire's copies.
const lists = .{ "up", "down", "used", "learned", "taken", "refits", "refit_up", "joint", "joint_down", "retired_lessons", "retired", "retired_w" };

/// The values it keeps: the last fact's lesson, where its undo goes back to, the last retire's mark, its check.
const values = .{ "lesson", "learned_before", "pos_before", "retired_marks", "back", "phase" };

/// What a mark keeps of pocket P: its lists and values in a copy; its rows (only ever added to) as a count and hash.
pub fn Kept(comptime P: type) type {
    return struct { copy: P, rows: usize, hash: u64 };
}

/// The pocket as it is now, copied on the host (read from the shards first if not yet); an earlier mark goes.
pub fn mark(p: anytype, t: anytype, host: anytype) !void {
    try p.load(t, host);
    const kept = try p.gpa.create(Kept(@TypeOf(p.*)));
    kept.* = .{ .copy = .{ .gpa = p.gpa, .mode = p.mode }, .rows = p.pos.items.len, .hash = hash(p.pos.items) };
    errdefer free(p.gpa, kept);
    inline for (lists) |f| try @field(kept.copy, f).appendSlice(p.gpa, @field(p, f).items);
    inline for (values) |f| @field(kept.copy, f) = @field(p, f);
    drop(p);
    p.marked = kept;
    std.log.info("slide pocket: marked with {d} neurons in use, kept on the host to put back", .{inUse(p)});
}

/// The mark's pocket written to the shards first (once a save wrote them), then put back and uploaded; the mark goes.
pub fn rewind(p: anytype, t: anytype, host: anytype) !void {
    const kept = p.marked orelse return error.NothingToRewind;
    // rows are only ever added past a mark; the ones before it are checked, never copied
    if (p.pos.items.len < kept.rows or hash(p.pos.items[0..kept.rows]) != kept.hash) return error.RowsChangedSinceMark;
    inline for (lists) |f| try @field(p, f).ensureTotalCapacity(p.gpa, @field(kept.copy, f).items.len);
    // a write that fails changes nothing: the night's pocket, its places and the mark stay, as the files still hold it
    if (p.written) _ = try host.pocketSave(p.moe.items, @import("pocket.zig").neurons, kept.copy.up.items, kept.copy.down.items);
    inline for (lists) |f| {
        @field(p, f).clearRetainingCapacity();
        @field(p, f).appendSliceAssumeCapacity(@field(kept.copy, f).items);
    }
    inline for (values) |f| @field(p, f) = @field(kept.copy, f);
    p.pos.shrinkRetainingCapacity(kept.rows);
    for (0..p.moe.items.len) |j| try p.upload(t, host, j);
    std.log.info("slide pocket: rewound to the mark: {d} neurons in use, every slot uploaded", .{inUse(p)});
    drop(p);
}

/// The mark let go, if there is one.
pub fn drop(p: anytype) void {
    const kept = p.marked orelse return;
    free(p.gpa, kept);
    p.marked = null;
}

fn free(gpa: std.mem.Allocator, kept: anytype) void {
    kept.copy.deinit();
    gpa.destroy(kept);
}

fn hash(rows: []const u16) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(rows));
}

fn inUse(p: anytype) usize {
    var n: usize = 0;
    for (p.used.items) |u| n += u;
    return n;
}
