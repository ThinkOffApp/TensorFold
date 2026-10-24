//! Promotion when a write fails: a zeroing, a rewind or the state file; the night fails and every record agrees after.
const std = @import("std");
const api = @import("engine_api");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const notes_promote = @import("notes_promote.zig");
const slide = @import("slide.zig");
const slide_graph = @import("slide_graph.zig");
const Server = @import("server.zig").Server;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Neuron = promote.Neuron;

const places = 64; // one layer's pocket
const layer = 3;

/// One layer's pocket behind the engine API, in memory and in the files: each place's fact (its graph id; 0: zero).
const Pocket = struct {
    ram: [places]u32 = @splat(0),
    used: usize = 0,
    disk: [places]u32 = @splat(0),
    marked: ?[places]u32 = null,
    marked_used: usize = 0,
    fail_rewind: bool = false, // the next rewind's write fails: as pocket_mark.rewind, nothing changes then
    fail_save: bool = false, // the next save fails before it writes anything
    breaks: u32 = 0, // the fact whose live neurons change every answer

    fn engine(e: *Pocket) api.Engine {
        return .{ .ctx = e, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = statusOf, .memory = memory, .learn = learn } };
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
    fn statusOf(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    fn learn(ctx: *anyopaque, req: *const api.LearnRequest, sink: api.LearnSink) api.LearnError!void {
        const e: *Pocket = @ptrCast(@alignCast(ctx));
        sink.event(sink.ctx, &.{ .done = .{ .message = e.apply(req) orelse "" } });
    }

    /// One learn request as the pocket's learner takes it; the reason it failed, or null.
    fn apply(e: *Pocket, req: *const api.LearnRequest) ?[]const u8 {
        if (req.mark) {
            e.marked = e.ram;
            e.marked_used = e.used;
        } else if (req.rewind) {
            const m = e.marked orelse return "NothingToRewind";
            if (e.fail_rewind) {
                e.fail_rewind = false;
                return "DiskFull";
            }
            e.disk = m;
            e.ram = m;
            e.used = e.marked_used;
            e.marked = null;
        } else if (req.save) {
            if (e.fail_save) {
                e.fail_save = false;
                return "DiskFull";
            }
            e.disk = e.ram;
        } else {
            for (req.retire) |n| {
                if (n.layer == layer and n.neuron < e.used) e.ram[n.neuron] = 0;
            }
        }
        return null;
    }

    /// A kept lesson of fact `id`: two places taken and filled, then the files written, as teachText leaves them.
    fn lesson(e: *Pocket, id: u32) [2]Neuron {
        var out: [2]Neuron = undefined;
        for (&out) |*n| {
            e.ram[e.used] = id;
            n.* = .{ .layer = layer, .neuron = @intCast(e.used), .key = .reply };
            e.used += 1;
        }
        e.disk = e.ram;
        return out;
    }

    /// A restart: memory as the files hold it, in use through the last place that is not zero (as the loaders count).
    fn restart(e: *Pocket) void {
        e.ram = e.disk;
        e.used = 0;
        for (e.disk, 0..) |x, i| {
            if (x != 0) e.used = i + 1;
        }
        e.marked = null;
    }

    fn live(e: *const Pocket, id: u32) bool {
        return std.mem.indexOfScalar(u32, e.ram[0..e.used], id) != null;
    }

    fn onDisk(e: *const Pocket, id: u32) bool {
        return std.mem.indexOfScalar(u32, &e.disk, id) != null;
    }

    /// Every live place as a neuron.
    fn liveNeurons(e: *const Pocket, a: Allocator) ![]const Neuron {
        var out: std.ArrayList(Neuron) = .empty;
        for (e.ram[0..e.used], 0..) |id, i| if (id != 0) try out.append(a, .{ .layer = layer, .neuron = @intCast(i), .key = .reply });
        return out.items;
    }
};

/// The promotion backend over the server's own parts, as notes_promote's Backend: slide's mark, rewind and retire.
const Night = struct {
    srv: *Server,
    e: *Pocket,
    path: []const u8, // the state file
    listed: []const promote.Note = &.{},
    breaks: []const u8 = "", // a fact whose lesson makes every answer change
    fail_after_rewind: bool = false, // from a good rewind on, the state is not written (Promoter.fail_persist)
    marked: ?slide.Mark = null,

    pub fn nowMs(_: *Night) i64 {
        return 0;
    }
    pub fn notes(n: *Night, a: Allocator) ![]promote.Note {
        return a.dupe(promote.Note, n.listed);
    }
    pub fn firstSeen(_: *Night, _: []const u8) ?u32 {
        return null;
    }
    pub fn wasRetrieved(_: *Night, _: []const u8) bool {
        return true;
    }
    pub fn placedFor(n: *Night, a: Allocator, text: []const u8) ![]const Neuron {
        const graph = try n.srv.slide.learnedChat(a, 0, std.math.maxInt(usize));
        var out: std.ArrayList(Neuron) = .empty;
        for (graph) |g| if (std.mem.eql(u8, g.text, text)) try out.appendSlice(a, g.neurons);
        return out.items;
    }
    /// A kept lesson as teachText leaves one: the fact learned in the graph with its neurons, placed, saved, counted.
    pub fn teach(n: *Night, a: Allocator, text: []const u8) !promote.Taught {
        const id = n.srv.slide.add(text, "chat", 1);
        const ns = n.e.lesson(id);
        n.srv.slide.placed(id, &ns); // placed, then marked learned, which writes the graph's file
        n.srv.slide.mark(id, .learned);
        n.srv.teacher.ended(true);
        if (std.mem.eql(u8, text, n.breaks)) n.e.breaks = id;
        return .{ .kept = true, .neurons = try a.dupe(Neuron, &ns) };
    }
    pub fn retire(n: *Night, a: Allocator, ns: []const Neuron) !void {
        if (!slide.retire(n.srv, a, ns)) return error.RetireRefused;
    }
    pub fn mark(n: *Night, a: Allocator) !void {
        n.marked = slide.mark(n.srv, a) orelse return error.MarkRefused;
    }
    pub fn rewind(n: *Night, a: Allocator) !void {
        const m = n.marked orelse return error.NothingToRewind;
        if (!slide.rewind(n.srv, a, m, "taken back: the night that taught it made answers worse")) return error.RewindRefused;
        n.marked = null;
        if (n.fail_after_rewind) notes_promote.Promoter.fail_persist = true;
    }
    pub fn persist(n: *Night, s: *const promote.State) !void {
        if (notes_promote.Promoter.fail_persist) return error.PersistFailed;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try pjson.writeFile(arena.allocator(), n.path, try pjson.encode(s, arena.allocator()));
    }
    pub fn askAll(n: *Night, a: Allocator, asks: []const promote.Ask) ![]const []const u8 {
        const out = try a.alloc([]const u8, asks.len);
        @memset(out, if (n.e.breaks != 0 and n.e.live(n.e.breaks)) "x" else "o");
        return out;
    }
    pub fn same(_: *Night, _: Allocator, _: []const u8, before: []const u8, reply: []const u8) !bool {
        return std.mem.eql(u8, before, reply);
    }
    pub fn agrees(_: *Night, _: []const u8, _: []const u8, ref: []const u8, reply: []const u8) bool {
        return std.mem.eql(u8, ref, reply);
    }
    pub fn subjects(_: *Night, _: Allocator) ![]const []const u8 {
        return &.{};
    }
    pub fn texts(_: *Night, _: Allocator) ![]const []const u8 {
        return &.{};
    }
    pub fn recordProbe(_: *Night, _: promote.Record) void {}
    pub fn gives(_: *Night, _: []const u8, _: []const u8, _: []const u8) bool {
        return true;
    }
    pub fn referenceAgain(_: *Night, _: Allocator, _: []const u8, _: []const u8) ![]const u8 {
        return "o";
    }
    pub fn references(_: *Night, a: Allocator, _: []const u8, qs: []const []const u8) ![]const []const u8 {
        const out = try a.alloc([]const u8, qs.len);
        @memset(out, "o");
        return out;
    }
    pub fn questionOf(_: *Night, _: Allocator, _: []const u8) ![]const u8 {
        return "";
    }
    pub fn neighbours(_: *Night, _: Allocator, _: []const u8) ![]const []const u8 {
        return &.{};
    }
    pub fn pairQuestion(_: *Night, _: Allocator, _: []const u8, _: []const u8) ![]const u8 {
        return "";
    }
};

const settings: promote.Settings = .{ .targeted = false, .regress_notes = 0 }; // the controls only
const kite: promote.Note = .{ .id = 1, .key = "w1", .text = "My kite is orange.", .told = 100, .fact = true };
const tent: promote.Note = .{ .id = 2, .key = "w2", .text = "My tent is red.", .told = 200, .fact = true };

fn graphFact(g: *slide_graph.Graph, id: u32) ?*const slide_graph.Fact {
    for (g.facts.items) |*f| if (f.id == id) return f;
    return null;
}

fn listed(ns: []const Neuron, n: Neuron) bool {
    for (ns) |x| if (x.layer == n.layer and x.neuron == n.neuron) return true;
    return false;
}

/// The pocket and the graph agree: each live place is listed by its own learned fact, each listed neuron is live.
fn expectGraphAgrees(e: *const Pocket, g: *slide_graph.Graph) !void {
    for (e.ram[0..e.used], 0..) |id, i| {
        if (id == 0) continue;
        const f = graphFact(g, id) orelse return error.LiveButNotInGraph;
        try testing.expectEqual(slide_graph.State.learned, f.state);
        if (!listed(f.neurons, .{ .layer = layer, .neuron = @intCast(i), .key = .reply })) return error.LiveButNotListed;
    }
    for (g.facts.items) |f| for (f.neurons) |x| {
        if (x.neuron >= e.used or e.ram[x.neuron] != f.id) return error.ListedButNotLive;
    };
}

/// The state's pocket, as `s` holds it, holds every live neuron but fact `other`'s; `exact`: nothing else either.
fn expectStateHolds(e: *const Pocket, a: Allocator, s: *const promote.State, exact: bool, other: u32) !void {
    var n: usize = 0;
    for (try e.liveNeurons(a)) |x| if (e.ram[x.neuron] != other) {
        if (!promote.has(s.pocket, x)) return error.LiveButNotInState;
        n += 1;
    };
    if (exact) try testing.expectEqual(n, s.pocket.len);
}

fn readState(r: *rig.Rig, a: Allocator) !promote.State {
    return pjson.decode(testing.allocator, try r.tmp.dir.readFileAlloc(testing.io, "night.promote", a, .limited(1 << 22)), settings);
}

/// A server whose graph lives in a file, its engine the pocket; a first night promotes the kite.
fn setUp(r: *rig.Rig, a: Allocator, e: *Pocket, s: *promote.State) !Night {
    r.srv.engine = e.engine();
    r.srv.slide.deinit();
    r.srv.slide = .init(testing.allocator, testing.io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/graph.json", .{r.tmp.sub_path}));
    var n: Night = .{ .srv = r.srv, .e = e, .path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/night.promote", .{r.tmp.sub_path}), .listed = &.{kite} };
    const first = try promote.night(s, a, &n);
    try testing.expectEqualStrings("add", first.plan);
    try testing.expectEqual(promote.Status.promoted, s.find("w1").?.status);
    n.listed = &.{ kite, tent };
    n.breaks = tent.text; // tonight's tent lesson changes every control's answer: the add plan is refused
    return n;
}

/// The server started again: the pocket and the graph as their files hold them, a new teacher, the state file read.
fn restart(r: *rig.Rig, a: Allocator, e: *Pocket) !promote.State {
    e.restart();
    const path = r.srv.slide.path;
    r.srv.slide.deinit();
    r.srv.slide = .init(testing.allocator, testing.io, path);
    r.srv.teacher.deinit();
    r.srv.teacher = .init(testing.allocator);
    return readState(r, a);
}

/// The night after the restart rebuilds, and then the pocket, the graph, the teacher and the state file all agree.
fn rebuildAndAgree(r: *rig.Rig, a: Allocator, n: *Night, s: *promote.State, refused: u32, other: u32) !void {
    try testing.expect(s.rebuild_next);
    n.breaks = "";
    n.e.breaks = 0;
    const log = try promote.night(s, a, n);
    try testing.expectEqualStrings("rebuild", log.plan);
    try testing.expect(!n.e.live(refused)); // nothing of the refused night is live
    try expectGraphAgrees(n.e, &r.srv.slide);
    try expectStateHolds(n.e, a, s, true, other);
    try testing.expectEqualSlices(u32, &n.e.ram, &n.e.disk); // the files hold the pocket as it is
    try testing.expectEqual(@as(usize, 2), r.srv.teacher.lessons); // the two lessons kept since the start
    var back = try readState(r, a);
    defer back.deinit();
    try testing.expectEqualSlices(Neuron, s.pocket, back.pocket);
    try testing.expect(back.open == null and !back.rebuild_next);
}

test "promotion rig: a refused night whose rewind cannot write fails, changes nothing, and the next start rebuilds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var e: Pocket = .{};
    var s = promote.State.init(testing.allocator, settings);
    defer s.deinit();
    var n = try setUp(r, a, &e, &s);
    e.fail_rewind = true;
    try testing.expectError(error.RewindRefused, promote.nightOrRebuild(&s, a, &n));
    n.persist(&s) catch {}; // runNight's failure path writes the state again
    try testing.expect(s.rebuild_next and s.nights_done == 1); // a failure, never reported as a night done
    // nothing moved: tonight's tent is live in memory and in the files, the graph and the teacher say so
    const night_tent = e.breaks;
    try testing.expect(e.live(night_tent) and e.onDisk(night_tent));
    try testing.expectEqual(slide_graph.State.learned, graphFact(&r.srv.slide, night_tent).?.state);
    try expectGraphAgrees(&e, &r.srv.slide);
    try testing.expectEqual(@as(usize, 2), r.srv.teacher.lessons);
    try expectStateHolds(&e, a, &s, true, 0);
    {
        var file = try readState(r, a);
        defer file.deinit();
        try expectStateHolds(&e, a, &file, false, 0);
    }
    // a chat lesson before the restart takes new places: none the files and the state still give tonight's tent
    const boat = r.srv.slide.add("My boat is green.", "chat", 1);
    const boat_neurons = e.lesson(boat);
    r.srv.slide.placed(boat, &boat_neurons);
    r.srv.slide.mark(boat, .learned);
    var after = try restart(r, a, &e);
    defer after.deinit();
    try testing.expect(e.live(night_tent)); // the files hold it, and the state file lists it to zero
    try rebuildAndAgree(r, a, &n, &after, night_tent, boat);
    try testing.expect(e.live(boat)); // the rebuild zeroed tonight's tent, not the boat
}

test "promotion rig: a refused night whose state is not written after the rewind fails, and the next start rebuilds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var e: Pocket = .{};
    var s = promote.State.init(testing.allocator, settings);
    defer s.deinit();
    var n = try setUp(r, a, &e, &s);
    n.fail_after_rewind = true;
    defer notes_promote.Promoter.fail_persist = false;
    try testing.expectError(error.PersistFailed, promote.nightOrRebuild(&s, a, &n));
    n.persist(&s) catch {}; // runNight's failure path: it fails too, so the file keeps tonight's neurons
    notes_promote.Promoter.fail_persist = false;
    n.fail_after_rewind = false;
    try testing.expect(s.rebuild_next and s.nights_done == 1);
    // the rewind went through: memory, files, graph and teacher as the night found them; the state in memory too
    const night_tent = e.breaks;
    try testing.expect(!e.live(night_tent) and !e.onDisk(night_tent));
    try testing.expectEqual(slide_graph.State.missed, graphFact(&r.srv.slide, night_tent).?.state);
    try expectGraphAgrees(&e, &r.srv.slide);
    try testing.expectEqual(@as(usize, 1), r.srv.teacher.lessons);
    try expectStateHolds(&e, a, &s, true, 0);
    {
        var file = try readState(r, a); // stale: it still lists tonight's neurons, with the night open
        defer file.deinit();
        try testing.expect(file.open != null and file.pocket.len > s.pocket.len);
    }
    var after = try restart(r, a, &e);
    defer after.deinit();
    try rebuildAndAgree(r, a, &n, &after, night_tent, 0);
}

test "promotion rig: a zeroing whose save fails is not done: the graph keeps the neurons the files still hold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var e: Pocket = .{};
    r.srv.engine = e.engine();
    const id = r.srv.slide.add(kite.text, "chat", 1);
    const ns = e.lesson(id);
    r.srv.slide.placed(id, &ns);
    r.srv.slide.mark(id, .learned);
    e.fail_save = true;
    try testing.expect(!slide.retire(r.srv, a, &ns));
    try testing.expect(e.onDisk(id));
    try testing.expectEqual(@as(usize, 2), graphFact(&r.srv.slide, id).?.neurons.len);
    // control: with the disk back the same zeroing goes through, and the graph lets go of the neurons
    try testing.expect(slide.retire(r.srv, a, &ns));
    try testing.expect(!e.onDisk(id) and !e.live(id));
    try testing.expectEqual(@as(usize, 0), graphFact(&r.srv.slide, id).?.neurons.len);
    try expectGraphAgrees(&e, &r.srv.slide);
}
