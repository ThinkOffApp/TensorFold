//! Promotion in a running server: in-weights notes leave every chat block, blocks count as use, off changes nothing.
const std = @import("std");
const json = @import("json.zig");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const notes_promote = @import("notes_promote.zig");
const testing = std.testing;

const ask = "{\"messages\": [{\"role\": \"user\", \"content\": \"What colour is my car?\"}], \"notes\": true, \"notes_echo\": true, \"notes_write\": false, \"max_tokens\": 1}";

fn ids(v: json.Value) ![]const i64 {
    const n = v.get("notes") orelse return error.NoNotes;
    const xs = (n.get("ids") orelse return error.NoNotes).items() orelse return error.NoNotes;
    const out = try testing.allocator.alloc(i64, xs.len);
    for (xs, out) |x, *o| o.* = x.int64() orelse return error.NoNotes;
    return out;
}

fn block(v: json.Value) []const u8 {
    const n = v.get("notes") orelse return "";
    return n.strField("block") orelse "";
}

test "promotion rig: an in-weights note leaves the chat block, its block counts as use, and off is as before" {
    _ = &notes_promote.Promoter.runNight; // the night's server side compiles with the rest
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    const off = try rig.request(r.srv, a, "POST", "/v1/chat/completions", ask);
    try testing.expectEqual(@as(u16, 200), off.status);
    const before = try ids(off.value);
    defer testing.allocator.free(before);
    try testing.expect(before.len >= 2);
    try testing.expectEqual(@as(u16, 404), (try rig.request(r.srv, a, "GET", "/v1/promotion", null)).status);
    // what a client gets when it leaves that note out itself (the promoter off)
    const client = try rig.request(r.srv, a, "POST", "/v1/chat/completions", try std.fmt.allocPrint(a, "{{\"messages\": [{{\"role\": \"user\", \"content\": \"What colour is my car?\"}}], \"notes\": true, \"notes_echo\": true, \"notes_write\": false, \"notes_exclude\": [{d}], \"max_tokens\": 1}}", .{before[0]}));
    const client_ids = try ids(client.value);
    defer testing.allocator.free(client_ids);
    // a state whose first retrieved note is in weights, on disk beside the snapshot, read at the promoter's start
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    const key = try std.fmt.allocPrint(a, "s{d}", .{before[0]});
    try st.facts.append(st.alloc(), .{ .key = key, .text = "x", .status = .in_weights, .alone = 2 });
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    var owned = true;
    defer if (owned) p.deinit();
    r.srv.promote = p;
    defer r.srv.promote = null;
    const on = try rig.request(r.srv, a, "POST", "/v1/chat/completions", ask);
    const with = try ids(on.value);
    defer testing.allocator.free(with);
    try testing.expect(std.mem.indexOfScalar(i64, with, before[0]) == null);
    try testing.expectEqualSlices(i64, client_ids, with); // as if the client had left it out
    try testing.expectEqualStrings(block(client.value), block(on.value));
    try testing.expect(p.retrieved.contains(try std.fmt.allocPrint(a, "s{d}", .{with[0]})));
    try testing.expect(!p.retrieved.contains(key)); // left out: not in this block
    const got = try rig.request(r.srv, a, "GET", "/v1/promotion", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings("in_weights", (got.value.get("state").?.get("facts").?.items().?)[0].strField("status").?);
    // a client's own exclusions are kept beside the server's
    const both = try rig.request(r.srv, a, "POST", "/v1/chat/completions", try std.fmt.allocPrint(a, "{{\"messages\": [{{\"role\": \"user\", \"content\": \"What colour is my car?\"}}], \"notes\": true, \"notes_write\": false, \"notes_exclude\": [{d}], \"max_tokens\": 1}}", .{before[1]}));
    const both_ids = try ids(both.value);
    defer testing.allocator.free(both_ids);
    try testing.expect(std.mem.indexOfScalar(i64, both_ids, before[0]) == null and std.mem.indexOfScalar(i64, both_ids, before[1]) == null);
    // off again: the same block as before, byte for byte
    r.srv.promote = null;
    p.deinit();
    owned = false;
    const again = try rig.request(r.srv, a, "POST", "/v1/chat/completions", ask);
    const back = try ids(again.value);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(i64, before, back);
    try testing.expectEqualStrings(block(off.value), block(again.value));
    try testing.expect(block(off.value).len > 0);
}

test "promotion rig: a note written after a night is keyed by its write, and an erase's renumbering is followed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    const w1 = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My boat is green.\", \"subject\": \"my boat\"}");
    try testing.expectEqual(@as(u16, 201), w1.status);
    const w2 = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
    const kite: i64 = w2.value.get("id").?.int64().?;
    const kite_source = w2.value.strField("source").?;
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    try st.facts.append(st.alloc(), .{ .key = kite_source, .text = "My kite is orange.", .status = .in_weights, .alone = 2 });
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    defer p.deinit();
    r.srv.promote = p;
    const kite_ask = "{\"messages\": [{\"role\": \"user\", \"content\": \"What colour is my kite?\"}], \"notes\": true, \"notes_write\": false, \"max_tokens\": 1}";
    const k1 = try ids((try rig.request(r.srv, a, "POST", "/v1/chat/completions", kite_ask)).value);
    defer testing.allocator.free(k1);
    try testing.expect(std.mem.indexOfScalar(i64, k1, kite) == null);
    // the boat's write erased: the kite's note moves down one id, and is still the one left out
    const boat: i64 = w1.value.get("id").?.int64().?;
    const er = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{boat}), null);
    try testing.expectEqual(@as(u16, 200), er.status);
    const k2 = try ids((try rig.request(r.srv, a, "POST", "/v1/chat/completions", kite_ask)).value);
    defer testing.allocator.free(k2);
    try testing.expect(std.mem.indexOfScalar(i64, k2, kite - 1) == null);
    // control: without the promoter the kite's note is in the block
    r.srv.promote = null;
    const k3 = try ids((try rig.request(r.srv, a, "POST", "/v1/chat/completions", kite_ask)).value);
    defer testing.allocator.free(k3);
    try testing.expect(std.mem.indexOfScalar(i64, k3, kite - 1) != null);
}

/// Answers "o" to every prompt and takes every learn request at once, keeping the neurons it was asked to zero.
const Learner = struct {
    zeroed: std.ArrayList(promote.Neuron) = .empty,
    saves: u32 = 0,
    refuse: bool = false, // every learn request refused (busy)
    const api = @import("engine_api");
    fn engine(e: *Learner) api.Engine {
        return .{ .ctx = e, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory, .learn = learn } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn submit(_: *anyopaque, id: api.Id, _: *const api.Request, sink: api.Sink) api.SubmitError!void {
        sink.event(sink.ctx, id, &.{ .prefilled = 0 });
        sink.event(sink.ctx, id, &.{ .tokens = &.{'o'} });
        sink.event(sink.ctx, id, &.{ .finished = .{ .reason = .stop } });
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    fn learn(ctx: *anyopaque, req: *const api.LearnRequest, sink: api.LearnSink) api.LearnError!void {
        const e: *Learner = @ptrCast(@alignCast(ctx));
        if (e.refuse) return error.Busy;
        e.zeroed.appendSlice(testing.allocator, req.retire) catch {};
        e.saves += @intFromBool(req.save);
        sink.event(sink.ctx, &.{ .done = .{} });
    }
};

fn inWeights(a: std.mem.Allocator, r: *rig.Rig, source: []const u8, first: u16) !void {
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    const ns = try a.dupe(promote.Neuron, &.{ .{ .layer = 3, .neuron = first, .key = .reply }, .{ .layer = 7, .neuron = first, .key = .subject } });
    try st.facts.append(st.alloc(), .{ .key = source, .text = "t", .status = .in_weights, .alone = 2, .neurons = ns });
    st.pocket = ns;
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
}

test "promotion rig: erasing a promoted note zeroes its neurons at once, or when the running night ends; a restart keeps it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var learner: Learner = .{};
    defer learner.zeroed.deinit(testing.allocator);
    r.srv.engine = learner.engine();
    const w = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
    const id = w.value.get("id").?.int64().?;
    try inWeights(a, r, w.value.strField("source").?, 0);
    var why: []const u8 = "";
    var p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    r.srv.promote = p;
    const er = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{id}), null);
    try testing.expectEqual(@as(u16, 200), er.status);
    const pr = er.value.get("promotion").?;
    try testing.expect(pr.get("pending").?.bool == false);
    try testing.expectEqual(@as(i64, 2), pr.get("zeroed").?.int64().?);
    try testing.expectEqual(@as(usize, 2), learner.zeroed.items.len);
    try testing.expect(learner.saves >= 1); // the zeroed pocket written into the model's files
    try testing.expectEqual(promote.Status.freed, p.state.facts.items[0].status);
    try testing.expectEqual(@as(usize, 0), p.state.pocket.len);
    // a restart reads the erase back from the state file
    r.srv.promote = null;
    p.deinit();
    p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    try testing.expectEqual(promote.Status.freed, p.state.facts.items[0].status);
    try testing.expectEqual(@as(usize, 0), p.state.facts.items[0].neurons.len);
    p.deinit();
    // a night running (the learner's lock held): the zeroing waits for its end
    const w2 = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My boat is green.\", \"subject\": \"my boat\"}");
    try inWeights(a, r, w2.value.strField("source").?, 1);
    p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    defer p.deinit();
    r.srv.promote = p;
    defer r.srv.promote = null;
    r.srv.teacher.learning.lockUncancelable(testing.io);
    const er2 = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{w2.value.get("id").?.int64().?}), null);
    try testing.expect(er2.value.get("promotion").?.get("pending").?.bool);
    try testing.expectEqual(@as(usize, 2), learner.zeroed.items.len); // nothing yet
    p.drainPending(); // the night's end, the lock still held by it
    r.srv.teacher.learning.unlock(testing.io);
    try testing.expectEqual(@as(usize, 4), learner.zeroed.items.len);
    try testing.expectEqual(@as(u16, 1), learner.zeroed.items[2].neuron);
    try testing.expectEqual(promote.Status.freed, p.state.facts.items[0].status);
    // control: an erase on a server without promotion says nothing of neurons
    r.srv.promote = null;
    const w3 = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My tent is red.\", \"subject\": \"my tent\"}");
    const er3 = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{w3.value.get("id").?.int64().?}), null);
    try testing.expect(er3.value.get("promotion") == null);
    try testing.expectEqual(@as(usize, 4), learner.zeroed.items.len);
}

test "promotion rig: an erase whose zeroing is refused, or whose state is not written, is never reported done and is finished after a restart" {
    const Fail = enum { refused, persist, publish };
    for ([_]Fail{ .refused, .persist, .publish }) |fail| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try rig.Rig.init(testing.allocator);
        defer r.deinit();
        var learner: Learner = .{};
        defer learner.zeroed.deinit(testing.allocator);
        r.srv.engine = learner.engine();
        const w = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
        try inWeights(a, r, w.value.strField("source").?, 0);
        var why: []const u8 = "";
        var p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
        r.srv.promote = p;
        learner.refuse = fail == .refused;
        notes_promote.Promoter.fail_persist = fail == .persist;
        notes_promote.Promoter.fail_publish = fail == .publish;
        const er = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{w.value.get("id").?.int64().?}), null);
        notes_promote.Promoter.fail_persist = false;
        notes_promote.Promoter.fail_publish = false;
        learner.refuse = false;
        const pr = er.value.get("promotion").?;
        try testing.expect(pr.get("pending").?.bool); // never reported done
        try testing.expect(pr.get("failed") != null);
        if (fail != .publish) { // the state still owns the fact's neurons: the next try can find and zero them
            try testing.expect(promote.active(p.state.facts.items[0].status));
            try testing.expectEqual(@as(usize, 2), p.state.facts.items[0].neurons.len);
            try testing.expectEqual(@as(usize, 2), p.state.pocket.len);
        }
        // a restart: the file read again, and the start's first step finishes the erase
        r.srv.promote = null;
        p.deinit();
        p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
        defer p.deinit();
        if (fail != .publish) try testing.expect(promote.active(p.state.facts.items[0].status)); // still erase-pending on disk
        const zeroed_before = learner.zeroed.items.len;
        r.srv.teacher.learning.lockUncancelable(testing.io);
        p.drainPending();
        r.srv.teacher.learning.unlock(testing.io);
        try testing.expectEqual(promote.Status.freed, p.state.facts.items[0].status);
        try testing.expectEqual(@as(usize, 0), p.state.pocket.len);
        if (fail != .publish) try testing.expectEqual(zeroed_before + 2, learner.zeroed.items.len);
        // and the file now says so
        var back = try pjson.decode(testing.allocator, try r.tmp.dir.readFileAlloc(testing.io, "snap.json.promote", a, .limited(1 << 20)), .{});
        defer back.deinit();
        try testing.expectEqual(promote.Status.freed, back.facts.items[0].status);
    }
}

test "promotion rig: a publish that keeps failing keeps the erase pending across retries and a restart, then completes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var learner: Learner = .{};
    defer learner.zeroed.deinit(testing.allocator);
    r.srv.engine = learner.engine();
    const w = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
    const key = w.value.strField("source").?;
    try inWeights(a, r, key, 0);
    var why: []const u8 = "";
    var p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    r.srv.promote = p;
    notes_promote.Promoter.fail_publish = true;
    defer notes_promote.Promoter.fail_publish = false;
    const er = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{w.value.get("id").?.int64().?}), null);
    try testing.expect(er.value.get("promotion").?.get("pending").?.bool);
    try testing.expect(p.publish_pending);
    try testing.expectEqual(@as(usize, 1), p.weights.items.len); // the list still holds the erased fact's key
    for (0..2) |_| { // retries while it keeps failing: never done, the flag kept
        r.srv.teacher.learning.lockUncancelable(testing.io);
        p.drainPending();
        r.srv.teacher.learning.unlock(testing.io);
        try testing.expect(p.publish_pending);
    }
    try testing.expectEqual(@as(usize, 2), learner.zeroed.items.len); // zeroed once; the retries only refresh
    r.srv.promote = null;
    p.deinit();
    p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    defer p.deinit();
    try testing.expect(p.publish_pending); // still failing at the start
    try testing.expectEqual(promote.Status.freed, p.state.facts.items[0].status); // the state file was written
    notes_promote.Promoter.fail_publish = false;
    r.srv.teacher.learning.lockUncancelable(testing.io);
    p.drainPending();
    r.srv.teacher.learning.unlock(testing.io);
    try testing.expect(!p.publish_pending);
    try testing.expectEqual(@as(usize, 0), p.weights.items.len);
}

test "promotion rig: an erase while the promoter's allocations fail is reported pending, and completes once memory is back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var learner: Learner = .{};
    defer learner.zeroed.deinit(testing.allocator);
    r.srv.engine = learner.engine();
    const w = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
    try inWeights(a, r, w.value.strField("source").?, 0);
    // the note erased from the store with no promoter attached: its fact is in the pocket, its note gone
    const er = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{w.value.get("id").?.int64().?}), null);
    try testing.expectEqual(@as(u16, 200), er.status);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(failing.allocator(), testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    defer p.deinit();
    // every allocation of the promoter from the k-th on fails: pending each time until k passes all of them
    var pending_seen: usize = 0;
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        failing.fail_index = failing.alloc_index + k;
        const v = try p.erased(a, &.{}); // as the erase route calls it: it takes the learner's lock itself
        failing.fail_index = std.math.maxInt(usize);
        if (!v.get("pending").?.bool) break;
        pending_seen += 1;
        try testing.expect(v.get("failed") != null);
        // never reported done while the fact is not out of the state and the list refreshed
        try testing.expect(promote.active(p.state.facts.items[0].status) or p.publish_pending);
    }
    try testing.expect(pending_seen >= 1 and k < 256);
    try testing.expectEqual(promote.Status.freed, p.state.facts.items[0].status);
    try testing.expect(!p.publish_pending);
    try testing.expect(learner.zeroed.items.len >= 2); // zeroed at least once (again on a retry: the same)
}
