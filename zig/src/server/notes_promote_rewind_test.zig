//! A refused night put back exactly: the learner, the state file, the graph and the teacher as the night found them.
const std = @import("std");
const api = @import("engine_api");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const slide = @import("slide.zig");
const testing = std.testing;
const Neuron = promote.Neuron;

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
    // control: with its mark the same rewind goes through, puts both back and saves
    e.marked = true;
    try testing.expect(slide.rewind(r.srv, a, m, "taken back"));
    try testing.expectEqual(slide_graph_state.learned, r.srv.slide.facts.items[0].state);
    try testing.expectEqual(@as(usize, 0), r.srv.teacher.lessons);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, e.letters.items, "s"));
}

const slide_graph_state = @import("slide_graph.zig").State;
