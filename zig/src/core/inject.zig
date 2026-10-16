//! Context a server adds to a running reply: tokens the engine prefills between two rounds, rows the reply reads.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One reply's queue (Request.inject): the server pushes ids from any thread, the engine takes them between rounds.
pub const Inject = struct {
    io: std.Io,
    gpa: Allocator,
    /// Tokens the reply may take in: the engine holds that many cache rows past max_tokens from its admission.
    room: u32,
    mutex: std.Io.Mutex = .init,
    queued: std.ArrayList(u32) = .empty, // pushed, not yet in the reply
    pushed: u32 = 0, // tokens accepted, taken or queued: `room` bounds them
    taken: u32 = 0, // tokens the reply took in: its usage counts them as prompt tokens
    ended: bool = false, // the reply finished: pushes fail and queued tokens never go in
    ready: std.atomic.Value(bool) = .init(false), // tokens wait: the engine's check each round, without the lock

    pub const Error = error{ Ended, NoRoom, OutOfMemory };

    pub fn deinit(i: *Inject) void {
        i.queued.deinit(i.gpa);
    }

    /// Queues `tokens` for the reply's next round boundary; refused once the reply ended or past its room.
    pub fn push(i: *Inject, tokens: []const u32) Error!void {
        i.mutex.lockUncancelable(i.io);
        defer i.mutex.unlock(i.io);
        if (i.ended) return error.Ended;
        if (tokens.len > i.room - i.pushed) return error.NoRoom;
        try i.queued.appendSlice(i.gpa, tokens);
        i.pushed += @intCast(tokens.len);
        if (tokens.len > 0) i.ready.store(true, .release);
    }

    /// Whether tokens wait for the reply (any thread, no lock).
    pub fn waiting(i: *const Inject) bool {
        return i.ready.load(.acquire);
    }

    /// The engine thread: the waiting tokens appended to `out` and counted as taken.
    pub fn take(i: *Inject, a: Allocator, out: *std.ArrayList(u32)) Allocator.Error!void {
        i.mutex.lockUncancelable(i.io);
        defer i.mutex.unlock(i.io);
        try out.appendSlice(a, i.queued.items);
        i.taken += @intCast(i.queued.items.len);
        i.queued.clearRetainingCapacity();
        i.ready.store(false, .release);
    }

    /// The engine thread at the reply's end: later pushes fail, and tokens still waiting never go in.
    pub fn end(i: *Inject) void {
        i.mutex.lockUncancelable(i.io);
        defer i.mutex.unlock(i.io);
        i.ended = true;
        i.queued.clearRetainingCapacity();
        i.ready.store(false, .release);
    }

    /// Tokens the reply took in, for its usage.
    pub fn count(i: *Inject) u32 {
        i.mutex.lockUncancelable(i.io);
        defer i.mutex.unlock(i.io);
        return i.taken;
    }
};

test "pushes wait until taken, stay within the room, and fail once the reply ended" {
    const gpa = std.testing.allocator;
    var i: Inject = .{ .io = std.testing.io, .gpa = gpa, .room = 5 };
    defer i.deinit();
    try std.testing.expect(!i.waiting());
    try i.push(&.{ 7, 8 });
    try i.push(&.{9});
    try std.testing.expect(i.waiting());
    try std.testing.expectError(error.NoRoom, i.push(&.{ 1, 2, 3 }));
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try i.take(gpa, &out);
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, out.items);
    try std.testing.expect(!i.waiting());
    try std.testing.expectEqual(@as(u32, 3), i.count());
    try i.push(&.{ 4, 5 });
    i.end();
    try std.testing.expect(!i.waiting());
    try std.testing.expectEqual(@as(u32, 3), i.count());
    try std.testing.expectError(error.Ended, i.push(&.{6}));
}
