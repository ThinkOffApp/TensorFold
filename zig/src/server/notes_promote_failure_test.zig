//! Promotion when a write fails: a zeroing, a rewind or the state file; the night fails and every record agrees after.
const std = @import("std");
const api = @import("engine_api");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const slide = @import("slide.zig");
const slide_graph = @import("slide_graph.zig");
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

const kite: promote.Note = .{ .id = 1, .key = "w1", .text = "My kite is orange.", .told = 100, .fact = true };

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
