//! Real shared teaching must preserve ownership through phase transitions, stop signals and graph failures.
const std = @import("std");
const t = std.testing;
const Case = @import("notes_promote_erase_http_test.zig").Case;
const np = @import("notes_promote.zig");
const owned = @import("notes_promote_graph.zig");
const slide = @import("slide.zig");
const backend = @import("notes_promote_backend.zig").Backend;
const text = "My locker code is 7419. My gate is green.";

test "promotion phase: a real multi-sentence teachText keeps ownership and erase finds its unrecorded neurons" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.initText(a, .note, text);
    defer c.deinit();
    var admission: owned.Admission = .{ .p = c.p, .key = c.key, .text = text };
    var out: slide.Out = .{ .conn = null, .a = a, .enrollment = admission.enrollment() };
    slide.teachText(c.r.srv, a, text, "chat", np.Stop{ .flag = &c.p.stop, .erasing = &c.p.erasing }, &out);
    try t.expectEqual(@as(usize, 2), c.r.srv.slide.facts.items.len);
    for (c.r.srv.slide.facts.items, 0..) |f, i| {
        try t.expectEqualStrings(c.key, f.promotion_key);
        c.r.srv.slide.placed(f.id, &.{.{ .layer = 3, .neuron = @intCast(i + 1), .key = .reply }});
    }
    const reply = try c.erase();
    try t.expect(!reply.value.get("promotion").?.get("pending").?.bool);
    try t.expectEqual(@as(usize, 2), c.learner.zeroed);
    try t.expect(std.mem.indexOf(u8, try c.r.srv.slide.render(a, null), "7419") == null);
    try c.controlIntact();
}

test "promotion phase: a missed legacy text row without neurons is removed instead of falsely reported clear" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const id = c.r.srv.slide.add("My locker code is 7419.", "chat", 1);
    c.r.srv.slide.mark(id, .missed);
    _ = try c.erase();
    try t.expect(std.mem.indexOf(u8, try c.r.srv.slide.render(a, null), "7419") == null);
}

test "promotion phase: graph commit failure reports its place as may_hold until the same erase retries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const path = try std.fmt.allocPrint(a, "{s}.graph", .{c.r.snap});
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    _ = try owned.add(&c.r.srv.slide, "My locker code is 7419.", "chat", c.key, 1);
    c.r.srv.slide.fault = .write;
    const failed = try c.erase();
    try t.expect(failed.value.get("retryable").?.bool);
    try t.expectEqualStrings("may_hold", failed.value.get("places").?.strField("promotion_graph").?);
    const retried = try c.erase();
    try t.expect(!retried.value.get("retryable").?.bool);
    try t.expectEqualStrings("forgotten", retried.value.get("places").?.strField("promotion_graph").?);
}

test "promotion phase: an erase fence rejects enrollment while the live note still exists" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.initText(a, .note, text);
    defer c.deinit();
    c.p.erasing.store(true, .release);
    var admission: owned.Admission = .{ .p = c.p, .key = c.key, .text = text };
    var out: slide.Out = .{ .conn = null, .a = a, .enrollment = admission.enrollment() };
    try t.expectError(error.ErasePending, @import("slide_fact_record.zig").record(c.r.srv, a, &.{text}, "chat", &out));
    try t.expectEqual(@as(usize, 0), c.r.srv.slide.facts.items.len);
}

test "promotion phase: an erase raised inside model generation stops the shared lesson before another sentence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.initText(a, .note, text);
    defer c.deinit();
    c.p.state.open = .{ .night = 1, .source_key = c.key, .teaching = text };
    c.learner.erase_during_submit = &c.p.erasing;
    var b: backend = .{ .p = c.p, .arena = a };
    try t.expectError(error.Stopped, b.teach(a, text));
    try t.expectEqual(@as(usize, 2), c.r.srv.slide.facts.items.len);
    try t.expectEqual(@import("slide_graph.zig").State.queued, c.r.srv.slide.facts.items[1].state);
}

test "promotion phase: erasing one source preserves unrelated conversations, chains and teacher facts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const path = try std.fmt.allocPrint(a, "{s}.graph", .{c.r.snap});
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    c.r.srv.slide.keepTalk("unrelated", &.{.{ "What colour is the sky?", "The sky is blue." }});
    const other = c.r.srv.slide.add("My umbrella is blue.", "chat", 1);
    c.r.srv.slide.mark(other, .learned);
    c.r.srv.slide.chained(other, .{ "What colour is my umbrella?", "Blue." });
    try c.r.srv.teacher.remember("my umbrella", "What colour is my umbrella?", "Blue.");
    const mine = try owned.add(&c.r.srv.slide, "My locker code is 7419.", "chat", c.key, 1);
    c.r.srv.slide.mark(mine, .learning);
    c.r.srv.slide.keepTalk("owned", &.{.{ "What is my locker code?", "7419" }});
    c.r.srv.slide.asked(mine, &.{.{ .question = "What is my locker code?", .answer = "7419" }});
    try c.r.srv.teacher.remember("my locker", "What is my locker code?", "7419");
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    _ = try c.erase();
    try t.expect((try c.r.srv.slide.talk(a, "unrelated")) != null);
    try t.expect((try c.r.srv.slide.talk(a, "owned")) == null);
    try t.expect(c.r.srv.slide.find(other).?.chain != null);
    try t.expectEqual(@as(usize, 1), c.r.srv.teacher.told.items.len);
    const report = try c.r.srv.slide.render(a, null);
    try t.expect(std.mem.indexOf(u8, report, "7419") == null);
    try t.expect(std.mem.indexOf(u8, report, "The sky is blue.") != null);
}

test "promotion recovery: a settled failed night releases manual learning without repeating LLM questions" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    c.p.state.rebuild_next = true;
    c.r.srv.promotion_pending.store(true, .release);
    const asked = c.learner.generations;
    c.p.recover();
    try t.expectEqual(asked, c.learner.generations);
    try t.expect(!c.r.srv.promotion_pending.load(.acquire));
    const admission = @import("slide_forget.zig").admit(c.r.srv, a);
    if (admission == null) c.r.srv.teacher.learning.unlock(t.io);
    try t.expect(admission == null);
    try t.expect(c.p.state.rebuild_next);
    try t.expectEqual(@as(usize, 0), c.learner.zeroed);
    try c.controlIntact();
}

test "promotion recovery: a refused mark settles before the next full-night interval and preserves old neurons" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    c.p.state.settings.targeted = false;
    c.p.state.settings.regress_notes = 0;
    c.p.state.rebuild_next = true;
    c.learner.refuse = true;
    c.p.runNight();
    try t.expect(c.r.srv.promotion_pending.load(.acquire));
    c.learner.refuse = false;
    const asked = c.learner.generations;
    c.p.recover();
    try t.expectEqual(asked, c.learner.generations);
    try t.expect(!c.r.srv.promotion_pending.load(.acquire));
    const admission = @import("slide_forget.zig").admit(c.r.srv, a);
    if (admission == null) c.r.srv.teacher.learning.unlock(t.io);
    try t.expect(admission == null);
    try t.expectEqual(@as(usize, 0), c.learner.zeroed);
    try c.controlIntact();
}
