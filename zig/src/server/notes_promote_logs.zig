//! Recognize hash-only probe records; legacy text and unreadable or oversized logs remain named erase warnings.
const std = @import("std");
const json = @import("json");
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
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = json.parse(a, line) catch return .may_hold;
        if (parsed != .ok or !hashOnly(parsed.ok)) return .may_hold;
    }
    return .off;
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

fn hashOnly(v: json.Value) bool {
    if (v != .object or !std.mem.eql(u8, v.strField("format") orelse "", pjson.probe_format)) return false;
    if (v.get("night") == null or v.get("kind") == null or v.get("ok") == null or v.get("q_sha256") == null)
        return false;
    for (v.object.keys(), v.object.values()) |name, value| {
        if (std.mem.eql(u8, name, "format")) continue;
        if (std.mem.eql(u8, name, "kind")) {
            const kind = value.str() orelse return false;
            var known = false;
            for ([_][]const u8{ "fact", "control", "neighbour", "pair", "alone", "reference", "dropped" }) |s|
                known = known or std.mem.eql(u8, kind, s);
            if (!known) return false;
        } else if (std.mem.eql(u8, name, "key")) {
            const key = value.str() orelse return false;
            if (key.len < 2 or (key[0] != 'w' and key[0] != 's')) return false;
            for (key[1..]) |c| if (!std.ascii.isDigit(c)) return false;
        } else if (std.mem.eql(u8, name, "night") or std.mem.eql(u8, name, "round")) {
            if ((value.int64() orelse return false) < 0) return false;
        } else if (std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "thinking")) {
            if (value != .bool) return false;
        } else if (std.mem.eql(u8, name, "exclude")) {
            for (value.items() orelse return false) |id| if ((id.int64() orelse return false) < 0) return false;
        } else {
            var known = false;
            for ([_][]const u8{ "q_sha256", "before_sha256", "after_sha256", "reply_sha256", "ref_sha256", "why_sha256" }) |s|
                known = known or std.mem.eql(u8, name, s);
            if (!known) return false;
            const digest = value.str() orelse return false;
            if (digest.len != 64) return false;
            for (digest) |c| if (!std.ascii.isHex(c)) return false;
        }
    }
    return true;
}

test "promotion: hash log clearance refuses legacy, mixed, malformed, unknown and oversized records" {
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
    try t.expectEqual(Status.off, status(t.allocator, t.io, path));
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
