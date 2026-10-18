//! Context injected through a lane host: the client hears the reply's own tokens, and a lone driver hands over for it.
const std = @import("std");
const lanes = @import("lanes");
const api = @import("engine_api.zig");
const LaneHost = @import("lane_host.zig").LaneHost;
const Reason = api.Reason;
const Id = api.Id;
const Event = api.Event;
const Request = api.Request;

const gpa = std.testing.allocator;
const extra = [_]u32{ 93, 17, 94, 33, 95, 61, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24 }; // wider than a window
const prompt = [_]u32{ 2, 7, 1, 8, 2, 8, 1, 8, 2, 8, 4, 5, 9 };

/// Collects the delivered tokens; the first delivery pushes `extra`, as a server thread would mid-reply.
const Box = struct {
    inject: *api.Inject,
    mutex: std.Io.Mutex = .init,
    tokens: std.ArrayList(u32) = .empty,
    at: ?usize = null, // tokens delivered when `extra` was pushed
    done: ?Reason = null,

    fn event(ctx: *anyopaque, _: Id, e: *const Event) void {
        const b: *Box = @ptrCast(@alignCast(ctx));
        b.mutex.lockUncancelable(std.testing.io);
        defer b.mutex.unlock(std.testing.io);
        switch (e.*) {
            .tokens => |t| {
                b.tokens.appendSlice(gpa, t) catch {};
                if (b.at == null) {
                    b.inject.push(&extra) catch {};
                    b.at = b.tokens.items.len;
                }
            },
            .finished => |f| b.done = f.reason,
            else => {},
        }
    }

    fn wait(b: *Box) Reason {
        while (true) {
            b.mutex.lockUncancelable(std.testing.io);
            const d = b.done;
            b.mutex.unlock(std.testing.io);
            if (d) |r| return r;
            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        }
    }
};

/// One token a step through the fake target, handing the stream to the lane core when `yield` asks (a GPU round's way).
const Lone = struct {
    be: lanes.backend.Backend,
    handed: u32 = 0,
    resumed: u32 = 0,

    fn run(ctx: *anyopaque, s: *lanes.Stream, hooks: api.LoneHooks) anyerror!bool {
        const l: *Lone = @ptrCast(@alignCast(ctx));
        if (hooks.resumed) l.resumed += 1 else {
            _ = try l.be.opening(gpa, s);
            hooks.committed(hooks.ctx);
        }
        while (!s.finished) {
            const pending = s.context.items[s.context.items.len - 1];
            if (hooks.yield(hooks.ctx)) {
                s.pending = pending;
                s.cache_len = s.context.items.len - 1; // the cache holds everything before the pending token
                l.handed += 1;
                return true;
            }
            const t = try l.be.read(try l.be.queue(s, .{ .value = pending }, s.context.items.len));
            _ = try s.commit(gpa, &.{t}, &.{});
            hooks.committed(hooks.ctx);
        }
        l.be.release(s);
        return false;
    }
};

/// Serves one request whose first delivery pushes `extra`; the delivered tokens are the target's with it read.
fn serve(lone: ?*Lone, resumes: bool, drafts: bool) !void {
    var costs: [16]lanes.config.Cost = undefined;
    for (&costs, 1..) |*c, w| c.* = .{ .width = @intCast(w), .ms = 5.0 + 0.8 * @as(f64, @floatFromInt(w)) };
    var cfg = try lanes.Config.init(gpa, .{ .exact_width = 16, .gpu_tokens = true, .mtp = true, .speculate = true, .speculate_early = false, .drafts = 4, .window_costs = &costs, .mtp_step_ms = 0.5, .hidden_rows = true, .batch_rows = 32, .max_streams = 8, .draft_streams = true }, 16, 15);
    defer cfg.deinit(gpa);
    var target: lanes.fake.Fake = .{ .gpa = gpa };
    defer target.deinit();
    var clock: lanes.fake.FixedClock = .{};
    var core = lanes.Engine.init(gpa, &cfg, target.backend(), clock.clock());
    defer core.deinit();
    var host = LaneHost.init(gpa, std.testing.io, &core, .{ .lanes = 2, .inject = true });
    try std.testing.expect(host.engine().info().inject);
    if (lone) |l| {
        l.be = target.backend();
        host.lone = .{ .ctx = l, .run = Lone.run, .resumes = resumes };
    }
    try host.start();
    defer host.stop();
    var inject: api.Inject = .{ .io = std.testing.io, .gpa = gpa, .room = extra.len };
    defer inject.deinit();
    const request: Request = .{ .prompt = &prompt, .max_tokens = 30, .drafts = drafts, .inject = &inject };
    var box: Box = .{ .inject = &inject };
    defer box.tokens.deinit(gpa);
    try host.engine().submit(1, &request, .{ .ctx = &box, .event = Box.event });
    const reason = box.wait();
    const at = box.at.? + @intFromBool(!drafts); // a plain stream's queued step lands before `extra`
    var history: std.ArrayList(u32) = .empty;
    defer history.deinit(gpa);
    try history.appendSlice(gpa, &prompt);
    for (box.tokens.items, 0..) |t, i| {
        if (i == at) try history.appendSlice(gpa, &extra);
        try std.testing.expectEqual(lanes.fake.next(history.items, null, history.items.len), t);
        try history.append(gpa, t);
    }
    try std.testing.expect(box.tokens.items.len > at); // the reply went on past `extra`
    if (reason == .length) try std.testing.expectEqual(@as(usize, 30), box.tokens.items.len);
    try std.testing.expectEqual(@as(u32, extra.len), inject.count());
    const where = try inject.where(gpa); // the reply's own tokens before the context: a client rebuilds the turn
    defer gpa.free(where);
    try std.testing.expectEqualSlices(api.Inject.Point, &.{.{ .at = @intCast(at), .tokens = extra.len }}, where);
    try std.testing.expectEqual(@as(usize, 1), target.extend_count);
    try std.testing.expectError(error.Ended, inject.push(&extra));
    try std.testing.expectEqual(@as(usize, 0), target.lanes.count());
}

test "a host opts in only over a backend with an extend pass" {
    var costs: [16]lanes.config.Cost = undefined;
    for (&costs, 1..) |*c, w| c.* = .{ .width = @intCast(w), .ms = 5.0 + 0.8 * @as(f64, @floatFromInt(w)) };
    var cfg = try lanes.Config.init(gpa, .{ .exact_width = 16, .gpu_tokens = true, .window_costs = &costs }, 16, 15);
    defer cfg.deinit(gpa);
    var target: lanes.fake.Fake = .{ .gpa = gpa };
    defer target.deinit();
    var clock: lanes.fake.FixedClock = .{};
    var table = target.backend().vtable.*;
    table.extend = null;
    var core = lanes.Engine.init(gpa, &cfg, .{ .ptr = &target, .vtable = &table }, clock.clock());
    defer core.deinit();
    try std.testing.expect(!LaneHost.init(gpa, std.testing.io, &core, .{ .lanes = 1, .inject = true }).info_.inject);
    var with = lanes.Engine.init(gpa, &cfg, target.backend(), clock.clock());
    defer with.deinit();
    try std.testing.expect(LaneHost.init(gpa, std.testing.io, &with, .{ .lanes = 1, .inject = true }).info_.inject);
    try std.testing.expect(!LaneHost.init(gpa, std.testing.io, &with, .{ .lanes = 1 }).info_.inject);
}

test "the client hears the reply's own tokens, the injected context read in place and counted" {
    try serve(null, false, true);
    try serve(null, false, false);
}

test "a lone driver hands its stream to the lane core for injected context, and keeps it only if it resumes" {
    var stays: Lone = .{ .be = undefined };
    try serve(&stays, false, true);
    try std.testing.expectEqual(@as(u32, 1), stays.handed);
    try std.testing.expectEqual(@as(u32, 0), stays.resumed);
    var back: Lone = .{ .be = undefined };
    try serve(&back, true, true);
    try std.testing.expectEqual(@as(u32, 1), back.handed);
    try std.testing.expectEqual(@as(u32, 1), back.resumed);
}

/// One reply's tokens and end; with `inject`, its first delivery pushes `extra`, then the queue's allocator fails.
const Reply = struct {
    inject: ?*api.Inject = null,
    failing: ?*std.testing.FailingAllocator = null,
    fail: usize = 0, // allocations the queue makes after the push before one fails
    pushed: bool = false,
    mutex: std.Io.Mutex = .init,
    tokens: std.ArrayList(u32) = .empty,
    done: ?Reason = null,

    fn event(ctx: *anyopaque, _: Id, e: *const Event) void {
        const r: *Reply = @ptrCast(@alignCast(ctx));
        r.mutex.lockUncancelable(std.testing.io);
        defer r.mutex.unlock(std.testing.io);
        switch (e.*) {
            .tokens => |t| {
                r.tokens.appendSlice(gpa, t) catch {};
                if (r.inject) |i| if (!r.pushed) {
                    i.push(&extra) catch {};
                    r.failing.?.fail_index = r.failing.?.alloc_index + r.fail;
                    r.pushed = true;
                };
            },
            .finished => |f| r.done = f.reason,
            else => {},
        }
    }

    fn wait(r: *Reply) Reason {
        while (true) {
            r.mutex.lockUncancelable(std.testing.io);
            const d = r.done;
            r.mutex.unlock(std.testing.io);
            if (d) |x| return x;
            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        }
    }
};

test "an injection whose take runs out of memory fails its reply alone; a neighbour finishes as it would alone" {
    var failed: usize = 0;
    for (0..3) |fail| {
        var costs: [16]lanes.config.Cost = undefined;
        for (&costs, 1..) |*c, w| c.* = .{ .width = @intCast(w), .ms = 5.0 + 0.8 * @as(f64, @floatFromInt(w)) };
        var cfg = try lanes.Config.init(gpa, .{ .exact_width = 16, .gpu_tokens = true, .mtp = true, .speculate = true, .speculate_early = false, .drafts = 4, .window_costs = &costs, .mtp_step_ms = 0.5, .hidden_rows = true, .batch_rows = 32, .max_streams = 8, .draft_streams = true }, 16, 15);
        defer cfg.deinit(gpa);
        var target: lanes.fake.Fake = .{ .gpa = gpa };
        defer target.deinit();
        var clock: lanes.fake.FixedClock = .{};
        var core = lanes.Engine.init(gpa, &cfg, target.backend(), clock.clock());
        defer core.deinit();
        var host = LaneHost.init(gpa, std.testing.io, &core, .{ .lanes = 2, .inject = true });
        try host.start();
        defer host.stop();
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        var inject: api.Inject = .{ .io = std.testing.io, .gpa = failing.allocator(), .room = extra.len };
        defer inject.deinit();
        const other = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
        var neighbour: Reply = .{};
        defer neighbour.tokens.deinit(gpa);
        var injecting: Reply = .{ .inject = &inject, .failing = &failing, .fail = fail };
        defer injecting.tokens.deinit(gpa);
        const plain: Request = .{ .prompt = &other, .max_tokens = 30 };
        const taking: Request = .{ .prompt = &prompt, .max_tokens = 30, .inject = &inject };
        try host.engine().submit(1, &plain, .{ .ctx = &neighbour, .event = Reply.event });
        try host.engine().submit(2, &taking, .{ .ctx = &injecting, .event = Reply.event });
        try std.testing.expectEqual(Reason.length, neighbour.wait()); // the neighbour's reply is the one it gives alone
        var history: std.ArrayList(u32) = .empty;
        defer history.deinit(gpa);
        try history.appendSlice(gpa, &other);
        for (neighbour.tokens.items) |t| {
            try std.testing.expectEqual(lanes.fake.next(history.items, null, history.items.len), t);
            try history.append(gpa, t);
        }
        try std.testing.expectEqual(@as(usize, 30), neighbour.tokens.items.len);
        const reason = injecting.wait();
        const where = try inject.where(gpa);
        defer gpa.free(where);
        if (reason == .failed) {
            failed += 1;
            try std.testing.expectEqual(@as(usize, 0), where.len); // no point for context that never went in
        } else try std.testing.expectEqual(@as(usize, 1), where.len);
    }
    try std.testing.expect(failed > 0); // the sweep reached a failing take
}

/// A plain reply's first delivery pushes `extra` and arms the fake to fail every later read of its draws.
const Armed = struct {
    inject: *api.Inject,
    target: *lanes.fake.Fake,
    mutex: std.Io.Mutex = .init,
    tokens: std.ArrayList(u32) = .empty,
    done: ?Reason = null,

    fn event(ctx: *anyopaque, _: Id, e: *const Event) void {
        const b: *Armed = @ptrCast(@alignCast(ctx));
        b.mutex.lockUncancelable(std.testing.io);
        defer b.mutex.unlock(std.testing.io);
        switch (e.*) {
            .tokens => |t| {
                b.tokens.appendSlice(gpa, t) catch {};
                if (b.target.fail_reads.load(.acquire) == 0) {
                    b.inject.push(&extra) catch {};
                    var it = b.target.lanes.keyIterator(); // the lane thread delivers: its one stream is this reply's
                    b.target.fail_reads.store(@intFromPtr(it.next().?.*), .release);
                }
            },
            .finished => |f| b.done = f.reason,
            else => {},
        }
    }
};

test "a settle that fails ends its reply with its own tokens alone, and the host serves the next request" {
    var costs: [16]lanes.config.Cost = undefined;
    for (&costs, 1..) |*c, w| c.* = .{ .width = @intCast(w), .ms = 5.0 + 0.8 * @as(f64, @floatFromInt(w)) };
    var cfg = try lanes.Config.init(gpa, .{ .exact_width = 16, .gpu_tokens = true, .window_costs = &costs }, 16, 15);
    defer cfg.deinit(gpa);
    var target: lanes.fake.Fake = .{ .gpa = gpa };
    defer target.deinit();
    var clock: lanes.fake.FixedClock = .{};
    var core = lanes.Engine.init(gpa, &cfg, target.backend(), clock.clock());
    defer core.deinit();
    var host = LaneHost.init(gpa, std.testing.io, &core, .{ .lanes = 2, .inject = true });
    try host.start();
    defer host.stop();
    var inject: api.Inject = .{ .io = std.testing.io, .gpa = gpa, .room = extra.len };
    defer inject.deinit();
    var armed: Armed = .{ .inject = &inject, .target = &target };
    defer armed.tokens.deinit(gpa);
    const plain: Request = .{ .prompt = &prompt, .max_tokens = 30, .drafts = false, .inject = &inject }; // a step stays queued
    try host.engine().submit(1, &plain, .{ .ctx = &armed, .event = Armed.event });
    while (true) {
        armed.mutex.lockUncancelable(std.testing.io);
        const d = armed.done;
        armed.mutex.unlock(std.testing.io);
        if (d) |r| {
            try std.testing.expectEqual(Reason.failed, r);
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    const where = try inject.where(gpa);
    defer gpa.free(where);
    try std.testing.expectEqual(@as(usize, 0), where.len); // it failed at the settle, before any context was taken
    var history: std.ArrayList(u32) = .empty;
    defer history.deinit(gpa);
    try history.appendSlice(gpa, &prompt);
    for (armed.tokens.items) |t| { // what it sent is its own reply: no injected token reached the client
        try std.testing.expectEqual(lanes.fake.next(history.items, null, history.items.len), t);
        try history.append(gpa, t);
    }
    target.fail_reads.store(0, .release);
    var next: Reply = .{};
    defer next.tokens.deinit(gpa);
    const other = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
    const later: Request = .{ .prompt = &other, .max_tokens = 30 };
    try host.engine().submit(2, &later, .{ .ctx = &next, .event = Reply.event });
    try std.testing.expectEqual(Reason.length, next.wait());
    try std.testing.expectEqual(@as(usize, 30), next.tokens.items.len);
}
