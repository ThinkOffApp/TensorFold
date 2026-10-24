//! Manual nights, draining and failed wakes use the real worker and the idle manager's lifetime counters.
const std = @import("std");
const api = @import("engine_api");
const cli = @import("cli.zig");
const rig = @import("notes_rig_test.zig");
const np = @import("notes_promote.zig");
const idle = @import("idle_unload.zig");
const t = std.testing;
const Server = @import("server.zig").Server;
const Seen = struct {
    srv: *Server,
    manager: ?*idle.Manager = null,
    ids: []const u32,
    asks: std.atomic.Value(u32) = .init(0),
    leased: std.atomic.Value(u32) = .init(0),
    opens: usize = 0,
    fn engine(s: *@This()) api.Engine {
        return .{ .ctx = s, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn submit(ctx: *anyopaque, id: api.Id, _: *const api.Request, sink: api.Sink) api.SubmitError!void {
        const s: *@This() = @ptrCast(@alignCast(ctx));
        _ = s.asks.fetchAdd(1, .seq_cst);
        const m = s.manager.?;
        m.mutex.lockUncancelable(t.io);
        const active = m.active > 0;
        m.mutex.unlock(t.io);
        if (active and s.srv.generating.load(.seq_cst) > 0) _ = s.leased.fetchAdd(1, .seq_cst);
        sink.event(sink.ctx, id, &.{ .prefilled = 0 });
        sink.event(sink.ctx, id, &.{ .tokens = s.ids });
        sink.event(sink.ctx, id, &.{ .finished = .{ .reason = .stop } });
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    fn open(ctx: *anyopaque, _: std.mem.Allocator, _: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8, _: cli.Args, why: *[]const u8) anyerror!?api.Opened {
        const s: *@This() = @ptrCast(@alignCast(ctx));
        s.opens += 1;
        why.* = "test wake failure";
        return null;
    }
    fn close(_: *anyopaque) void {}
    fn replace(_: *anyopaque, _: api.Opened, _: *std.heap.ArenaAllocator) void {}
};

test "promotion: manual night runs under an engine lease; drain and failed reload leave counts balanced" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(t.allocator);
    defer r.deinit();
    var seen: Seen = .{ .srv = r.srv, .ids = try r.srv.text.encode(a, "Your cat's eyes are green.", false) };
    r.srv.engine = seen.engine();
    var manager: idle.Manager = .{
        .gpa = t.allocator,
        .io = t.io,
        .args = .{ .model = "m" },
        .dir = "m",
        .model_type = "test",
        .idle_s = 60,
        .re = .{ .ctx = &seen, .open = Seen.open, .close_held = Seen.close, .replace = Seen.replace },
        .srv = r.srv,
    };
    seen.manager = &manager;
    r.srv.idle_manager = &manager;
    defer r.srv.idle_manager = null;
    var why: []const u8 = "";
    const p = try np.Promoter.init(t.allocator, t.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    r.srv.promote = p;
    defer @import("notes_promote_start.zig").stop(r.srv);
    try p.state.facts.append(p.state.alloc(), .{
        .key = "s2",
        .text = "My cat's eyes are green.",
        .status = .promoted,
        .probes = &.{.{ .q = "Which colour are my cat's eyes?", .ref = "Your cat's eyes are green." }},
    });
    r.srv.draining.store(true, .seq_cst);
    p.runNight();
    try t.expectEqual(@as(u32, 0), seen.asks.load(.seq_cst));
    try t.expectEqual(@as(u32, 0), manager.active);
    try t.expectEqual(@as(u32, 0), r.srv.generating.load(.seq_cst));
    r.srv.draining.store(false, .seq_cst);
    manager.state = .unloaded;
    manager.parked = true;
    p.runNight();
    try t.expectEqual(@as(usize, 1), seen.opens);
    try t.expectEqual(@as(u32, 0), seen.asks.load(.seq_cst));
    try t.expectEqual(@as(u32, 0), manager.active);
    try t.expectEqual(@as(u32, 0), r.srv.generating.load(.seq_cst));
    manager.state = .resident;
    manager.parked = false;
    try p.start();
    try t.expectEqual(@as(u16, 202), (try rig.request(r.srv, a, "POST", "/v1/promotion", "{}")).status);
    var done = false;
    for (0..600) |_| {
        p.mu.lockUncancelable(t.io);
        const nights = p.nights_done;
        p.mu.unlock(t.io);
        if (nights > 0) {
            done = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    try t.expect(done);
    @import("notes_promote_start.zig").stop(r.srv);
    try t.expect(seen.asks.load(.seq_cst) > 0);
    try t.expectEqual(seen.asks.load(.seq_cst), seen.leased.load(.seq_cst));
    try t.expectEqual(@as(u32, 0), manager.active);
    try t.expectEqual(@as(u32, 0), r.srv.generating.load(.seq_cst));
}
