//! A merge off the writer's path: a new suffix-array core built on its own thread from one published version.
//! The version is immutable and held (its readers count, as a lookup holds one), so the merge reads a consistent
//! snapshot while writes go on; nothing of the writer's model is copied or read (core_build.zig).
const std = @import("std");
const index = @import("index.zig");
const core_build = @import("core_build.zig");
const Allocator = std.mem.Allocator;

/// Tests only: while set, a merge waits before it builds (so writes come in during it).
pub var hold: std.atomic.Value(bool) = .init(false);

/// One merge in flight: the version it reads, and the core it made once `done`.
pub const Job = struct {
    gpa: Allocator,
    from: *const index.Index, // the version merged: held through `readers` until finish()
    readers: *std.atomic.Value(u32),
    mark: usize, // how many retired places the store had listed then: the ones after it are the new core's
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    result: ?*index.Index = null,

    /// Starts a merge of version `v` (a layered one), held by one reader taken here. O(1) for the caller.
    pub fn start(gpa: Allocator, v: anytype, mark: usize) !*Job {
        const j = try gpa.create(Job);
        errdefer gpa.destroy(j);
        _ = v.readers.fetchAdd(1, .acquire);
        errdefer _ = v.readers.fetchSub(1, .release);
        j.* = .{ .gpa = gpa, .from = v.idx, .readers = &v.readers, .mark = mark };
        j.thread = try std.Thread.spawn(.{}, run, .{j});
        return j;
    }

    fn run(j: *Job) void {
        while (hold.load(.acquire)) std.atomic.spinLoopHint();
        j.result = core_build.fromVersion(j.gpa, j.from) catch null; // null: the next merge starts again
        j.done.store(true, .release);
    }

    pub fn ready(j: *const Job) bool {
        return j.done.load(.acquire);
    }

    /// Waits for the merge, lets its version go and frees the job; the core it made (the caller's reference), or null.
    pub fn finish(j: *Job) ?*index.Index {
        j.thread.join();
        const r = j.result;
        _ = j.readers.fetchSub(1, .release);
        j.gpa.destroy(j);
        return r;
    }
};
