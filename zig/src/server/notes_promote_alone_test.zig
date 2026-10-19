//! The nightly alone check against the scripted learner: what it records, whom it leaves out, the probes it asks.
const std = @import("std");
const json = @import("json.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const Fake = @import("notes_promote_fake.zig").Fake;
const testing = std.testing;

fn status(s: *promote.State, key: []const u8) promote.Status {
    return (s.find(key) orelse return .note).status;
}

/// The alone asks the fake recorded on night `night`.
fn aloneOf(a: std.mem.Allocator, f: *const Fake, night: u32) ![]const promote.Record {
    var out: std.ArrayList(promote.Record) = .empty;
    for (f.records.items) |r| if (r.night == night and std.mem.eql(u8, r.kind, "alone")) try out.append(a, r);
    return out.items;
}

test "promotion alone: every alone ask is recorded with its night, fact, question, notes left out, reply and verdict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .a = a };
    const dog = try f.add("w1", "dog=Luna");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    for (1..3) |night| {
        const n = try promote.night(&s, a, &f);
        const asks = try aloneOf(a, &f, @intCast(night));
        try testing.expectEqual(@as(usize, n.alone_asked), asks.len);
        try testing.expectEqual(@as(usize, 4), asks.len); // the dog's four probes, each recorded
        for (asks) |r| {
            try testing.expectEqualStrings("w1", r.key);
            try testing.expectEqualStrings("Q:dog", r.q);
            try testing.expectEqualSlices(u32, &.{dog}, r.exclude.?);
            try testing.expectEqualStrings("Luna", r.reply.?);
            try testing.expectEqualStrings("Luna", r.ref);
            try testing.expect(r.ok);
        }
    }
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
    // a wrong ask is recorded wrong: the neurons no longer answer, and the fact goes back to the prompt
    f.weak = "dog";
    _ = try promote.night(&s, a, &f);
    const wrong = try aloneOf(a, &f, 3);
    try testing.expectEqual(@as(usize, 4), wrong.len);
    for (wrong) |r| try testing.expect(!r.ok and std.mem.eql(u8, r.reply.?, "unknown"));
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
}

test "promotion alone: a probe record's JSON line: an alone ask's fields, and a regression probe's as before" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try pjson.probeLine(a, .{ .night = 7, .kind = "alone", .key = "s2", .q = "Which colour are my cat's eyes?", .exclude = &.{ 2, 10 }, .reply = "Your cat's eyes are brown.", .ref = "Your cat's eyes are green.", .ok = false });
    const v = switch (try json.parse(a, line)) {
        .ok => |x| x,
        .err => return error.BadLine,
    };
    try testing.expectEqual(@as(i64, 7), v.get("night").?.int64().?);
    try testing.expectEqualStrings("alone", v.strField("kind").?);
    try testing.expectEqualStrings("s2", v.strField("key").?);
    try testing.expectEqualStrings("Which colour are my cat's eyes?", v.strField("q").?);
    const ids = v.get("exclude").?.items().?;
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqual(@as(i64, 10), ids[1].int64().?);
    try testing.expectEqualStrings("Your cat's eyes are brown.", v.strField("reply").?);
    try testing.expectEqualStrings("Your cat's eyes are green.", v.strField("ref").?);
    try testing.expect(!v.get("ok").?.bool);
    // a regression probe's line has the fields it always had, in their order
    const old = try pjson.probeLine(a, .{ .night = 3, .kind = "fact", .q = "Q:dog", .before = "Luna", .after = "Bruno", .ok = false });
    try testing.expectEqualStrings("{\"night\": 3, \"kind\": \"fact\", \"q\": \"Q:dog\", \"before\": \"Luna\", \"after\": \"Bruno\", \"ok\": false}", old);
}
