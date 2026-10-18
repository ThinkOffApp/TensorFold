//! Bounded writes (docs/NOTES-WRITE-ERASE-DESIGN.md, Gate 1): a version is a core (a full suffix-array index,
//! shared by reference count) plus a delta of the notes written since it (layer.zig). A delta past the soft limit
//! (Store.side_max) starts a merge on its own thread (merge.zig: the suffix arrays merged linearly, sa.merge); the
//! writes go on against the old core meanwhile. Past the hard limit a write waits for that merge (back-pressure):
//! the only place a write waits for merge work. The journal is untouched: everything here is derived state.
const std = @import("std");
const index = @import("index.zig");
const layer = @import("layer.zig");
const merge_mod = @import("merge.zig");
const alias = @import("alias.zig");
const clock = @import("../clock.zig");

/// A merge's core, not yet read by any version, and how many retired places were listed when the merge began.
const Pending = struct { core: *index.Index, mark: usize };

/// The store's part of it (Store.bw), written under the writer's lock only.
pub const Writes = struct {
    core_retired: std.ArrayList(u32) = .empty, // places retired since the current core was built
    background_merge: bool = true, // a merge past side_max runs on its own thread while writes go on
    merging: ?*merge_mod.Job = null, // that merge
    pending: ?Pending = null, // the core it made, until a write's version is layered on it
    hard_max: ?u32 = null, // past this many notes since the core, a write waits for the merge (null: hardLimit's)
    waits: u64 = 0, // writes that waited at the hard limit, and their wait in all
    wait_ns: u64 = 0,
    alias_memo: alias.Memo = .{}, // the name facts' encoded aliases, kept between versions

    pub fn deinit(w: *Writes, s: anytype) void {
        w.stop();
        w.core_retired.deinit(s.gpa);
        w.alias_memo.deinit(s.gpa);
    }

    /// The hard limit: 4 times the soft one, and at least 1,024 notes past it.
    pub fn hardLimit(w: *const Writes, side_max: u32) usize {
        return w.hard_max orelse 4 * @as(usize, side_max) + 1024;
    }

    /// Waits for a merge in flight and drops what it made (an erase, an on-demand merge, the store's end).
    pub fn stop(w: *Writes) void {
        if (w.merging) |j| {
            if (j.finish()) |c| c.deinit();
            w.merging = null;
        }
        if (w.pending) |p| p.core.deinit();
        w.pending = null;
    }
};

/// A version for a write that retires the places in `gone` (applied to the model, not yet in core_retired).
pub fn build(s: anytype, gone: []const u32) !*@TypeOf(s.*.current.*) {
    const w = &s.bw;
    if (s.kind == .sa) {
        if (w.merging) |j| if (j.ready()) {
            w.merging = null;
            const mark = j.mark;
            if (j.finish()) |c| w.pending = .{ .core = c, .mark = mark };
        };
        if (w.pending) |p| { // the merge's core, with what was retired after it began
            const retired = try std.mem.concat(s.gpa, u32, &.{ w.core_retired.items[p.mark..], gone });
            defer s.gpa.free(retired);
            if (try layer.build(s.gpa, s.model, p.core, retired)) |idx| return wrap(s, idx);
        }
        const cur = s.current.idx;
        const core = cur.layer.core orelse cur; // a full suffix-array index is its own core
        const side = s.model.notes.items.len -| core.notes();
        const room: usize = if (w.background_merge) w.hardLimit(s.side_max) else s.side_max; // past it: wait, or merge here
        if (side > room) if (w.merging) |j| { // back-pressure: writes outpaced merges; this one waits for it
            w.merging = null;
            const mark = j.mark; // finish() frees the job
            const t0 = clock.nowNs(s.io);
            const c = j.finish();
            w.wait_ns += @intCast(clock.nowNs(s.io) - t0);
            w.waits += 1;
            if (c) |x| {
                w.pending = .{ .core = x, .mark = mark };
                return build(s, gone);
            }
        };
        if (side <= room) {
            const retired = try std.mem.concat(s.gpa, u32, &.{ w.core_retired.items, gone });
            defer s.gpa.free(retired);
            if (try layer.build(s.gpa, s.model, core, retired)) |idx| return wrap(s, idx);
        }
    }
    return full(s);
}

/// A full build: every note in the index's own columns (sa: a new core, its suffix arrays merged from the current
/// core's; places move only in an erase, whose own build replaces the current core).
pub fn full(s: anytype) !*@TypeOf(s.*.current.*) {
    const cur = s.current.idx;
    const prev = if (s.kind == .sa) (cur.layer.core orelse cur).base else null;
    const idx = try index.Index.buildMerging(s.gpa, s.model, s.kind, prev);
    if (s.kind == .sa) s.merges += 1;
    return wrap(s, idx);
}

fn wrap(s: anytype, idx: *index.Index) !*@TypeOf(s.*.current.*) {
    errdefer idx.deinit();
    try alias.populateMemo(idx, s.model, s.text, &s.bw.alias_memo);
    const v = try s.gpa.create(@TypeOf(s.*.current.*));
    v.* = .{ .idx = idx };
    idx.ver = s.next_ver;
    return v;
}

/// After a version is swapped in: the places it retired join core_retired while it is layered on the same core.
pub fn settle(s: anytype, v: anytype, gone: []const u32) void {
    const w = &s.bw;
    const core = v.idx.layer.core;
    if (w.pending) |p| if (core == null or core == p.core) { // the merge's core is in use now (or a full build)
        const after = w.core_retired.items[p.mark..];
        std.mem.copyForwards(u32, w.core_retired.items[0..after.len], after);
        w.core_retired.shrinkRetainingCapacity(after.len);
        p.core.deinit(); // the store's reference; the versions layered on it hold theirs
        w.pending = null;
        s.merges += 1;
    };
    if (core == null) {
        w.core_retired.clearRetainingCapacity();
        return;
    }
    w.core_retired.appendSliceAssumeCapacity(gone); // room reserved before the write was stored
}

/// After a write: a merge starts on its own thread once the delta passes side_max (none is running).
pub fn maybeMerge(s: anytype) void {
    const w = &s.bw;
    if (s.kind != .sa or !w.background_merge or w.merging != null or w.pending != null) return;
    const cur = s.current.idx;
    const core = cur.layer.core orelse cur;
    if (s.model.notes.items.len -| core.notes() <= s.side_max) return;
    w.merging = merge_mod.Job.start(s.gpa, s.model, w.core_retired.items.len, core.base) catch null; // else the next write
}
