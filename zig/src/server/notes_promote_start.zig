//! Promotion is created before admission and starts only after the idle manager has its final lifetime.
const std = @import("std");
const cli = @import("cli.zig");
const Server = @import("server.zig").Server;
const np = @import("notes_promote.zig");
const log = @import("log.zig");

pub fn create(srv: *Server, args: cli.Args) bool {
    const o = args.notes.promotion;
    const every = o.every_ms orelse return true;
    const store = srv.notes orelse {
        std.debug.print("tensorfold: --notes-promote-every needs --notes and --slide\n", .{});
        return false;
    };
    if (!args.slide) {
        std.debug.print("tensorfold: --notes-promote-every needs --slide on a writable model copy\n", .{});
        return false;
    }
    var why: []const u8 = "";
    srv.promote = np.Promoter.init(srv.gpa, srv.io, srv, store, args.notes.path.?, .{
        .every_ms = every,
        .settings = .{ .hold = o.hold, .alone = o.alone, .regress_notes = o.regress, .targeted = o.targeted, .thinking = o.thinking },
    }, &why) catch |e| {
        std.debug.print("tensorfold: promotion: {s} ({s})\n", .{ why, @errorName(e) });
        return false;
    };
    return true;
}

pub fn start(srv: *Server) bool {
    const p = srv.promote orelse return true;
    p.start() catch |e| {
        std.debug.print("tensorfold: promotion thread: {s}\n", .{@errorName(e)});
        return false;
    };
    log.line("notes promotion on: every {d}s, hold {d} nights, alone {d} nights; GET /v1/promotion reports state", .{ @divTrunc(p.every_ms, 1000), p.state.settings.hold, p.state.settings.alone });
    return true;
}

pub fn stop(srv: *Server) void {
    if (srv.promote) |p| p.deinit();
    srv.promote = null;
}
