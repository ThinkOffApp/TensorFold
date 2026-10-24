//! The slide adapter: initial reader progress before its first potentially long step, and --slide's startup refusals.
const std = @import("std");
const api = @import("engine_api");
const Adapter = @import("slide_adapter.zig").Adapter;
const refusal = @import("slide_adapter.zig").refusal;
const Fixture = struct {
    pub const Example = api.Example;
    pub const Learner = struct {
        pub const Progress = struct { phase: enum { read, fit, values, check, done }, at: usize, of: usize, loss: f32 };
        pub const Placed = api.Neuron;
        marked: bool = false,
        rewound: bool = false,
        pub fn init(_: std.mem.Allocator, _: std.Io, _: void) @This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn begin(l: *@This(), request: anytype) !void {
            l.marked = request.mark;
            l.rewound = request.rewind;
        }
        pub fn abort(_: *@This()) void {}
        pub fn progress(_: *@This()) ?Progress {
            return .{ .phase = .read, .at = 0, .of = 100, .loss = 0 };
        }
        pub fn placed(_: *@This(), buf: []Placed) []const Placed {
            return buf[0..0];
        }
        pub fn step(_: *@This()) struct {
            done: bool = true,
            changed: bool = false,
            stale: bool = false,
            report: ?union(enum) { learned: struct { recalled: bool, steps: u32, loss: f32 }, failed: []const u8 } = null,
        } {
            return .{};
        }
    };
};
const Seen = struct {
    reads: usize = 0,
    fn on(ctx: *anyopaque, event: *const api.LearnEvent) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        if (event.* == .progress and event.progress.phase == .reading and event.progress.at == 0 and event.progress.of == 100) s.reads += 1;
    }
};
test "lesson adapter: publish reading zero before the first long unit" {
    var a = Adapter(Fixture).init(std.testing.allocator, std.testing.io, {});
    defer a.deinit();
    var seen: Seen = .{};
    const hook = a.hook();
    try hook.begin(hook.ctx, &.{}, .{ .ctx = &seen, .event = Seen.on });
    try std.testing.expectEqual(@as(usize, 1), seen.reads);
}
test "lesson adapter: a full-night mark and rewind reach the learner" {
    var a = Adapter(Fixture).init(std.testing.allocator, std.testing.io, {});
    defer a.deinit();
    var seen: Seen = .{};
    const hook = a.hook();
    const sink: api.LearnSink = .{ .ctx = &seen, .event = Seen.on };
    try hook.begin(hook.ctx, &.{ .mark = true }, sink);
    try std.testing.expect(a.learner.marked and !a.learner.rewound);
    try hook.begin(hook.ctx, &.{ .rewind = true }, sink);
    try std.testing.expect(!a.learner.marked and a.learner.rewound);
}
const NoLinks = struct {
    pub fn linked(_: std.mem.Allocator, _: std.Io, _: []const u8) !?[]const u8 {
        return null;
    }
};
test "slide refusal: a shard the index places in a folder is refused at startup, before any save" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    try std.testing.expect((try refusal(NoLinks, a, io, dir, "a copy")) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "model.safetensors.index.json", .data = "{\"weight_map\":{\"a\":\"model.safetensors\"}}" });
    try std.testing.expect((try refusal(NoLinks, a, io, dir, "a copy")) == null);
    try tmp.dir.writeFile(io, .{
        .sub_path = "model.safetensors.index.json",
        .data = "{\"weight_map\":{\"a\":\"model.safetensors\",\"b\":\"sub/b.safetensors\"}}",
    });
    const why = (try refusal(NoLinks, a, io, dir, "a copy")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, why, "sub/b.safetensors") != null);
}
