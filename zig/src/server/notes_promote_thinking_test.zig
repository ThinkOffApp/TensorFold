//! Promotion's checks asked with thinking on as well as off: damage seen only with thinking on counts.
const std = @import("std");
const promote = @import("notes/promote.zig");
const testing = std.testing;
const Fake = @import("notes_promote_fake.zig").Fake;

fn status(s: *promote.State, key: []const u8) promote.Status {
    return (s.find(key) orelse return .note).status;
}

test "promotion: a night whose damage shows only with thinking on is rejected; asked with thinking off only, it is kept" {
    for ([_]bool{ true, false }) |thinking| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f: Fake = .{ .a = a, .thinking_breaks = "boat=blue" };
        _ = try f.add("w1", "dog=Luna");
        var s = promote.State.init(testing.allocator, .{ .thinking = thinking });
        defer s.deinit();
        _ = try promote.night(&s, a, &f);
        _ = try f.add("w2", "boat=blue");
        const n = try promote.night(&s, a, &f);
        if (!thinking) { // control: the same night asked with thinking off only does not see it
            try testing.expectEqual(@as(u32, 0), n.rejected);
            try testing.expectEqual(promote.Status.promoted, status(&s, "w2"));
            try testing.expectEqual(@as(u32, 0), f.thinking_asks);
            continue;
        }
        try testing.expectEqual(@as(u32, 1), n.rejected);
        try testing.expectEqual(promote.Status.rejected, status(&s, "w2"));
        try testing.expect(std.mem.indexOf(u8, n.worse_list, "control (thinking): What is the capital of France? -> Lyon") != null);
        try testing.expect(std.mem.indexOf(u8, n.worse_list, "control: What") == null); // with thinking off it held
    }
}

test "promotion: every regression probe is asked in both modes, and the probe log says which" {
    var probes_of: [2]u32 = undefined;
    for ([_]bool{ false, true }, 0..) |thinking, i| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f: Fake = .{ .a = a };
        _ = try f.add("w1", "cat eyes=green");
        _ = try f.add("w2", "my eyes=green");
        var s = promote.State.init(testing.allocator, .{ .thinking = thinking });
        defer s.deinit();
        const n = try promote.night(&s, a, &f);
        probes_of[i] = n.probes;
        var on: u32 = 0;
        var off: u32 = 0;
        for (f.records.items) |r| if (r.before != null) {
            if (r.thinking) on += 1 else off += 1;
        };
        try testing.expectEqual(if (thinking) off else 0, on);
        try testing.expect(off > 0);
    }
    try testing.expectEqual(2 * probes_of[0], probes_of[1]);
}

test "promotion: a fact its neurons answer only with thinking off never leaves the prompt" {
    for ([_]bool{ true, false }) |thinking| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f: Fake = .{ .a = a, .thinking_weak = "dog" };
        _ = try f.add("w1", "dog=Luna");
        var s = promote.State.init(testing.allocator, .{ .thinking = thinking });
        defer s.deinit();
        var last: promote.NightLog = .{};
        for (0..3) |_| last = try promote.night(&s, a, &f);
        if (!thinking) { // control: asked with thinking off only, it leaves the prompt as before
            try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
            continue;
        }
        try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
        try testing.expectEqual(@as(u32, 0), s.find("w1").?.alone);
        try testing.expectEqual(2 * last.alone_right, last.alone_asked); // right in one mode of the two
        var wrong_thinking: u32 = 0;
        for (f.records.items) |r| if (std.mem.eql(u8, r.kind, "alone") and r.thinking and !r.ok) {
            wrong_thinking += 1;
        };
        try testing.expect(wrong_thinking > 0);
    }
}

test "promotion: a thinking reply that copies the notes block is never judged; one citation is" {
    const judge = @import("notes/promote_judge.zig");
    try testing.expect(judge.copiesBlock("[21] \"I have moved; I live in Lisbon now.\"\n[22] \"My cat's name is Milo.\"\n[23] \""));
    try testing.expect(judge.copiesBlock("amber.\"\n[13] \"My dog is called Bruno now.\"  \n[15]  \"My sister's name is Ana.\""));
    try testing.expect(!judge.copiesBlock("Your dog's name is Bruno. You mentioned this in message [13]: \"My dog is called Bruno now.\""));
    try testing.expect(!judge.copiesBlock("Yes. In message [19], you said: \"My dog really likes apples.\""));
    try testing.expect(!judge.copiesBlock("The only note about the tent is [4] \"The tent belongs to me.\" It names no colour."));
    try testing.expect(!judge.copiesBlock("The colour of my brother's eyes is amber."));
    // a lesson after which every thinking reply copies the block: the night is kept, the copies recorded unjudged
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .a = a, .thinking_copies = "boat=blue" };
    _ = try f.add("w1", "dog=Luna");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try promote.night(&s, a, &f);
    _ = try f.add("w2", "boat=blue");
    const n = try promote.night(&s, a, &f);
    try testing.expectEqual(@as(u32, 0), n.rejected);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w2"));
    var unjudged: u32 = 0;
    for (f.records.items) |r| if (r.night == 2 and r.thinking and std.mem.indexOf(u8, r.why, "copies the notes block") != null) {
        try testing.expect(r.ok);
        unjudged += 1;
    };
    try testing.expect(unjudged > 0);
}
