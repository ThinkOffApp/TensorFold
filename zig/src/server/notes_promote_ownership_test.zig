//! Ownership, admission, recovery and prompt exclusion tests use the actual server and durable graph codec.
const std = @import("std");
const t = std.testing;
const Case = @import("notes_promote_erase_http_test.zig").Case;
const owned = @import("notes_promote_graph.zig");
const backend = @import("notes_promote_backend.zig").Backend;
const slide = @import("slide.zig");
const np = @import("notes_promote.zig");
const pjson = @import("notes/promote_json.zig");
const json = @import("json");
const secret = "My locker code is 7419.";

test "promotion ownership: graph enrollment must commit the source before the shared learner can fit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const path = try std.fmt.allocPrint(a, "{s}.graph", .{c.r.snap});
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    var admission: owned.Admission = .{ .p = c.p, .key = c.key, .text = secret };
    var out: slide.Out = .{ .conn = null, .a = a, .enrollment = admission.enrollment() };
    c.r.srv.slide.fault = .write;
    slide.teachText(c.r.srv, a, secret, "chat", np.Stop{ .flag = &c.p.stop }, &out);
    try t.expect(out.failed != null);
    try t.expectEqual(@as(usize, 0), c.learner.trained);
    try t.expectEqual(@as(usize, 0), out.results.items.len);
    const ids = try @import("slide_fact_record.zig").record(c.r.srv, a, &.{secret}, "chat", &out);
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    try t.expectEqualStrings(c.key, c.r.srv.slide.find(ids[0]).?.promotion_key);
}

test "promotion ownership: a note erased after fact finding is refused at enrollment without a new graph row" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    var admission: owned.Admission = .{ .p = c.p, .key = c.key, .text = secret };
    var out: slide.Out = .{ .conn = null, .a = a, .enrollment = admission.enrollment() };
    const found = [_][]const u8{secret};
    _ = try c.erase();
    const before = c.r.srv.slide.facts.items.len;
    try t.expectError(error.SourceGone, @import("slide_fact_record.zig").record(c.r.srv, a, &found, "chat", &out));
    try t.expectEqual(before, c.r.srv.slide.facts.items.len);
    try t.expectEqual(@as(usize, 0), c.learner.trained);
}

test "promotion ownership: split interrupted rows survive state and graph reload, then erase retires them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const path = try std.fmt.allocPrint(a, "{s}.graph", .{c.r.snap});
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    const id = try owned.add(&c.r.srv.slide, "7419 is the locker code.", "chat", c.key, 1);
    const ns = [_]@import("notes/promote.zig").Neuron{.{ .layer = 3, .neuron = 1, .key = .reply }};
    c.r.srv.slide.placed(id, &ns);
    c.r.srv.slide.mark(id, .missed);
    c.p.state.open = .{ .night = 2, .source_key = c.key, .teaching = "The gate is green. The locker code is 7419." };
    const encoded = try pjson.encode(&c.p.state, a);
    const fresh = try pjson.decode(t.allocator, encoded, .{});
    c.p.state.deinit();
    c.p.state = fresh;
    c.r.srv.slide.deinit();
    c.r.srv.slide = .init(t.allocator, t.io, path);
    var b: backend = .{ .p = c.p, .arena = a };
    try t.expectEqualSlices(@import("notes/promote.zig").Neuron, &ns, try b.placedFor(a, c.p.state.open.?.teaching));
    const reply = try c.erase();
    try t.expect(!reply.value.get("promotion").?.get("pending").?.bool);
    try t.expect(!c.learner.live_slot);
    try t.expectEqual(@as(usize, 1), c.learner.zeroed);
    try t.expectEqualStrings("forgotten", reply.value.get("places").?.strField("promotion_graph").?);
    try t.expect(std.mem.indexOf(u8, try c.r.srv.slide.render(a, null), "7419") == null);
    try c.controlIntact();
}

test "promotion ownership: a refused rewind retains its mark across backend and scratch allocator lifetimes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    {
        var scratch = std.heap.ArenaAllocator.init(t.allocator);
        defer scratch.deinit();
        var b: backend = .{ .p = c.p, .arena = scratch.allocator() };
        try b.mark(scratch.allocator());
        c.learner.refuse = true;
        try t.expectError(error.RewindRefused, b.rewind(scratch.allocator()));
    }
    try t.expect(c.p.rewind_pending);
    c.learner.refuse = false;
    var retry: backend = .{ .p = c.p, .arena = a };
    try retry.rewind(a);
    try t.expect(!c.p.rewind_pending and c.p.marked == null);
    retry.control_failed = true;
    c.r.srv.promotion_pending.store(true, .release);
    try retry.persist(&c.p.state);
    try t.expect(c.r.srv.promotion_pending.load(.acquire));
}

test "promotion ownership: open and failed rebuilds keep in-weights notes available to production prompts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .in_weights);
    defer c.deinit();
    const body = try json.newObject(a);
    try body.put(a, "notes", .{ .bool = true });
    try t.expect((try c.p.requestBody(a, .{ .object = body })).get("notes_exclude") != null);
    c.p.state.rebuild_next = true;
    try t.expect(c.p.tryPublish());
    try t.expect((try c.p.requestBody(a, .{ .object = body })).get("notes_exclude") == null);
    c.p.state.rebuild_next = false;
    c.p.state.open = .{ .night = 2 };
    try t.expect(c.p.tryPublish());
    try t.expect((try c.p.requestBody(a, .{ .object = body })).get("notes_exclude") == null);
}

test "promotion ownership: failed take-out preserves orphan addresses and blocks fitting until recovery" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const id = try owned.add(&c.r.srv.slide, secret, "chat", c.key, 1);
    const ns = [_]@import("notes/promote.zig").Neuron{.{ .layer = 3, .neuron = 1, .key = .reply }};
    c.r.srv.slide.placed(id, &ns);
    c.learner.refuse = true;
    try t.expect(!@import("slide_control.zig").take(c.r.srv, a, id, false));
    c.r.srv.slide.mark(id, .missed);
    try t.expectEqualSlices(@import("notes/promote.zig").Neuron, &ns, c.r.srv.slide.find(id).?.neurons);
    try t.expect(c.r.srv.promotion_pending.load(.acquire));
    c.learner.refuse = false;
    const reply = try c.erase();
    try t.expect(!reply.value.get("promotion").?.get("pending").?.bool);
    try t.expect(!c.learner.live_slot);
    try t.expectEqual(@as(usize, 1), c.learner.zeroed);
}

test "promotion ownership: reversible probe hashes are purged and a failed purge keeps the same erase retryable" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .in_weights);
    defer c.deinit();
    const logs = @import("notes_promote_logs.zig");
    defer logs.fail_purge = false;
    pjson.appendProbe(a, c.path, .{ .night = 1, .kind = "control", .q = "What is the code?", .reply = "7419" });
    try t.expectEqual(logs.Status.may_hold, logs.status(t.allocator, t.io, c.r.snap));
    logs.fail_purge = true;
    const failed = try c.erase();
    try t.expect(failed.value.get("retryable").?.bool);
    try t.expectEqualStrings("may_hold", failed.value.get("places").?.strField("promotion_probe_log").?);
    logs.fail_purge = false;
    const done = try c.erase();
    try t.expect(!done.value.get("retryable").?.bool);
    try t.expectEqualStrings("empty", done.value.get("places").?.strField("promotion_probe_log").?);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, try std.fmt.allocPrint(a, "{s}-probes.jsonl", .{c.path}), a, .limited(1));
    try t.expectEqual(@as(usize, 0), bytes.len);
}

test "promotion ownership: a partly kept lesson retires its successful sentence and leaves unrelated neurons intact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .note);
    defer c.deinit();
    const one = try owned.add(&c.r.srv.slide, secret, "chat", c.key, 1);
    const two = try owned.add(&c.r.srv.slide, "The gate is green.", "chat", c.key, 1);
    c.r.srv.slide.placed(one, &.{.{ .layer = 3, .neuron = 1, .key = .reply }});
    c.r.srv.slide.mark(one, .learned);
    var b: backend = .{ .p = c.p, .arena = a };
    const result = try b.taught(a, &.{ .{ .id = one, .recalled = true }, .{ .id = two, .recalled = false } });
    try t.expect(!result.kept);
    try t.expect(!c.learner.live_slot);
    try t.expectEqual(@as(usize, 1), c.learner.zeroed);
    try c.controlIntact();
}

test "promotion startup: explicit settings require an interval, a Notes snapshot and Sliding Weights" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rig = @import("notes_rig_test.zig");
    const r = try rig.Rig.init(t.allocator);
    defer r.deinit();
    const cli = @import("cli.zig");
    const start = @import("notes_promote_start.zig");
    var usage: cli.Usage = .{};
    try t.expect(start.create(r.srv, .{}));
    const setting = try cli.parse(a, &.{ "m", "--notes-promote-hold", "1" }, &usage);
    try t.expect(!start.create(r.srv, setting));
    var args: cli.Args = .{};
    args.notes.promotion.every_ms = 60_000;
    const store = r.srv.notes;
    r.srv.notes = null;
    const missing_store = start.create(r.srv, args);
    r.srv.notes = store;
    try t.expect(!missing_store);
    args.notes.path = r.snap;
    try t.expect(!start.create(r.srv, args));
    args.slide = true;
    try t.expect(start.create(r.srv, args));
    try t.expect(r.srv.promote != null);
}

test "promotion ownership: manual fact deletion restores Notes prompts and is detected before restart admission" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try Case.init(a, .in_weights);
    defer c.deinit();
    const id = try owned.add(&c.r.srv.slide, secret, "chat", c.key, 1);
    c.r.srv.slide.placed(id, c.p.state.find(c.key).?.neurons);
    c.r.srv.slide.mark(id, .learned);
    try t.expect(!owned.lost(c.p));
    c.r.srv.slide.mark(id, .deleted);
    try t.expect(owned.lost(c.p));
    owned.invalidated(c.p, a, c.key);
    const body = try json.newObject(a);
    try body.put(a, "notes", .{ .bool = true });
    try t.expect((try c.p.requestBody(a, .{ .object = body })).get("notes_exclude") == null);
    try t.expect(c.r.srv.promotion_pending.load(.acquire));
    try t.expect(c.p.state.rebuild_next);
}
