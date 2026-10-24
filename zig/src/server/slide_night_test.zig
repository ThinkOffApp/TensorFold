//! Promotion controls through the real server learner bridge, including graph failures after physical rewind.
const std = @import("std");
const api = @import("engine_api");
const Server = @import("server.zig").Server;
const Graph = @import("slide_graph.zig").Graph;
const slide = @import("slide.zig");
const night = @import("slide_night.zig");
const Bytes = @import("notes_storage_bytes_test.zig").Bytes;
const t = std.testing;

const Engine = struct {
    marks: usize = 0,
    rewinds: usize = 0,
    retires: usize = 0,
    saves: usize = 0,
    lessons: usize = 0,
    fail_save: bool = false,
    graph_rewind_failure: bool = false,
    graph_save_failure: bool = false,
    srv: ?*Server = null,
    fn engine(e: *@This()) api.Engine {
        return .{ .ctx = e, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory, .learn = learn } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn submit(_: *anyopaque, _: api.Id, _: *const api.Request, _: api.Sink) api.SubmitError!void {}
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    fn learn(ctx: *anyopaque, request: *const api.LearnRequest, sink: api.LearnSink) api.LearnError!void {
        const e: *@This() = @ptrCast(@alignCast(ctx));
        e.marks += @intFromBool(request.mark);
        e.rewinds += @intFromBool(request.rewind);
        e.retires += @intFromBool(request.retire.len > 0);
        e.saves += @intFromBool(request.save);
        e.lessons += @intFromBool(request.train.len > 0);
        if (request.rewind and e.graph_rewind_failure) {
            e.srv.?.slide.fault = .rename;
            e.graph_rewind_failure = false;
        }
        if (request.save and e.graph_save_failure) {
            e.srv.?.slide.fault = .write;
            e.graph_save_failure = false;
        }
        sink.event(sink.ctx, &.{ .done = .{ .message = if (request.save and e.fail_save) "DiskFull" else "" } });
    }
};

fn server(e: *Engine, bytes: *Bytes, path: []const u8) !*Server {
    const srv = try Server.init(t.allocator, t.io, e.engine(), bytes.text(), .{ .served_name = "m", .model_ids = &.{"m"} }, null);
    srv.slide.deinit();
    srv.slide = Graph.init(t.allocator, t.io, path);
    e.srv = srv;
    return srv;
}

const example = [_]api.Example{.{ .ids = &.{ 1, 2 }, .start = 1, .decide = 0 }};

test "promotion: graph publication after rewind retries without rewinding twice or admitting a new lesson" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/graph.json", .{tmp.sub_path});
    var e: Engine = .{};
    var bytes: Bytes = .{};
    const srv = try server(&e, &bytes, path);
    defer srv.deinit();
    const old = srv.slide.add("My boat is blue.", "chat", 1);
    srv.slide.mark(old, .learned);
    const neurons = [_]api.Neuron{.{ .layer = 2, .neuron = 1, .key = .reply }};
    srv.slide.placed(old, &neurons);
    srv.teacher.ended(true);
    const marked = slide.mark(srv, a) orelse return error.MarkFailed;
    srv.slide.mark(old, .replaced);
    const added = srv.slide.add("My tent is red.", "chat", 2);
    srv.slide.mark(added, .learned);
    srv.teacher.ended(true);
    e.graph_rewind_failure = true;
    try t.expect(!slide.rewind(srv, a, marked, "night rejected"));
    try t.expectEqual(@as(usize, 1), e.rewinds);
    try t.expectEqual(@as(usize, 2), srv.teacher.lessons);
    try t.expectEqual(@import("slide_graph.zig").State.replaced, srv.slide.find(old).?.state);
    try t.expect(slide.run(srv, a, &.{ .train = &example }, 0) == .failed);
    try t.expectEqual(@as(usize, 0), e.lessons);
    try t.expect(slide.rewind(srv, a, marked, "night rejected"));
    try t.expectEqual(@as(usize, 1), e.rewinds);
    try t.expectEqual(@as(usize, 1), srv.teacher.lessons);
    try t.expectEqual(@import("slide_graph.zig").State.learned, srv.slide.find(old).?.state);
    try t.expectEqual(@import("slide_graph.zig").State.missed, srv.slide.find(added).?.state);
    try t.expectEqualSlices(api.Neuron, &neurons, srv.slide.find(old).?.neurons);
    try t.expect(slide.run(srv, a, &.{ .train = &example }, 0) == .failed);
    night.acknowledged(srv);
    try t.expect(slide.run(srv, a, &.{ .train = &example }, 0) != .failed);
    try t.expectEqual(@as(usize, 1), e.lessons);
}

test "promotion: retirement preserves listings through save and graph failures, blocking new lessons until acknowledged" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/graph.json", .{tmp.sub_path});
    var e: Engine = .{};
    var bytes: Bytes = .{};
    const srv = try server(&e, &bytes, path);
    defer srv.deinit();
    const id = srv.slide.add("My boat is blue.", "chat", 1);
    srv.slide.mark(id, .learned);
    const neurons = [_]api.Neuron{
        .{ .layer = 2, .neuron = 1, .key = .reply },
        .{ .layer = 2, .neuron = 9, .key = .reply },
    };
    srv.slide.placed(id, &neurons);
    e.fail_save = true;
    try t.expect(!slide.retire(srv, a, neurons[0..1]));
    try t.expectEqualSlices(api.Neuron, &neurons, srv.slide.find(id).?.neurons);
    try t.expect(slide.run(srv, a, &.{ .train = &example }, 0) == .failed);
    e.fail_save = false;
    e.graph_save_failure = true;
    try t.expect(!slide.retire(srv, a, neurons[0..1]));
    try t.expectEqualSlices(api.Neuron, &neurons, srv.slide.find(id).?.neurons);
    try t.expect(slide.retire(srv, a, neurons[0..1]));
    try t.expectEqualSlices(api.Neuron, neurons[1..], srv.slide.find(id).?.neurons);
    try t.expect(slide.run(srv, a, &.{ .train = &example }, 0) == .failed);
    try t.expectEqual(@as(usize, 0), e.lessons);
    night.acknowledged(srv);
    try t.expect(slide.run(srv, a, &.{ .train = &example }, 0) != .failed);
}
