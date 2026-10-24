//! Fact enrollment happens after wording generation and before any fitting, including internal promotion lessons.
const std = @import("std");
const Server = @import("server.zig").Server;
const Out = @import("slide_stream.zig").Out;

pub fn record(srv: *Server, a: std.mem.Allocator, facts: []const []const u8, source: []const u8, out: *Out) ![]const u32 {
    const ids = if (out.enrollment) |e| try e.record(e.ctx, a, facts, source) else ids: {
        const xs = try a.alloc(u32, facts.len);
        for (facts, xs) |fact, *id| {
            id.* = srv.slide.add(fact, source, @import("slide.zig").now(srv));
            if (id.* == 0) return error.OutOfMemory;
        }
        break :ids xs;
    };
    for (facts, ids) |fact, id| out.event("fact", .{ .id = id, .text = fact });
    return ids;
}
