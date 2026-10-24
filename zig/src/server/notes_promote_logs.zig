//! Probe hashes can expose short answers; only a missing or empty log establishes its clearance.
const std = @import("std");
const pjson = @import("notes/promote_json.zig");
pub const Status = enum { off, empty, may_hold };
const limit = 1 << 20;

pub fn status(gpa: std.mem.Allocator, io: std.Io, snapshot: []const u8) Status {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}.promote-probes.jsonl", .{snapshot}) catch return .may_hold;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(limit)) catch |e|
        return if (e == error.FileNotFound) .off else .may_hold;
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return .empty;
    return .may_hold;
}

pub var fail_purge: bool = false;

/// Erase the whole owned log: control and cross-fact probes can copy any note's answer or its reversible hash.
pub fn purge(a: std.mem.Allocator, io: std.Io, snapshot: []const u8) !void {
    if (@import("builtin").is_test and fail_purge) return error.ProbeLogWrite;
    if (status(a, io, snapshot) == .off) return;
    const path = try std.fmt.allocPrint(a, "{s}.promote-probes.jsonl", .{snapshot});
    try pjson.writeFile(a, path, "");
}

/// Disabling the worker cannot establish that an earlier promotion state or its neurons were erased.
pub fn dormantState(io: std.Io, snapshot: []const u8) Status {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}.promote", .{snapshot}) catch return .may_hold;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e|
        return if (e == error.FileNotFound) .off else .may_hold;
    file.close(io);
    return .may_hold;
}

test "promotion: any nonempty probe log, including reversible hashes, remains an erase warning" {
    const t = std.testing;
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/state", .{dir.sub_path});
    const file = "state.promote-probes.jsonl";
    try t.expectEqual(Status.off, status(t.allocator, t.io, path));
    try dir.dir.writeFile(t.io, .{ .sub_path = file, .data = "" });
    try t.expectEqual(Status.empty, status(t.allocator, t.io, path));
    const hashed = try pjson.probeLine(a, .{ .night = 1, .kind = "alone", .key = "w7", .q = "secret", .ok = true });
    try dir.dir.writeFile(t.io, .{ .sub_path = file, .data = hashed });
    try t.expectEqual(Status.may_hold, status(t.allocator, t.io, path));
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectEqual(Status.may_hold, status(failing.allocator(), t.io, path));
    const mixed = try std.mem.concat(a, u8, &.{ "{\"q\":\"secret\"}\n", hashed });
    const unknown = try std.fmt.allocPrint(a, "{s},\"unknown\":\"secret\"}}", .{hashed[0 .. hashed.len - 1]});
    const huge = try a.alloc(u8, limit + 1);
    @memset(huge, ' ');
    for ([_][]const u8{ "{\"q\":\"secret\"}", mixed, "{broken", unknown, huge }) |bytes| {
        try dir.dir.writeFile(t.io, .{ .sub_path = file, .data = bytes });
        try t.expectEqual(Status.may_hold, status(t.allocator, t.io, path));
    }
}
