//! Promotion file publication must leave neither an owned temporary nor an open rewrite after allocation failure.
const std = @import("std");
const pjson = @import("notes/promote_json.zig");
const t = std.testing;

test "promotion: an allocation failure cannot strand a state temporary" {
    var dir = t.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/state.promote", .{dir.sub_path});
    var finished = false;
    for (0..16) |at| {
        try pjson.writeFile(a, path, "old");
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = at });
        const result = pjson.writeFile(failing.allocator(), path, "new");
        if (result) |_| {
            finished = true;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
        var it = dir.dir.iterate();
        while (try it.next(t.io)) |entry| try t.expectEqualStrings("state.promote", entry.name);
        const actual = try dir.dir.readFileAlloc(t.io, "state.promote", a, .limited(16));
        try t.expectEqualStrings(if (finished) "new" else "old", actual);
        if (finished) break;
    }
    try t.expect(finished);
}

test "promotion: failed state writes keep the old file until rename and always clean their temporary" {
    var dir = t.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/state.promote", .{dir.sub_path});
    defer pjson.write_fault = .none;
    for ([_]pjson.WriteFault{ .write, .file_sync, .rename, .folder_sync }) |fault| {
        try pjson.writeFile(a, path, "old");
        pjson.write_fault = fault;
        try t.expectError(error.PromoteIo, pjson.writeFile(a, path, "new complete state"));
        const actual = try dir.dir.readFileAlloc(t.io, "state.promote", a, .limited(64));
        try t.expectEqualStrings(if (fault == .folder_sync) "new complete state" else "old", actual);
        var it = dir.dir.iterate();
        while (try it.next(t.io)) |entry| try t.expectEqualStrings("state.promote", entry.name);
        try pjson.writeFile(a, path, "new complete state");
        const retried = try dir.dir.readFileAlloc(t.io, "state.promote", a, .limited(64));
        try t.expectEqualStrings("new complete state", retried);
    }
}

test "promotion: future probe logs contain hashes and opaque ids instead of note text" {
    var dir = t.tmpDir(.{ .iterate = true });
    defer dir.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/state.promote", .{dir.sub_path});
    const secret = "My locker code is 7419.";
    const log_path = "state.promote-probes.jsonl";
    pjson.appendProbe(a, path, .{
        .night = 2,
        .kind = "alone",
        .key = "w17",
        .q = secret,
        .before = secret,
        .after = secret,
        .reply = secret,
        .ref = secret,
        .why = secret,
        .exclude = &.{ 17, 23 },
        .round = 2,
        .ok = false,
        .thinking = true,
    });
    const bytes = try dir.dir.readFileAlloc(t.io, log_path, a, .limited(4096));
    try t.expect(std.mem.indexOf(u8, bytes, secret) == null);
    const v = (try @import("json").parse(a, bytes)).ok;
    try t.expectEqualStrings("w17", v.strField("key").?);
    try t.expectEqual(@as(i64, 23), v.get("exclude").?.array[1].int64().?);
    try t.expect(v.get("thinking").?.bool);
    try t.expectEqual(@as(usize, 64), v.strField("q_sha256").?.len);
    for ([_][]const u8{ "q", "before", "after", "reply", "ref", "why" }) |name| try t.expect(v.get(name) == null);
}
