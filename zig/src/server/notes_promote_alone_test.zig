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

/// The cat's eyes and mine, both green, and a note that joins them in the block ("the same colour as mine").
fn greenPair(f: *Fake) ![3]u32 {
    const cat = try f.add("w1", "cat eyes=green");
    const mine = try f.add("w2", "my eyes=green");
    const bridge = try f.addBridge("w9", "cat eyes", "my eyes");
    return .{ cat, mine, bridge };
}

test "promotion alone: a fact another candidate's note answers for is asked with that note out too, and fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the neurons carry my eyes but not the cat's: the cat's eyes come back only through the bridge and my eyes' note
    var f: Fake = .{ .a = a, .weaks = &.{"cat eyes"} };
    const ids = try greenPair(&f);
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n1 = try promote.night(&s, a, &f);
    try testing.expectEqual(@as(u32, 2), n1.kept);
    try testing.expectEqual(@as(u32, 0), s.find("w1").?.alone); // the old check counted it right alone
    try testing.expectEqual(@as(u32, 2), n1.alone_rounds); // the cat dropped, my eyes asked again with its note back
    const r1 = try aloneOf(a, &f, 1);
    for (r1) |r| {
        const cat = std.mem.eql(u8, r.key, "w1");
        try testing.expectEqualSlices(u32, if (r.round == 1) &.{ ids[0], ids[1] } else &.{ids[1]}, r.exclude.?);
        try testing.expect(r.round == 1 or !cat); // the cat is not asked again
        try testing.expectEqual(!cat, r.ok);
    }
    _ = try promote.night(&s, a, &f);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
    try testing.expectEqual(@as(u32, 0), s.find("w1").?.alone);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w2"));
    // control: with the cat's neurons answering, both leave the prompt on night 2
    var g: Fake = .{ .a = a };
    _ = try greenPair(&g);
    var s2 = promote.State.init(testing.allocator, .{});
    defer s2.deinit();
    _ = try promote.night(&s2, a, &g);
    _ = try promote.night(&s2, a, &g);
    try testing.expectEqual(promote.Status.in_weights, status(&s2, "w1"));
    try testing.expectEqual(promote.Status.in_weights, status(&s2, "w2"));
}

test "promotion alone: two candidates that answer only through each other's note both fail, every night" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .a = a, .weaks = &.{ "cat eyes", "my eyes" } };
    _ = try greenPair(&f);
    _ = try f.add("w3", "dog=Luna"); // a third candidate the neurons carry
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    for (0..3) |_| {
        const n = try promote.night(&s, a, &f);
        try testing.expectEqual(@as(u32, 4), n.alone_right); // the dog's four probes; the pair's eight wrong
        try testing.expectEqual(@as(u32, 12), n.alone_asked);
        try testing.expectEqual(@as(u32, 2), n.alone_rounds); // the pair out in round 1, the dog asked again with theirs in
        try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
        try testing.expectEqual(promote.Status.promoted, status(&s, "w2"));
        try testing.expectEqual(@as(u32, 0), s.find("w2").?.alone);
    }
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w3"));
    // what the old check saw: each asked with only its own note out, the other's note and the bridge answer it
    const own = try f.askAll(a, &.{ .{ .q = "Q:cat eyes", .exclude = &.{1} }, .{ .q = "Q:my eyes", .exclude = &.{2} } });
    try testing.expectEqualStrings("green", own[0]);
    try testing.expectEqualStrings("green", own[1]);
}

test "promotion alone: the rest are asked again with the failures' notes back, where a note overrides the neurons" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // my favourite colour is in the neurons, the sister's is not; with her note in the block it answers for mine
    var f: Fake = .{ .a = a, .weaks = &.{"sister colour"} };
    const mine = try f.add("w1", "fav colour=blue");
    _ = try f.add("w2", "sister colour=orange");
    _ = try f.addBridge("w9", "fav colour", "sister colour");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    for (1..3) |night| {
        const n = try promote.night(&s, a, &f);
        try testing.expectEqual(@as(u32, 2), n.alone_rounds);
        const asks = try aloneOf(a, &f, @intCast(night));
        var second: usize = 0;
        for (asks) |r| if (r.round == 2) {
            second += 1;
            try testing.expectEqualStrings("w1", r.key);
            try testing.expectEqualSlices(u32, &.{mine}, r.exclude.?); // the sister's note back in
            try testing.expectEqualStrings("orange", r.reply.?);
        };
        try testing.expectEqual(@as(usize, 4), second);
        try testing.expectEqual(@as(u32, 0), n.alone_right);
    }
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1")); // never out of the prompt
    try testing.expectEqual(promote.Status.promoted, status(&s, "w2"));
}

fn ofKind(a: std.mem.Allocator, f: *const Fake, kind: []const u8) ![]const promote.Record {
    var out: std.ArrayList(promote.Record) = .empty;
    for (f.records.items) |r| if (std.mem.eql(u8, r.kind, kind)) try out.append(a, r);
    return out.items;
}

test "promotion alone: a reference that does not give its fact is written once more, and dropped if it still does not" {
    for ([_]bool{ true, false }) |twice| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f: Fake = .{ .a = a, .garbage = &.{"dog=Luna"}, .garbage_twice = twice };
        _ = try f.add("w1", "dog=Luna");
        var s = promote.State.init(testing.allocator, .{});
        defer s.deinit();
        const n = try promote.night(&s, a, &f);
        const dog = s.find("w1").?;
        try testing.expectEqual(@as(u32, 1), f.rewrites);
        try testing.expectEqual(@as(usize, if (twice) 3 else 4), dog.probes.len);
        for (dog.probes) |p| try testing.expectEqualStrings("Luna", p.ref); // never the off-topic one
        try testing.expectEqual(@as(u32, @intFromBool(twice)), n.dropped);
        const refs = try ofKind(a, &f, "reference");
        try testing.expectEqual(@as(usize, 1), refs.len);
        try testing.expectEqualStrings(@import("notes_promote_fake.zig").nemotron, refs[0].before.?);
        try testing.expectEqual(!twice, refs[0].ok);
        try testing.expect(refs[0].why.len > 0);
        // the facts' probes that stay are asked alone and pass
        _ = try promote.night(&s, a, &f);
        try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
    }
}

test "promotion alone: a degenerate wording of the learner's is never a probe" {
    const degenerate = @import("notes/promote_probes.zig").degenerate;
    // run6's boat: its two held-out questions, then sound wordings
    try testing.expect(degenerate("What is the colour of the boat's colour's colour's colour's colour's colour's colour's colour?"));
    try testing.expect(degenerate("What is the colour of the boat's colour's colour's colour's colour's colour's colour's colour's colour?"));
    try testing.expect(degenerate("What is the boat’s colour’s colour’s colour?"));
    for ([_][]const u8{ "What is the colour of the vessel?", "What colour is stated for the boat?", "What colour is the boat's colour?", "What is my sister's brother's name?", "Who is who?" }) |q| try testing.expect(!degenerate(q));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the fake model cannot answer the degenerate wording: asked alone it would keep the boat in the prompt for ever
    var f: Fake = .{ .a = a, .wordings = &.{ "Q:boat's colour's colour's colour", "Q:boat", "Q:boat" } };
    _ = try f.add("w1", "boat=blue");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n = try promote.night(&s, a, &f);
    try testing.expectEqual(@as(u32, 1), n.dropped);
    try testing.expectEqual(@as(usize, 2), s.find("w1").?.probes.len);
    for (s.find("w1").?.probes) |p| try testing.expectEqualStrings("Q:boat", p.q);
    try testing.expectEqual(@as(usize, 1), (try ofKind(a, &f, "dropped")).len);
    _ = try promote.night(&s, a, &f);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
}

test "promotion alone: stored probes a night would not build are dropped once on load; a fact left with none goes back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nemotron = @import("notes_promote_fake.zig").nemotron;
    var f: Fake = .{ .a = a };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "boat=blue");
    for ([_][2][]const u8{ .{ "dog", "dog=Luna" }, .{ "boat", "boat=blue" } }, 0..) |x, i| {
        const ns = try a.dupe(promote.Neuron, &.{.{ .layer = 1, .neuron = @intCast(i), .key = .reply }});
        try f.pocket.append(a, .{ .topic = x[0], .value = x[1][x[0].len + 1 ..], .neurons = ns, .text = x[1] }); // both taught
    }
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    const dog = [_]promote.Probe{ .{ .q = "Q:dog", .ref = "Luna" }, .{ .q = "Q:dog", .ref = nemotron }, .{ .q = "Q:dog's dog's dog", .ref = "Luna" } };
    const boat = [_]promote.Probe{.{ .q = "Q:boat", .ref = nemotron }};
    try st.facts.append(st.alloc(), .{ .key = "w1", .text = "dog=Luna", .status = .in_weights, .alone = 2, .probes = &dog });
    try st.facts.append(st.alloc(), .{ .key = "w2", .text = "boat=blue", .status = .in_weights, .alone = 2, .probes = &boat });
    // the state file as an earlier build wrote it, read back
    var s = try pjson.decode(testing.allocator, try pjson.encode(&st, a), .{});
    defer s.deinit();
    try testing.expectEqual(@as(u32, 3), try promote.repair(&s, a, &f));
    try testing.expectEqual(@as(usize, 1), s.find("w1").?.probes.len);
    try testing.expectEqualStrings("Luna", s.find("w1").?.probes[0].ref);
    try testing.expectEqual(@as(usize, 0), s.find("w2").?.probes.len);
    const dropped = try ofKind(a, &f, "dropped");
    try testing.expectEqual(@as(usize, 3), dropped.len);
    for (dropped) |r| try testing.expect(r.why.len > 0);
    try testing.expectEqual(@as(u32, 0), try promote.repair(&s, a, &f)); // once: nothing left to drop
    // the next night: the dog's sound probe still answers alone; the boat, with none left, goes back to the prompt
    const n = try promote.night(&s, a, &f);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
    try testing.expectEqual(promote.Status.promoted, status(&s, "w2"));
    try testing.expectEqual(@as(u32, 1), n.back_to_prompt);
    try testing.expectEqualStrings("back in the prompt: no probe left to ask it alone", s.find("w2").?.why);
}
