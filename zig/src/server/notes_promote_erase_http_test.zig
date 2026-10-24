//! Review regressions for promotion erasure, using the real HTTP routes, state codec and an inert learner.
const std = @import("std");
const api = @import("engine_api");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const promoter = @import("notes_promote.zig");
const testing = std.testing;
const secret = "My locker code is 7419.";
const marker = "7419";
const control_text = "My umbrella is blue.";

const Learner = struct {
    refuse: bool = false,
    zeroed: usize = 0,
    saves: usize = 0,
    touched_control: bool = false,
    fail_state_after_save: bool = false,
    trained: usize = 0,
    live_slot: bool = true,
    fn engine(e: *@This()) api.Engine {
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
    fn learn(ctx: *anyopaque, request: *const api.LearnRequest, sink: api.LearnSink) api.LearnError!void {
        const e: *@This() = @ptrCast(@alignCast(ctx));
        if (e.refuse) return error.Busy;
        for (request.retire) |n| {
            e.zeroed += 1;
            if (n.neuron == 1) e.live_slot = false;
            if (n.neuron == 9) e.touched_control = true;
        }
        e.saves += @intFromBool(request.save);
        if (request.train.len > 0) {
            e.trained += 1;
            e.live_slot = true;
        }
        if (request.save and e.fail_state_after_save) promoter.Promoter.fail_persist = true;
        sink.event(sink.ctx, &.{ .done = .{} });
    }
};

const Case = struct {
    r: *rig.Rig,
    p: *promoter.Promoter,
    learner: *Learner,
    a: std.mem.Allocator,
    id: i64,
    key: []const u8,
    control_key: []const u8,
    path: []const u8,

    fn init(a: std.mem.Allocator, fact_status: promote.Status) !Case {
        const learner = try testing.allocator.create(Learner);
        learner.* = .{};
        errdefer testing.allocator.destroy(learner);
        const r = try rig.Rig.init(testing.allocator);
        errdefer r.deinit();
        r.srv.engine = learner.engine();
        const added = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\":\"My locker code is 7419.\",\"subject\":\"my locker\"}");
        try testing.expectEqual(@as(u16, 201), added.status);
        const other = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\":\"My umbrella is blue.\",\"subject\":\"my umbrella\"}");
        try testing.expectEqual(@as(u16, 201), other.status);
        const key = added.value.strField("source").?;
        const control_key = other.value.strField("source").?;
        const active = fact_status == .promoted or fact_status == .in_weights;
        const neurons = try a.dupe(promote.Neuron, &.{ .{ .layer = 3, .neuron = 1, .key = .reply }, .{ .layer = 7, .neuron = 1, .key = .subject } });
        const control_neurons = try a.dupe(promote.Neuron, &.{.{ .layer = 3, .neuron = 9, .key = .reply }});
        var state = promote.State.init(testing.allocator, .{});
        defer state.deinit();
        const question: promote.Probe = .{ .q = "What is my locker code?", .ref = secret };
        const pair: promote.Pair = .{ .q = "Does my locker have the same code as my umbrella?", .ref = secret, .text = secret };
        try state.facts.append(state.alloc(), .{
            .key = key,
            .text = secret,
            .status = fact_status,
            .neurons = if (active) neurons else &.{},
            .ask = question,
            .probes = try a.dupe(promote.Probe, &.{question}),
            .neighbours = try a.dupe([]const u8, &.{"What is my brother's locker code?"}),
            .pair = pair,
        });
        // A pair cached on another fact also carries the erased fact; its own text and neurons must survive.
        try state.facts.append(state.alloc(), .{ .key = control_key, .text = control_text, .status = .in_weights, .neurons = control_neurons, .pair = pair });
        try state.nights.append(state.alloc(), .{ .night = 1, .worse_list = secret });
        state.nights_done = 1;
        state.pocket = try a.alloc(promote.Neuron, (if (active) @as(usize, 2) else 0) + 1);
        if (active) @memcpy(@constCast(state.pocket)[0..2], neurons);
        @memcpy(@constCast(state.pocket)[state.pocket.len - 1 ..], control_neurons);
        const path = try std.fmt.allocPrint(a, "{s}.promote", .{r.snap});
        try pjson.writeFile(a, path, try pjson.encode(&state, a));
        var why: []const u8 = "";
        const p = try promoter.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
        errdefer p.deinit();
        r.srv.promote = p;
        try testing.expect(std.mem.indexOf(u8, p.report, marker) != null);
        const seeded = p.state.find(key).?;
        try testing.expect(seeded.ask != null and seeded.probes.len > 0 and seeded.neighbours.len > 0 and seeded.pair != null);
        return .{ .r = r, .p = p, .learner = learner, .a = a, .id = added.value.get("id").?.int64().?, .key = key, .control_key = control_key, .path = path };
    }
    fn deinit(c: *Case) void {
        promoter.Promoter.fail_persist = false;
        promoter.Promoter.fail_publish = false;
        c.r.srv.promote = null;
        c.p.deinit();
        c.r.deinit();
        testing.allocator.destroy(c.learner);
    }
    fn erase(c: *Case) !rig.Reply {
        return rig.request(c.r.srv, c.a, "DELETE", try std.fmt.allocPrint(c.a, "/v1/notes/{d}?erase=true", .{c.id}), null);
    }
    fn controlIntact(c: *Case) !void {
        const f = c.p.state.find(c.control_key) orelse return error.UnrelatedFactLost;
        try testing.expectEqualStrings(control_text, f.text);
        try testing.expectEqual(@as(usize, 1), f.neurons.len);
        try testing.expect(!c.learner.touched_control);
    }
    fn fieldsScrubbed(c: *Case) !void {
        try c.controlIntact();
        const f = c.p.state.find(c.key) orelse return;
        try testing.expectEqualStrings("", f.text);
        try testing.expect(f.probes.len == 0 and f.neighbours.len == 0 and f.pair == null);
        if (f.ask) |q| try testing.expect(q.q.len == 0 and q.ref.len == 0);
    }
    fn persistedScrubbed(c: *Case) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, c.path, c.a, .limited(8 << 20));
        var loaded = try pjson.decode(testing.allocator, bytes, .{});
        defer loaded.deinit();
        const again = try pjson.encode(&loaded, c.a);
        try testing.expect(std.mem.indexOf(u8, again, marker) == null);
        const other = loaded.find(c.control_key) orelse return error.UnrelatedFactLost;
        try testing.expectEqualStrings(control_text, other.text);
    }
};

fn checkFields(fact_status: promote.Status) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), fact_status);
    defer c.deinit();
    try testing.expectEqual(@as(u16, 200), (try c.erase()).status);
    try c.fieldsScrubbed();
}

test "promotion erase HTTP: erase scrubs an in-weights fact's metadata" {
    try checkFields(.in_weights);
}
test "promotion erase HTTP: erase scrubs a promoted fact's metadata" {
    try checkFields(.promoted);
}
test "promotion erase HTTP: erase scrubs a note-only fact's metadata" {
    try checkFields(.note);
}
test "promotion erase HTTP: erase scrubs a missed fact's metadata" {
    try checkFields(.missed);
}
test "promotion erase HTTP: erase scrubs a rejected fact's metadata" {
    try checkFields(.rejected);
}
test "promotion erase HTTP: erase scrubs a previously freed fact's metadata" {
    try checkFields(.freed);
}

test "promotion erase HTTP: saved and loaded JSON has no erased text in facts, pairs or night reports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    try testing.expectEqual(@as(u16, 200), (try c.erase()).status);
    try c.persistedScrubbed();
}

test "promotion erase HTTP: GET promotion does not serve the erased text from its cached report" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    try testing.expectEqual(@as(u16, 200), (try c.erase()).status);
    const got = try rig.request(c.r.srv, c.a, "GET", "/v1/promotion", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, marker) == null);
    try c.controlIntact();
}

fn failedThenRetry(fault: enum { neuron, state, publish }, check_report: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    switch (fault) {
        .neuron => c.learner.refuse = true,
        .state => promoter.Promoter.fail_persist = true,
        .publish => promoter.Promoter.fail_publish = true,
    }
    const failed = try c.erase();
    try testing.expectEqual(@as(u16, 200), failed.status);
    try testing.expect(failed.value.get("promotion").?.get("pending").?.bool);
    if (check_report) {
        try testing.expect(!failed.value.get("complete").?.bool);
        try testing.expect(failed.value.get("retryable").?.bool);
    }
    c.learner.refuse = false;
    promoter.Promoter.fail_persist = false;
    promoter.Promoter.fail_publish = false;
    try testing.expectEqual(@as(u16, 200), (try c.erase()).status);
    try c.fieldsScrubbed();
    try c.persistedScrubbed();
}

test "promotion erase HTTP: neuron failure reports incomplete and the same DELETE retries" {
    try failedThenRetry(.neuron, true);
}
test "promotion erase HTTP: state failure reports incomplete and the same DELETE retries" {
    try failedThenRetry(.state, true);
}
test "promotion erase HTTP: publish failure reports incomplete and the same DELETE retries" {
    try failedThenRetry(.publish, true);
}

fn legacyProbeLog(check_report: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    const log_path = try std.fmt.allocPrint(c.a, "{s}-probes.jsonl", .{c.path});
    const line = try std.fmt.allocPrint(c.a, "{{\"night\":1,\"kind\":\"fact\",\"key\":\"{s}\",\"q\":\"What is my locker code?\",\"before\":\"7419\",\"after\":\"7419\",\"ok\":true}}\n", .{c.key});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = log_path, .data = line });
    const erased = try c.erase();
    try testing.expectEqual(@as(u16, 200), erased.status);
    const remaining_bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, log_path, c.a, .limited(8 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (std.mem.indexOf(u8, remaining_bytes, marker) == null) return;
    if (check_report) try testing.expect(!erased.value.get("complete").?.bool);
    const remaining = erased.value.get("remaining_places") orelse return error.ProbeLogNotNamed;
    for (remaining.items() orelse return error.ProbeLogNotNamed) |place| {
        if (place != .string) continue;
        if (std.mem.indexOf(u8, place.string, "promot") != null and std.mem.indexOf(u8, place.string, "prob") != null) return;
    }
    return error.ProbeLogNotNamed;
}

test "promotion erase HTTP: neuron pending retry preserves the unrelated note and original identity" {
    try failedThenRetry(.neuron, false);
}
test "promotion erase HTTP: state pending retry preserves the unrelated note and original identity" {
    try failedThenRetry(.state, false);
}
test "promotion erase HTTP: publish pending retry preserves the unrelated note and original identity" {
    try failedThenRetry(.publish, false);
}
test "promotion erase HTTP: retained legacy probe text prevents complete true" {
    try legacyProbeLog(true);
}
test "promotion erase HTTP: retained legacy probe text is explicitly named under remaining places" {
    try legacyProbeLog(false);
}

test "promotion erase HTTP: erase drops the partner copy on the unrelated fact and preserves its neurons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    try testing.expectEqual(@as(u16, 200), (try c.erase()).status);
    try c.controlIntact();
    const f = c.p.state.find(c.control_key).?;
    if (f.pair) |pair| {
        try testing.expect(std.mem.indexOf(u8, pair.text, marker) == null);
        try testing.expect(std.mem.indexOf(u8, pair.q, marker) == null);
        try testing.expect(std.mem.indexOf(u8, pair.ref, marker) == null);
    }
}

test "promotion erase HTTP: erase reply names the other fact whose pair was dropped or rebuilt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    const erased = try c.erase();
    try testing.expectEqual(@as(u16, 200), erased.status);
    try testing.expect(std.mem.indexOf(u8, erased.body, c.control_key) != null);
    try c.controlIntact();
}

fn afterRetirement(restart: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    c.learner.fail_state_after_save = true;
    const failed = try c.erase();
    try testing.expect(failed.value.get("retryable").?.bool);
    try testing.expect(failed.value.get("promotion").?.get("pending").?.bool);
    try testing.expect(!c.learner.live_slot and c.learner.zeroed == 2);
    c.learner.fail_state_after_save = false;
    promoter.Promoter.fail_persist = false;
    if (restart) {
        c.r.srv.promote = null;
        c.p.deinit();
        var why: []const u8 = "";
        c.p = try promoter.Promoter.init(testing.allocator, testing.io, c.r.srv, c.r.store(), c.r.snap, .{ .every_ms = 600_000 }, &why);
        c.r.srv.promote = c.p;
    }
    const lesson = [_]api.Example{.{ .ids = &.{ 1, 2 }, .start = 1, .decide = 0 }};
    const slide = @import("slide.zig");
    try testing.expect(slide.run(c.r.srv, c.a, &.{ .train = &lesson }, 0) == .failed);
    try testing.expectEqual(@as(usize, 0), c.learner.trained);
    c.r.srv.teacher.learning.lockUncancelable(testing.io);
    const settled = c.p.drainPending();
    c.r.srv.teacher.learning.unlock(testing.io);
    try testing.expect(settled);
    try c.persistedScrubbed();
    try c.controlIntact();
    try testing.expect(slide.run(c.r.srv, c.a, &.{ .train = &lesson }, 0) != .failed);
    const before_retry = c.learner.zeroed;
    const retried = try c.erase();
    try testing.expect(!retried.value.get("retryable").?.bool);
    try testing.expect(c.learner.live_slot);
    try testing.expectEqual(before_retry, c.learner.zeroed);
    try c.controlIntact();
}

test "promotion erase HTTP: state failure after retirement fences slot reuse until same-process recovery" {
    try afterRetirement(false);
}
test "promotion erase HTTP: state failure after retirement fences slot reuse across restart" {
    try afterRetirement(true);
}
test "promotion erase HTTP: a busy night hides cached report text and leaves the same erase retryable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    c.r.srv.teacher.learning.lockUncancelable(testing.io);
    const erased = c.erase() catch |e| {
        c.r.srv.teacher.learning.unlock(testing.io);
        return e;
    };
    c.r.srv.teacher.learning.unlock(testing.io);
    try testing.expect(erased.value.get("retryable").?.bool);
    const report = try rig.request(c.r.srv, c.a, "GET", "/v1/promotion", null);
    try testing.expect(std.mem.indexOf(u8, report.body, marker) == null);
    try testing.expectEqual(@as(u16, 200), (try c.erase()).status);
    try c.persistedScrubbed();
}

test "promotion erase HTTP: disabling promotion names its retained state and neurons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try Case.init(arena.allocator(), .in_weights);
    defer c.deinit();
    c.r.srv.promote = null;
    const reply = try c.erase();
    try testing.expectEqual(@as(u16, 200), reply.status);
    try testing.expect(!reply.value.get("complete").?.bool);
    const places = reply.value.get("places").?;
    try testing.expectEqualStrings("may_hold", places.strField("promotion_state").?);
    try testing.expectEqualStrings("may_hold", places.strField("promotion_neurons").?);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, c.path, c.a, .limited(8 << 20));
    try testing.expect(std.mem.indexOf(u8, bytes, marker) != null);
    c.r.srv.promote = c.p;
}
