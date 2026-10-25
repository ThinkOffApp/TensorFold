//! A blocked model save must allow Notes writes and must recheck new erase intents before publication.
const std = @import("std");
const t = std.testing;
const Case = @import("notes_promote_erase_http_test.zig").Case;
const rig = @import("notes_rig_test.zig");
const ops = @import("notes/operations.zig");
const Server = @import("server.zig").Server;

const Request = struct {
    srv: *Server,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8 = null,
    done: std.Io.Event = .unset,
    status: u16 = 0,
    failed: bool = false,
    pending: bool = false,

    fn run(r: *Request) void {
        defer r.done.set(t.io);
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const reply = rig.request(r.srv, arena.allocator(), r.method, r.path, r.body) catch {
            r.failed = true;
            return;
        };
        r.status = reply.status;
        if (reply.value.get("promotion")) |p| if (p.get("pending")) |v| {
            r.pending = v == .bool and v.bool;
        };
    }
};

fn quick(event: *std.Io.Event) bool {
    event.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(1500), .clock = .awake } }) catch return false;
    return true;
}

fn concurrent(erasing_other: bool) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .in_weights);
    defer c.deinit();
    var entered: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    c.learner.save_enter = &entered;
    c.learner.save_release = &release;
    var first: Request = .{ .srv = c.r.srv, .method = "DELETE", .path = try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{c.id}) };
    var second: Request = .{
        .srv = c.r.srv,
        .method = "POST",
        .path = "/v1/notes",
        .body = "{\"text\":\"My spare key is copper.\",\"subject\":\"my spare key\"}",
    };
    if (erasing_other) {
        for (try ops.list(c.r.store(), a, true)) |v| if (std.mem.eql(u8, v.source orelse "", c.control_key)) {
            second = .{ .srv = c.r.srv, .method = "DELETE", .path = try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{v.id}) };
            break;
        };
        try t.expectEqualStrings("DELETE", second.method);
    }
    const eraser = try std.Thread.spawn(.{}, Request.run, .{&first});
    const saving = quick(&entered);
    const writer = std.Thread.spawn(.{}, Request.run, .{&second}) catch |e| {
        release.set(t.io);
        eraser.join();
        return e;
    };
    const wrote_before_save = quick(&second.done);
    release.set(t.io);
    eraser.join();
    writer.join();
    c.learner.save_enter = null;
    c.learner.save_release = null;
    try t.expect(saving);
    try t.expect(wrote_before_save);
    try t.expect(!first.failed and !second.failed);
    try t.expectEqual(@as(u16, 200), first.status);
    if (erasing_other) {
        try t.expect(first.pending and second.pending);
        try t.expectEqual(@as(u16, 200), second.status);
        const retry = try c.erase();
        try t.expect(!retry.value.get("promotion").?.get("pending").?.bool);
        try t.expect(c.learner.touched_control);
    } else {
        try t.expectEqual(@as(u16, 201), second.status);
        try t.expect(!first.pending);
        try c.r.restart();
        c.p.store = c.r.store();
        const found = for (try ops.list(c.r.store(), a, false)) |v| {
            if (std.mem.eql(u8, v.text, "My spare key is copper.")) break true;
        } else false;
        try t.expect(found);
        try c.controlIntact();
    }
}

test "promotion concurrency: a Notes write finishes while model save blocks and survives journal retirement and restart" {
    try concurrent(false);
}

test "promotion concurrency: a new erase during model save remains pending and prevents premature publication" {
    try concurrent(true);
}

const FenceWork = struct {
    p: *@import("notes_promote.zig").Promoter,
    recovery: bool,
    persisted: bool = false,
    persist: bool = false,
    fn run(w: *FenceWork) void {
        if (w.recovery and !w.persist) return w.p.recover();
        w.p.srv.teacher.learning.lockUncancelable(t.io);
        defer w.p.srv.teacher.learning.unlock(t.io);
        if (w.persist) {
            var arena = std.heap.ArenaAllocator.init(t.allocator);
            defer arena.deinit();
            var b: @import("notes_promote_backend.zig").Backend = .{ .p = w.p, .arena = arena.allocator() };
            b.persist(&w.p.state) catch return;
            w.persisted = true;
        } else w.persisted = w.p.drainPending();
    }
};

fn acknowledgmentRace(recovery: bool, persist: bool) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    c.p.state.rebuild_next = recovery;
    c.r.srv.promotion_pending.store(true, .release);
    var gate: @import("notes_promote_ack.zig").Gate = .{ .pause_after = if (recovery and !persist) 1 else 0 };
    c.p.ack_gate = &gate;
    var work: FenceWork = .{ .p = c.p, .recovery = recovery, .persist = persist };
    const thread = try std.Thread.spawn(.{}, FenceWork.run, .{&work});
    const paused = quick(&gate.entered);
    const reply = c.erase() catch |e| {
        gate.release.set(t.io);
        thread.join();
        c.p.ack_gate = null;
        return e;
    };
    gate.release.set(t.io);
    thread.join();
    c.p.ack_gate = null;
    try t.expect(paused);
    try t.expect(reply.value.get("promotion").?.get("pending").?.bool);
    try t.expect(c.p.erasing.load(.acquire));
    try t.expect(c.r.srv.promotion_pending.load(.acquire));
    const refused = @import("slide_forget.zig").admit(c.r.srv, a);
    if (refused == null) c.r.srv.teacher.learning.unlock(t.io);
    try t.expect(refused != null);
    try t.expectEqual(@as(usize, 0), c.learner.trained);
    const retry = try c.erase();
    try t.expect(!retry.value.get("promotion").?.get("pending").?.bool);
    try c.controlIntact();
}

test "promotion concurrency: settle acknowledgment cannot release a concurrent DELETE fence" {
    try acknowledgmentRace(true, false);
}

test "promotion concurrency: drain acknowledgment cannot release a concurrent DELETE fence" {
    try acknowledgmentRace(false, false);
}

test "promotion concurrency: persist acknowledgment cannot release a concurrent DELETE fence" {
    try acknowledgmentRace(true, true);
}
