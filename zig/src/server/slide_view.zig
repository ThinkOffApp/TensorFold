//! Sliding Weights page and scripts, independent of lesson and promotion control.
const std = @import("std");
const routes = @import("routes.zig");
const Server = @import("server.zig").Server;
const Conn = @import("http_conn.zig").Conn;
const Allocator = std.mem.Allocator;

const page = @embedFile("slide.html");

/// The page's scripts, each served at /slide/NAME.
const scripts = [_]struct { []const u8, []const u8 }{
    .{ "data.js", @embedFile("slide_data.js") },
    .{ "panel.js", @embedFile("slide_panel.js") },
    .{ "flat.js", @embedFile("slide_flat.js") },
    .{ "scene.js", @embedFile("slide_scene.js") },
    .{ "tower.js", @embedFile("slide_tower.js") },
    .{ "fx.js", @embedFile("slide_fx.js") },
    .{ "bloom.js", @embedFile("slide_bloom.js") },
    .{ "layout.js", @embedFile("slide_layout.js") },
};

pub fn view(_: *Server, conn: *Conn, _: Allocator) void {
    send(conn, "text/html; charset=utf-8", page);
}

/// One of the page's scripts by name, else the unknown path.
pub fn script(_: *Server, conn: *Conn, a: Allocator, name: []const u8) void {
    for (scripts) |x| if (std.mem.eql(u8, x[0], name)) return send(conn, "text/javascript; charset=utf-8", x[1]);
    routes.unknown(conn, a);
}

fn send(conn: *Conn, kind: []const u8, body: []const u8) void {
    conn.startResponse(200, null) catch return;
    conn.addHeader("Content-Type", kind) catch return;
    var len: [24]u8 = undefined;
    conn.addHeader("Content-Length", std.fmt.bufPrint(&len, "{d}", .{body.len}) catch return) catch return;
    conn.finish(body) catch {};
}
