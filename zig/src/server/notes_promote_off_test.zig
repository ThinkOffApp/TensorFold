//! A disabled promotion route preserves ordinary method responses and consumes bodies before the next request.
const std = @import("std");
const http = @import("http_conn.zig");
const routes = @import("routes.zig");
const rig = @import("notes_rig_test.zig");
const t = std.testing;

const Wire = struct {
    out: std.ArrayList(u8) = .empty,
    fn now(_: *anyopaque) i64 {
        return 0;
    }
    fn read(_: *anyopaque, _: []u8, _: i32) http.IoError!usize {
        return 0;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) error{Closed}!void {
        const w: *Wire = @ptrCast(@alignCast(ctx));
        w.out.appendSlice(t.allocator, bytes) catch return error.Closed;
    }
};

test "promotion off: body cannot become a pipelined request and ordinary method responses are unchanged" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(t.allocator);
    defer r.deinit();
    const notes = r.srv.notes;
    defer r.srv.notes = notes;
    const methods = [_]struct { name: []const u8, code: u16 }{
        .{ .name = "GET", .code = 404 },
        .{ .name = "POST", .code = 404 },
        .{ .name = "PUT", .code = 501 },
        .{ .name = "DELETE", .code = 404 },
    };
    for ([_]bool{ false, true }) |notes_on| for (methods) |m| {
        r.srv.notes = if (notes_on) notes else null;
        const body = "GET /v1/smuggled HTTP/1.1\r\nHost: test\r\n\r\n";
        const input = try std.fmt.allocPrint(a, "{s} /v1/promotion HTTP/1.1\r\nHost: test\r\nContent-Length: {d}\r\n\r\n{s}GET /health HTTP/1.1\r\nHost: test\r\n\r\n", .{ m.name, body.len, body });
        var wire: Wire = .{};
        defer wire.out.deinit(t.allocator);
        var conn = try http.Conn.init(t.allocator, -1, "test");
        defer conn.deinit();
        conn.quiet_log = true;
        conn.read_hooks = .{ .ctx = &wire, .now = Wire.now, .read = Wire.read };
        conn.write_hooks = .{ .ctx = &wire, .write = Wire.write };
        @memcpy(conn.buf[0..input.len], input);
        conn.end = input.len;
        try t.expectEqual(http.Outcome.ready, try conn.readRequest(a, false));
        routes.dispatch(r.srv, &conn, a);
        const status = try std.fmt.allocPrint(a, "HTTP/1.1 {d}", .{m.code});
        try t.expect(std.mem.startsWith(u8, wire.out.items, status));
        try t.expectEqual(http.Outcome.ready, try conn.readRequest(a, true));
        try t.expectEqualStrings("GET", conn.method);
        try t.expectEqualStrings("/health", conn.path);
    };
}
