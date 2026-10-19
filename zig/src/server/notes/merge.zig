//! A merge off the writer's path: a new suffix-array core built on its own thread from one published version.
//! The version is immutable and its index held (a reference, as a layered version holds its core), so the merge
//! reads a consistent snapshot while writes go on; nothing of the writer's model is copied or read
//! (core_build.zig). The version itself is not held: the lines it replaced may go with it as usual, since the new
//! core keeps only their slices for places retired since, which the versions on it read from their own overrides.
const std = @import("std");
const index = @import("index.zig");
const core_build = @import("core_build.zig");
const Allocator = std.mem.Allocator;

/// Tests only: while set, a merge waits before it builds (so writes come in during it).
pub var hold: std.atomic.Value(bool) = .init(false);

/// One merge in flight: the version it reads, and the core it made once `done`.
pub const Job = struct {
    gpa: Allocator,
    from: *index.Index, // the version's index, retained until finish()
    mark: usize, // how many retired places the store had listed then: the ones after it are the new core's
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    result: ?*index.Index = null,

    /// Starts a merge of version `v` (a layered one), its index retained here. O(1) for the caller.
    pub fn start(gpa: Allocator, v: anytype, mark: usize) !*Job {
        const j = try gpa.create(Job);
        errdefer gpa.destroy(j);
        j.* = .{ .gpa = gpa, .from = v.idx.retain(), .mark = mark };
        errdefer j.from.deinit();
        j.thread = try std.Thread.spawn(.{}, run, .{j});
        return j;
    }

    fn run(j: *Job) void {
        while (hold.load(.acquire) and !j.cancelled.load(.acquire)) std.Thread.yield() catch {};
        if (!j.cancelled.load(.acquire)) j.result = core_build.fromVersionCancellable(j.gpa, j.from, &j.cancelled) catch null;
        j.done.store(true, .release);
    }

    pub fn ready(j: *const Job) bool {
        return j.done.load(.acquire);
    }

    pub fn cancel(j: *Job) void {
        j.cancelled.store(true, .release);
    }

    /// Waits for the merge, lets its version go and frees the job; the core it made (the caller's reference), or null.
    pub fn finish(j: *Job) ?*index.Index {
        j.thread.join();
        const r = j.result;
        j.from.deinit();
        j.gpa.destroy(j);
        return r;
    }
};
