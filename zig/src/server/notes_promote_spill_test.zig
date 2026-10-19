//! A refused promotion night taught again one fact at a time: the fact that spills over is rejected on its own.
const std = @import("std");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const testing = std.testing;
const Fake = @import("notes_promote_fake.zig").Fake;

fn status(s: *promote.State, key: []const u8) promote.Status {
    return (s.find(key) orelse return .note).status;
}

fn liveText(f: *const Fake, text: []const u8) bool {
    for (f.pocket.items) |l| if (l.live and std.mem.eql(u8, l.text, text)) return true;
    return false;
}

/// The probes a one-by-one check of `key` recorded as worse.
fn worseOf(f: *const Fake, key: []const u8) u32 {
    var n: u32 = 0;
    for (f.records.items) |r| n += @intFromBool(std.mem.eql(u8, r.key, key) and r.before != null and !r.ok);
    return n;
}

test "promotion: a refused night is taught again one fact at a time, and only the fact that spills over is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator(), .leaks = "brother eyes=amber" };
    _ = try f.add("w1", "cat eyes=green");
    _ = try f.add("w2", "brother eyes=amber");
    _ = try f.add("w3", "tent=red");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(@as(u32, 1), n.rejected); // the three taught together
    try testing.expectEqual(@as(u32, 3), n.one_by_one);
    try testing.expectEqual(@as(u32, 1), n.blamed);
    try testing.expectEqual(@as(u32, 0), n.worse);
    try testing.expectEqualStrings("add", n.plan);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
    try testing.expectEqual(promote.Status.rejected, status(&s, "w2"));
    // taught after w2 was rewound: had its neurons stayed, w3's check would have seen the leak too
    try testing.expectEqual(promote.Status.promoted, status(&s, "w3"));
    try testing.expectEqual(@as(u32, 0), worseOf(&f, "w1"));
    try testing.expectEqual(@as(u32, 0), worseOf(&f, "w3"));
    const w2 = worseOf(&f, "w2");
    try testing.expect(w2 > 0);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "rejected: taught on its own it made {d} answers worse", .{w2}), s.find("w2").?.why);
    try testing.expect(std.mem.indexOf(u8, n.worse_list, "w2: neighbour: N:") != null);
    try testing.expect(!liveText(&f, "brother eyes=amber"));
    try testing.expectEqual(@as(usize, 2), f.liveCount());
    try testing.expectEqual(@as(usize, 4), s.pocket.len); // w1's and w3's neurons
    try testing.expectEqual(@as(usize, 2), s.find("w1").?.neurons.len);
    try testing.expectEqual(@as(usize, 0), s.find("w2").?.neurons.len);
    // the counts are kept in the state file
    var back = try pjson.decode(testing.allocator, try pjson.encode(&s, arena.allocator()), .{});
    defer back.deinit();
    try testing.expectEqual(@as(u32, 3), back.nights.items[0].one_by_one);
    try testing.expectEqual(@as(u32, 1), back.nights.items[0].blamed);
}

test "promotion: when every fact spills over on its own, none is kept and the pocket is as the night found it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w0", "dog=Luna");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w0"));
    const pocket = try arena.allocator().dupe(promote.Neuron, s.pocket);
    f.leaks = "brother eyes=amber";
    f.breaks = "boat=blue";
    _ = try f.add("w1", "brother eyes=amber");
    _ = try f.add("w2", "boat=blue");
    const n = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(@as(u32, 2), n.one_by_one);
    try testing.expectEqual(@as(u32, 2), n.blamed);
    try testing.expectEqualStrings("none", n.plan);
    try testing.expectEqual(promote.Status.rejected, status(&s, "w1"));
    try testing.expectEqual(promote.Status.rejected, status(&s, "w2"));
    try testing.expect(status(&s, "w0") == .promoted or status(&s, "w0") == .in_weights);
    try testing.expectEqualSlices(promote.Neuron, pocket, s.pocket);
    try testing.expectEqual(@as(usize, 1), f.liveCount());
    try testing.expectEqualStrings("Paris", (try f.askAll(arena.allocator(), &.{.{ .q = "What is the capital of France?" }}))[0]);
}

test "promotion: one due fact that spills over is rejected as before, with no lesson taught again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator(), .leaks = "brother eyes=amber" };
    _ = try f.add("w1", "brother eyes=amber");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(@as(u32, 1), n.rejected);
    try testing.expectEqual(@as(u32, 0), n.one_by_one);
    try testing.expectEqual(@as(u32, 1), f.teaches);
    try testing.expectEqualStrings("rejected: the night made answers worse", s.find("w1").?.why);
    try testing.expectEqual(@as(usize, 0), f.liveCount());
}

test "promotion: a lesson missed in the one-by-one pass stays a missed note, and the facts around it are judged alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator(), .leaks = "brother eyes=amber", .misses = &.{"tent=red"} };
    _ = try f.add("w1", "cat eyes=green");
    _ = try f.add("w2", "brother eyes=amber");
    _ = try f.add("w3", "tent=red");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(@as(u32, 3), n.one_by_one);
    try testing.expectEqual(@as(u32, 1), n.blamed);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
    try testing.expectEqual(promote.Status.rejected, status(&s, "w2"));
    try testing.expectEqual(promote.Status.missed, status(&s, "w3"));
    try testing.expectEqualStrings("too few clean answers to learn from", s.find("w3").?.why);
    try testing.expectEqual(@as(usize, 1), f.liveCount());
}

test "promotion: a night with no spill-over is kept whole, with nothing taught again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "cat eyes=green");
    _ = try f.add("w2", "brother eyes=amber");
    _ = try f.add("w3", "tent=red");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(@as(u32, 0), n.rejected);
    try testing.expectEqual(@as(u32, 0), n.one_by_one);
    try testing.expectEqual(@as(u32, 3), f.teaches);
    for ([_][]const u8{ "w1", "w2", "w3" }) |k| try testing.expectEqual(promote.Status.promoted, status(&s, k));
}

test "promotion: a one-by-one pass where only a missed lesson passes says plan none, not add" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator(), .leaks = "brother eyes=amber", .breaks = "boat=blue", .misses = &.{"tent=red"} };
    _ = try f.add("w1", "brother eyes=amber");
    _ = try f.add("w2", "boat=blue");
    _ = try f.add("w3", "tent=red");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n = try promote.night(&s, arena.allocator(), &f);
    try testing.expectEqual(@as(u32, 3), n.one_by_one);
    try testing.expectEqual(@as(u32, 2), n.blamed);
    try testing.expectEqualStrings("none", n.plan); // GPU check, 20 Oct: the pears' missed lesson made it read "add"
    try testing.expectEqual(promote.Status.missed, status(&s, "w3"));
    try testing.expectEqual(@as(usize, 0), s.pocket.len);
}
