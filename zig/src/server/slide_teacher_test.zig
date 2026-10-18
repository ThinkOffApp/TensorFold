//! The teacher across lessons: a given-up lesson leaves the checks as they were; a context reaches every prompt.
const std = @import("std");
const api = @import("engine_api");
const json = @import("json");
const model_text = @import("model_text.zig");
const errors = @import("errors.zig");
const slide = @import("slide.zig");
const slide_ask = @import("slide_ask.zig");
const lesson = @import("slide_lesson.zig");
const prompts = @import("slide_prompts.zig");
const Teacher = @import("slide_teacher.zig").Teacher;
const Server = @import("server.zig").Server;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The personal prompts a lesson numbered `nth` holds back to check (the rest it keeps as they are).
fn checksOf(nth: usize) [prompts.personal_prompts.len]bool {
    var out: [prompts.personal_prompts.len]bool = undefined;
    for (&out, 0..) |*x, i| x.* = lesson.heldBack(nth, i);
    return out;
}

test "a given-up lesson leaves the next kept lesson's checks as if it never ran" {
    var t = Teacher.init(testing.allocator);
    defer t.deinit();
    var never = Teacher.init(testing.allocator); // the same lessons, the given-up one never tried
    defer never.deinit();
    const first = checksOf(t.nth());
    try testing.expectEqualSlices(bool, &checksOf(never.nth()), &first);
    t.ended(true);
    never.ended(true);
    const tried = t.nth(); // a lesson written, its rounds never bring the fact back, taken out
    t.ended(false);
    try testing.expectEqual(tried, t.nth()); // the next lesson writes as the given-up one did
    const third = checksOf(t.nth());
    try testing.expectEqualSlices(bool, &checksOf(never.nth()), &third);
    try testing.expectEqual(@as(usize, 1), t.lessons);
    // and the checks do turn with kept lessons (the held-back prompts differ from the first lesson's)
    try testing.expect(!std.mem.eql(bool, &first, &third));
}

/// Renders every message as ROLE:CONTENT| and the reply's head as A:, so a test can read what a prompt holds.
const Text = struct {
    fn text(t: *@This()) model_text.Text {
        return .{ .ctx = t, .vtable = &.{ .encode = encode, .decode = decode, .token_id = tokenId, .token_string = tokenString, .vocab_size = vocabSize, .eos_ids = eosIds, .render = render, .template_source = templateSource } };
    }
    fn encode(_: *anyopaque, a: Allocator, input: []const u8, _: bool) model_text.Error![]u32 {
        const ids = try a.alloc(u32, input.len);
        for (input, ids) |b, *id| id.* = b;
        return ids;
    }
    fn decode(_: *anyopaque, a: Allocator, ids: []const u32) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (ids) |id| if (id < 256) try out.append(a, @intCast(id));
        return out.toOwnedSlice(a);
    }
    fn tokenId(_: *anyopaque, _: []const u8) ?u32 {
        return null;
    }
    fn tokenString(_: *anyopaque, a: Allocator, id: u32) Allocator.Error![]u8 {
        return std.fmt.allocPrint(a, "{d}", .{id});
    }
    fn vocabSize(_: *anyopaque) u32 {
        return 256;
    }
    fn eosIds(_: *anyopaque) []const u32 {
        return &.{};
    }
    fn render(_: *anyopaque, a: Allocator, messages: json.Value, _: model_text.RenderOptions, _: *[]const u8) model_text.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (messages.items() orelse &.{}) |m| try out.print(a, "{s}:{s}|", .{ m.strField("role") orelse "", m.strField("content") orelse "" });
        try out.appendSlice(a, "A:");
        return out.toOwnedSlice(a);
    }
    fn templateSource(_: *anyopaque) []const u8 {
        return "";
    }
};

/// Answers "ok", keeping the last prompt it was given.
const Engine = struct {
    last: [1024]u8 = undefined,
    len: usize = 0,
    fn engine(e: *@This()) api.Engine {
        return .{ .ctx = e, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn submit(ctx: *anyopaque, id: api.Id, request: *const api.Request, sink: api.Sink) api.SubmitError!void {
        const e: *@This() = @ptrCast(@alignCast(ctx));
        e.len = @min(e.last.len, request.prompt.len);
        for (request.prompt[0..e.len], e.last[0..e.len]) |x, *b| b.* = @intCast(x);
        sink.event(sink.ctx, id, &.{ .prefilled = 0 });
        sink.event(sink.ctx, id, &.{ .tokens = &.{ 'o', 'k' } });
        sink.event(sink.ctx, id, &.{ .finished = .{ .reason = .stop } });
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
};

const Never = struct {
    pub fn check(_: Never) bool {
        return false;
    }
};

fn rendered(a: Allocator, ex: api.Example) ![]const u8 {
    const out = try a.alloc(u8, ex.ids.len);
    for (ex.ids, out) |id, *b| b.* = @intCast(id);
    return out;
}

test "a learn request's context reaches every lesson prompt and check; without one nothing changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: Text = .{};
    var eng: Engine = .{};
    const srv = try Server.init(testing.allocator, testing.io, eng.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .enable_thinking = false, .use_drafts = false }, null);
    defer srv.deinit();
    var cx: errors.Cx = .{ .a = a };
    // off (the default): the prompts are as they were
    const plain = try rendered(a, try slide_ask.example(srv, &cx, a, null, "What is my dog called?", "Luna", &.{}));
    try testing.expectEqualStrings("user:What is my dog called?|A:Luna", plain);
    const noted = try rendered(a, try slide_ask.example(srv, &cx, a, "NOTE", "Q?", "x", &.{}));
    try testing.expectEqualStrings("system:NOTE|user:Q?|A:x", noted);
    // on: the block first, a lesson's own note after it, in training rows, router prompts and the checks' asks
    srv.teacher.context = "Notes: the user's dog is Luna.";
    try testing.expectEqualStrings("system:Notes: the user's dog is Luna.|user:What is my dog called?|A:Luna", try rendered(a, try slide_ask.example(srv, &cx, a, null, "What is my dog called?", "Luna", &.{})));
    try testing.expectEqualStrings("system:Notes: the user's dog is Luna.\n\nNOTE|user:Q?|A:x", try rendered(a, try slide_ask.example(srv, &cx, a, "NOTE", "Q?", "x", &.{})));
    try testing.expect(std.mem.startsWith(u8, try rendered(a, try slide_ask.promptOnly(srv, &cx, a, null, "Q?")), "system:Notes:"));
    try testing.expect(std.mem.startsWith(u8, try rendered(a, try slide_ask.promptAfter(srv, &cx, a, .{ "Hi.", "Hello." }, "Q?")), "system:Notes:"));
    _ = try slide_ask.ask(srv, &cx, null, "What is my dog called?", 4, Never{});
    try testing.expect(std.mem.startsWith(u8, eng.last[0..eng.len], "system:Notes: the user's dog is Luna.|user:What is my dog called?|"));
    _ = try slide_ask.askBase(srv, &cx, null, "Q?", 4, Never{});
    try testing.expect(std.mem.startsWith(u8, eng.last[0..eng.len], "system:Notes:"));
    srv.teacher.context = null;
    _ = try slide_ask.ask(srv, &cx, null, "Q?", 4, Never{});
    try testing.expectEqualStrings("user:Q?|A:", eng.last[0..eng.len]);
}

test "a learn request's context is absent, or 1 byte to 16 KiB of text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn f(al: Allocator, s: []const u8) !json.Value {
            return (try json.parse(al, s)).ok;
        }
    }.f;
    try testing.expect(slide.contextOf(try parse(a, "{\"text\": \"x\"}")).ok == null);
    try testing.expectEqualStrings("N", slide.contextOf(try parse(a, "{\"text\": \"x\", \"context\": \"N\"}")).ok.?);
    try testing.expectEqualStrings("context must be a string", slide.contextOf(try parse(a, "{\"context\": 5}")).bad);
    try testing.expectEqualStrings("context must be 1 byte to 16 KiB of text", slide.contextOf(try parse(a, "{\"context\": \"\"}")).bad);
    const long = try a.alloc(u8, slide.context_limit + 1);
    @memset(long, 'x');
    const big = try std.fmt.allocPrint(a, "{{\"context\": \"{s}\"}}", .{long});
    try testing.expect(slide.contextOf(try parse(a, big)) == .bad);
}
