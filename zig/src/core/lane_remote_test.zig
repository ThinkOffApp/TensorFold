//! #1594 step 2b on the real lane host and a fake backend: a remote prefix is restored, never counted, dropped once.
const std = @import("std");
const lanes = @import("lanes");
const api = @import("engine_api.zig");
const pc = @import("prompt_cache.zig");
const remote = @import("lane_remote.zig");
const t = std.testing;

/// Another machine's prefill, in the fake backend's kept-state form: the prefix's own tokens.
const Peer = struct {
    at: u32,
    fail: bool = false,
    fills: u32 = 0,
    drops: std.atomic.Value(u32) = .init(0),
    kept: std.ArrayList(u32) = .empty,

    fn fill(ptr: *anyopaque, prompt: []const u32) anyerror!?remote.Filled {
        const p: *Peer = @ptrCast(@alignCast(ptr));
        p.fills += 1;
        if (p.fail) return error.LinkDown;
        p.kept.clearRetainingCapacity();
        try p.kept.appendSlice(t.allocator, prompt[0..@min(p.at, prompt.len)]);
        return .{ .saved = &p.kept, .at = p.at };
    }

    fn drop(ptr: *anyopaque, saved: pc.Saved) void {
        const p: *Peer = @ptrCast(@alignCast(ptr));
        std.debug.assert(saved == @as(pc.Saved, &p.kept));
        _ = p.drops.fetchAdd(1, .acq_rel);
    }
};

/// What the backend saw at the pass's first chunk, and what the request heard.
const Seen = struct {
    restoring: bool = false,
    at: u32 = 0,
    remote: bool = false,
    marks: usize = 0,
    hooked: bool = false,
    prefilled: ?u32 = null,
    done: std.atomic.Value(bool) = .init(false),

    fn chunk(ctx: *anyopaque, s: *lanes.Stream, n: usize) void {
        if (n != 0) return;
        const x: *Seen = @ptrCast(@alignCast(ctx));
        x.* = .{ .restoring = s.reuse.saved != null, .at = s.reuse.at, .remote = s.reuse.remote, .marks = s.reuse.marks.len, .hooked = s.reuse.hook != null };
    }

    fn event(ctx: *anyopaque, _: api.Id, ev: *const api.Event) void {
        const x: *Seen = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .prefilled => |n| x.prefilled = n,
            .finished => x.done.store(true, .release),
            else => {},
        }
    }
};

fn run(peer: *Peer, request: *const api.Request) !Seen {
    var cfg = try lanes.Config.init(t.allocator, .{}, 1, 0);
    defer cfg.deinit(t.allocator);
    var seen: Seen = .{};
    var fake: lanes.fake.Fake = .{ .gpa = t.allocator, .prefill_hook = Seen.chunk, .prefill_hook_ctx = &seen };
    defer fake.deinit();
    var clock: lanes.fake.FixedClock = .{};
    var core = lanes.Engine.init(t.allocator, &cfg, fake.backend(), clock.clock());
    defer core.deinit();
    var host = api.LaneHost.init(t.allocator, t.io, &core, .{ .lanes = 1 });
    host.remote = .{ .ptr = peer, .fill = Peer.fill, .drop = Peer.drop };
    try host.start();
    defer host.stop();
    try host.engine().submit(1, request, .{ .ctx = &seen, .event = Seen.event });
    const until = std.Io.Clock.awake.now(t.io).toNanoseconds() + 5 * std.time.ns_per_s;
    while (!seen.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(t.io).toNanoseconds() > until) return error.RemoteFixtureTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    return seen;
}

const six = [_]u32{ 11, 12, 13, 14, 15, 16 };

test "remote prefix: the stream restores it with nothing kept after it, counts none of it cached, and it is dropped once" {
    var peer: Peer = .{ .at = 4 };
    defer peer.kept.deinit(t.allocator);
    const seen = try run(&peer, &.{ .prompt = &six, .max_tokens = 2 });
    try t.expect(seen.restoring and seen.remote);
    try t.expectEqual(@as(u32, 4), seen.at);
    try t.expectEqual(@as(usize, 0), seen.marks);
    try t.expect(!seen.hooked);
    try t.expectEqual(@as(?u32, 0), seen.prefilled);
    try t.expectEqual(@as(u32, 1), peer.fills);
    try t.expectEqual(@as(u32, 1), peer.drops.load(.acquire));
}

test "remote prefix: a failed fill leaves the whole prompt to this engine, and nothing is dropped" {
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    var peer: Peer = .{ .at = 4, .fail = true };
    defer peer.kept.deinit(t.allocator);
    const seen = try run(&peer, &.{ .prompt = &six, .max_tokens = 2 });
    try t.expect(!seen.restoring and !seen.remote);
    try t.expectEqual(@as(u32, 1), peer.fills);
    try t.expectEqual(@as(u32, 0), peer.drops.load(.acquire));
}

test "remote prefix: one covering the whole prompt is dropped unused, and a background pass never asks" {
    var whole: Peer = .{ .at = 6 };
    defer whole.kept.deinit(t.allocator);
    const seen = try run(&whole, &.{ .prompt = &six, .max_tokens = 2 });
    try t.expect(!seen.restoring and !seen.remote);
    try t.expectEqual(@as(u32, 1), whole.drops.load(.acquire));
    var quiet: Peer = .{ .at = 4 };
    defer quiet.kept.deinit(t.allocator);
    _ = try run(&quiet, &.{ .prompt = &six, .max_tokens = 0, .background = true });
    try t.expectEqual(@as(u32, 0), quiet.fills);
}
