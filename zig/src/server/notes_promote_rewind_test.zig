//! A refused night put back exactly: the learner, the state file, the graph and the teacher as the night found them.
const std = @import("std");
const api = @import("engine_api");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const notes_promote = @import("notes_promote.zig");
const slide = @import("slide.zig");
const scripted = @import("notes_promote_test.zig");
const testing = std.testing;
const Fake = scripted.Fake;
const Live = scripted.Live;
const Neuron = promote.Neuron;

fn status(s: *promote.State, key: []const u8) promote.Status {
    return (s.find(key) orelse return .note).status;
}

/// The fake pocket's facts, field for field: what the learner holds.
fn expectPocket(want: []const Live, got: []const Live) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| {
        try testing.expectEqualStrings(x.text, y.text);
        try testing.expectEqual(x.live, y.live);
        try testing.expectEqual(x.fits, y.fits);
        try testing.expectEqualSlices(Neuron, x.neurons, y.neurons);
    }
}

test "promotion: a refused add-night leaves the learner as the night found it, an earlier fact's refit included" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .a = a };
    _ = try f.add("w1", "dog=Luna");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try promote.night(&s, a, &f);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
    // the boat's lesson refits the dog's neurons and breaks a control: the night is refused
    f.breaks = "boat=blue";
    f.refits = "boat=blue";
    _ = try f.add("w2", "boat=blue");
    const pocket = try a.dupe(Live, f.pocket.items);
    const next = f.next_neuron;
    const placed = try a.dupe(Neuron, s.pocket);
    const n = try promote.night(&s, a, &f);
    try testing.expectEqual(@as(u32, 1), n.rejected);
    try testing.expectEqualStrings("none", n.plan);
    try testing.expectEqual(promote.Status.rejected, status(&s, "w2"));
    // the learner: the dog's neurons as they were (never refitted), no boat, its neuron places free again
    try expectPocket(pocket, f.pocket.items);
    try testing.expectEqual(next, f.next_neuron);
    try testing.expect(f.marked == null); // the rewind let the mark go
    // the state, in memory and in its file, holds the pocket as it is
    try testing.expectEqualSlices(Neuron, placed, s.pocket);
    try testing.expectEqualSlices(Neuron, placed, s.find("w1").?.neurons);
    var back = try pjson.decode(testing.allocator, f.saved.?, .{});
    defer back.deinit();
    try testing.expectEqualSlices(Neuron, placed, back.pocket);
    try testing.expectEqual(promote.Status.rejected, status(&back, "w2"));
    try testing.expectEqualStrings("Paris", (try f.askAll(a, &.{.{ .q = "What is the capital of France?" }}))[0]);
}

test "promotion: each rebuild plan starts from the pocket as the night found it; a refused one's refits never reach the next" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .a = a };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "boat=blue");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try promote.night(&s, a, &f);
    // a chat fact the user taught outside promotion: no rebuild zeroes it, and it stays as it is
    try f.pocket.append(a, .{ .topic = "tent", .value = "red", .neurons = try a.dupe(Neuron, &.{.{ .layer = 2, .neuron = 0, .key = .reply }}), .text = "tent=red" });
    try f.change("w1", "w3", "dog=Bruno");
    f.breaks = "boat=blue"; // every plan that teaches the boat again is refused
    f.refits = "dog=Bruno"; // and the first one's lesson for the new dog refits every live neuron
    const next = f.next_neuron;
    const n = try promote.night(&s, a, &f);
    try testing.expectEqualStrings("source", n.plan);
    try testing.expectEqual(@as(u32, 3), n.tries); // rebuild, rebuild-old, source
    try testing.expectEqual(@as(u32, 2), n.rejected);
    // the chat fact: live, never refitted; the refused plans' neurons gone with their places
    const tent = f.pocket.items[2];
    try testing.expectEqualStrings("tent=red", tent.text);
    try testing.expect(tent.live);
    try testing.expectEqual(@as(u32, 0), tent.fits);
    try testing.expectEqual(@as(usize, 3), f.pocket.items.len);
    try testing.expectEqual(next, f.next_neuron);
    try testing.expectEqual(@as(usize, 0), s.pocket.len);
    try testing.expectEqual(promote.Status.note, status(&s, "w2"));
    try testing.expectEqual(promote.Status.rejected, status(&s, "w3"));
}

/// Answers "x" from a mark to its rewind, else "o"; logs learn requests (m mark, w rewind, s save, r retire) by letter.
const Engine = struct {
    srv: ?*@import("server.zig").Server = null,
    a: std.mem.Allocator,
    marked: bool = false,
    letters: std.ArrayList(u8) = .empty,
    zeroed: std.ArrayList(Neuron) = .empty,
    replaced: u32 = 0, // the graph fact a night's lesson replaces
    erase: ?i64 = null, // the note erased while the night runs
    pending: ?bool = null, // whether that erase was left for the night's end

    fn engine(e: *Engine) api.Engine {
        return .{ .ctx = e, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = statusOf, .memory = memory, .learn = learn } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn submit(ctx: *anyopaque, id: api.Id, _: *const api.Request, sink: api.Sink) api.SubmitError!void {
        const e: *Engine = @ptrCast(@alignCast(ctx));
        sink.event(sink.ctx, id, &.{ .prefilled = 0 });
        sink.event(sink.ctx, id, &.{ .tokens = if (e.marked) &.{'x'} else &.{'o'} });
        sink.event(sink.ctx, id, &.{ .finished = .{ .reason = .stop } });
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn statusOf(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    fn learn(ctx: *anyopaque, req: *const api.LearnRequest, sink: api.LearnSink) api.LearnError!void {
        const e: *Engine = @ptrCast(@alignCast(ctx));
        if (req.rewind and !e.marked) return sink.event(sink.ctx, &.{ .done = .{ .message = "NothingToRewind" } });
        const letter: u8 = if (req.mark) 'm' else if (req.rewind) 'w' else if (req.save) 's' else if (req.retire.len > 0) 'r' else '?';
        e.letters.append(e.a, letter) catch {};
        e.zeroed.appendSlice(e.a, req.retire) catch {};
        if (req.rewind) e.marked = false;
        if (req.mark) e.marked = true;
        // the night's first save, after its first lesson: what that lesson did beside the pocket
        if (req.save and e.marked) e.night() catch {};
        sink.event(sink.ctx, &.{ .done = .{} });
    }

    /// What a night's lessons do beside the pocket: a learned fact replaced, a lesson kept, and the user erases a note.
    fn night(e: *Engine) !void {
        const srv = e.srv orelse return;
        if (e.replaced == 0) return;
        defer e.replaced = 0;
        srv.slide.mark(e.replaced, .replaced);
        srv.slide.note(e.replaced, "replaced by a fact taught tonight");
        srv.teacher.ended(true);
        try srv.teacher.remember("my boat", "What colour is my boat?", "Blue.");
        const id = e.erase orelse return;
        e.erase = null;
        const er = try rig.request(srv, e.a, "DELETE", try std.fmt.allocPrint(e.a, "/v1/notes/{d}?erase=true", .{id}), null);
        e.pending = er.value.get("promotion").?.get("pending").?.bool;
    }
};

test "promotion rig: a refused night rewinds the learner, then saves; the graph and teacher go back; an erase lands after" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var e: Engine = .{ .a = a };
    r.srv.engine = e.engine();
    // a kite note in weights (two neurons), a tent note due tonight
    const kite = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
    const tent = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My tent is red.\", \"subject\": \"my tent\"}");
    const kite_neurons = [_]Neuron{ .{ .layer = 3, .neuron = 0, .key = .reply }, .{ .layer = 7, .neuron = 0, .key = .subject } };
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    try st.facts.append(st.alloc(), .{ .key = kite.value.strField("source").?, .text = "My kite is orange.", .status = .in_weights, .alone = 2, .neurons = &kite_neurons });
    st.pocket = &kite_neurons;
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
    // the graph and teacher as the night finds them: a learned chat fact with its neurons, three lessons kept
    const boat = r.srv.slide.add("My boat is green.", "chat", 1);
    r.srv.slide.mark(boat, .learned);
    r.srv.slide.placed(boat, &.{.{ .layer = 5, .neuron = 1, .key = .reply }});
    r.srv.slide.note(boat, "learned");
    r.srv.teacher.lessons = 3;
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    defer p.deinit();
    r.srv.promote = p;
    defer r.srv.promote = null;
    try p.retrieved.put(p.gpa, tent.value.strField("source").?, {});
    e.srv = r.srv;
    e.replaced = boat;
    e.erase = kite.value.get("id").?.int64().?;
    p.runNight();
    try testing.expectEqual(@as(usize, 0), p.state.nights.items.len);
    try testing.expect(p.state.rebuild_next);
    try testing.expectEqual(promote.Status.note, status(&p.state, tent.value.strField("source").?));
    // mark, the lesson's save, the rewind (no retire; it writes the files itself), then the erase's zeroing and save
    try testing.expectEqual(@as(?bool, true), e.pending); // the night held the learner: the erase waited for its end
    try testing.expectEqualStrings("mswrs", e.letters.items);
    try testing.expectEqualSlices(Neuron, &kite_neurons, e.zeroed.items);
    try testing.expectEqual(promote.Status.freed, status(&p.state, kite.value.strField("source").?));
    try testing.expectEqual(@as(usize, 0), p.state.pocket.len);
    // the graph: the boat learned again with its neurons and message; the tent, taught tonight, taken back
    const facts = r.srv.slide.facts.items;
    try testing.expectEqual(slide_graph_state.learned, facts[0].state);
    try testing.expectEqual(@as(usize, 1), facts[0].neurons.len);
    try testing.expectEqualStrings("learned", facts[0].message);
    try testing.expect(facts.len >= 2);
    for (facts[1..]) |x| {
        try testing.expectEqual(slide_graph_state.missed, x.state);
        try testing.expectEqual(@as(usize, 0), x.neurons.len);
        try testing.expect(std.mem.startsWith(u8, x.message, "taken back"));
    }
    // the teacher: three lessons kept, no answer told tonight
    try testing.expectEqual(@as(usize, 3), r.srv.teacher.lessons);
    try testing.expectEqual(@as(usize, 0), r.srv.teacher.told.items.len);
    // and the state file says so
    var back = try pjson.decode(testing.allocator, try r.tmp.dir.readFileAlloc(testing.io, "snap.json.promote", a, .limited(1 << 22)), .{});
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.pocket.len);
    try testing.expectEqual(promote.Status.freed, status(&back, kite.value.strField("source").?));
}

test "promotion rig: a rewind the learner refuses (no mark) is reported, and the graph and teacher are left alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var e: Engine = .{ .a = a };
    r.srv.engine = e.engine();
    const boat = r.srv.slide.add("My boat is green.", "chat", 1);
    r.srv.slide.mark(boat, .learned);
    const m = slide.mark(r.srv, a).?;
    try testing.expect(e.marked);
    r.srv.slide.mark(boat, .replaced);
    r.srv.teacher.ended(true);
    e.marked = false; // the learner lost its mark (a restart of the engine, say)
    try testing.expect(!slide.rewind(r.srv, a, m, "taken back"));
    try testing.expectEqual(slide_graph_state.replaced, r.srv.slide.facts.items[0].state);
    try testing.expectEqual(@as(usize, 1), r.srv.teacher.lessons);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, e.letters.items, "s")); // and nothing saved
    try testing.expectEqualStrings("failed", @tagName(r.srv.slide.saved.state)); // the graph's save view says so
    // control: with its mark the same rewind goes through (writing the files itself) and puts both back
    e.marked = true;
    try testing.expect(slide.rewind(r.srv, a, m, "taken back"));
    try testing.expectEqual(slide_graph_state.learned, r.srv.slide.facts.items[0].state);
    try testing.expectEqual(@as(usize, 0), r.srv.teacher.lessons);
    try testing.expectEqualStrings("mw", e.letters.items);
    try testing.expectEqualStrings("saved", @tagName(r.srv.slide.saved.state));
}

const slide_graph_state = @import("slide_graph.zig").State;
