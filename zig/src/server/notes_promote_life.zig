//! Background promotion holds the same engine lifetime lease as an HTTP inference or erase.
const std = @import("std");
const Server = @import("server.zig").Server;
const idle = @import("idle_unload.zig");
const log = @import("log.zig");

pub fn begin(srv: *Server, a: std.mem.Allocator) bool {
    _ = srv.generating.fetchAdd(1, .seq_cst);
    if (srv.idle_manager) |m| m.begin();
    var kept = false;
    defer if (!kept) end(srv);
    if (srv.draining.load(.seq_cst)) return false;
    if (srv.idle_manager) |m| {
        const why = idle.wakeReload(m, srv, a) catch return false;
        if (why.len > 0) {
            log.line("notes promotion: engine wake failed: {s}", .{why});
            return false;
        }
    }
    kept = true;
    return true;
}

pub fn end(srv: *Server) void {
    if (srv.idle_manager) |m| m.end();
    _ = srv.generating.fetchSub(1, .seq_cst);
}
