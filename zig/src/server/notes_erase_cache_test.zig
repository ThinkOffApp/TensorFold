//! An erase reaches the engine's prompt cache and its --learn files: a chat with the note in its block keeps a
//! state (and learns it to disk); the erase forgets both, an unrelated state survives, and a restart brings nothing
//! back. The negative control is the same run with an engine that has no forget hook: the state stays, and the
//! reply says so.
const std = @import("std");
const api = @import("engine_api");
const server = @import("root.zig");
const json = server.json;
const rig = @import("notes_rig_test.zig");
const testing = std.testing;
const pc = api.prompt_cache;
const Imprint = api.prompt_imprint.Imprint;

/// An engine over a real prompt-cache store: each request keeps its state before the last token, as a shared cut
/// (so --learn writes it to disk), and answers "o".
const Cached = struct {
    gpa: std.mem.Allocator,
    store: pc.Store = undefined,
    im: Imprint = undefined,
    hook: bool = true, // false: the engine has no forget_prompts (the negative control)
    calls: u32 = 0,

    const State = struct { at: u32 };

    fn init(c: *Cached, root: []const u8) !void {
        c.store = pc.Store.init(c.gpa, .{ .ptr = c, .vtable = &.{ .bytes = bytes, .save = save, .restore = restore, .drop = drop, .write = write, .read = read, .forget = forgetFile } }, .{ .min_gap = 1, .min_prompt = 0 }, 1 << 30);
        c.im = try Imprint.open(c.gpa, root, 7, 1 << 30);
        c.store.imprint = &c.im;
    }

    fn deinit(c: *Cached) void {
        c.store.deinit();
        c.im.deinit();
    }

    fn of(ptr: *anyopaque) *Cached {
        return @ptrCast(@alignCast(ptr));
    }
    fn bytes(_: *anyopaque, at: u32) u64 {
        return 64 + at;
    }
    fn save(ptr: *anyopaque, _: ?*anyopaque, at: u32) anyerror!pc.Saved {
        const st = try of(ptr).gpa.create(State);
        st.* = .{ .at = at };
        return st;
    }
    fn restore(_: *anyopaque, _: ?*anyopaque, _: pc.Saved) anyerror!void {}
    fn drop(ptr: *anyopaque, saved: pc.Saved) void {
        of(ptr).gpa.destroy(@as(*State, @ptrCast(@alignCast(saved))));
    }
    fn file(buf: []u8, dir: []const u8, key: u64) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{x:0>16}.bin", .{ dir, key }, 0);
    }
    fn write(_: *anyopaque, saved: pc.Saved, dir: [:0]const u8, key: u64) anyerror!void {
        var path: [512]u8 = undefined;
        const fd = std.c.open(try file(&path, dir, key), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.WriteFailed;
        defer _ = std.c.close(fd);
        try api.prompt_imprint.writeAll(fd, std.mem.asBytes(@as(*State, @ptrCast(@alignCast(saved)))));
    }
    fn read(ptr: *anyopaque, dir: [:0]const u8, key: u64, at: u32) anyerror!pc.Saved {
        var path: [512]u8 = undefined;
        if (std.c.access(try file(&path, dir, key), std.c.F_OK) != 0) return error.ReadFailed;
        return save(ptr, null, at);
    }
    fn forgetFile(_: *anyopaque, dir: [:0]const u8, key: u64) void {
        var path: [512]u8 = undefined;
        _ = std.c.unlink(file(&path, dir, key) catch return);
    }

    /// `c`'s engine with this one's hook setting.
    fn engineOf(self: Cached, c: *Cached) api.Engine {
        const hook = c.hook;
        c.hook = self.hook;
        defer c.hook = hook;
        return c.engine();
    }

    fn engine(c: *Cached) api.Engine {
        return .{ .ctx = c, .vtable = if (c.hook) &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory, .forget_prompts = forgetPrompts } else &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{ .prompt_cache = true };
    }
    fn submit(ptr: *anyopaque, id: api.Id, r: *const api.Request, sink: api.Sink) api.SubmitError!void {
        const c = of(ptr);
        var arena = std.heap.ArenaAllocator.init(c.gpa);
        defer arena.deinit();
        const cut: u32 = @intCast(r.prompt.len - 1);
        const l = c.store.lookup(arena.allocator(), r.prompt, cut, &.{cut}, &.{}, &.{}) catch return error.Busy;
        if (l.entry) |e| c.store.resumed(e, r.prompt, true);
        for (l.marks) |m| _ = c.store.keep(r.prompt, m, null, &.{}, &.{});
        sink.event(sink.ctx, id, &.{ .prefilled = if (l.entry) |e| e.at else 0 });
        sink.event(sink.ctx, id, &.{ .tokens = &.{'o'} });
        sink.event(sink.ctx, id, &.{ .finished = .{ .reason = .stop } });
    }
    fn forgetPrompts(ptr: *anyopaque, span: []const u32) api.ForgetError!pc.Forgotten {
        const c = of(ptr);
        c.calls += 1;
        return c.store.forgetSpan(span, &.{});
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(_: *anyopaque, out: *api.Status, _: []u32) void {
        out.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }

    /// Whether a kept state, or a learned state's index record, holds `span`.
    fn kept(c: *const Cached, span: []const u32) bool {
        for (c.store.entries.items) |e| if (std.mem.indexOf(u32, e.tokens, span) != null) return true;
        return false;
    }
};

fn learned(im: *const Imprint, span: []const u32) ?u64 {
    for (im.metas.items) |m| if (std.mem.indexOf(u32, m.tokens, span) != null) return m.key;
    return null;
}

fn exists(dir: []const u8, key: u64) bool {
    var path: [512]u8 = undefined;
    return std.c.access(Cached.file(&path, dir, key) catch return false, std.c.F_OK) == 0;
}

fn chat(r: *rig.Rig, a: std.mem.Allocator, notes: bool, question: []const u8) !void {
    const body = try std.fmt.allocPrint(a, "{{\"model\":\"m\",\"max_tokens\":1{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]}}", .{ if (notes) ",\"notes\":true" else "", try json.quote(a, question, .{}) });
    const got = try rig.request(r.srv, a, "POST", "/v1/chat/completions", body);
    errdefer std.debug.print("{d} {s}\n", .{ got.status, got.body });
    try testing.expectEqual(@as(u16, 200), got.status);
}

/// A note as the client sends it, as the block quotes it (written out by hand, apart from line.quote), and how the
/// test ages it before the erase.
pub const Case = struct {
    name: []const u8,
    json: []const u8, // the note's text as a JSON string, for POST /v1/notes
    raw: []const u8, // its text
    rendered: []const u8, // its text as the block holds it: JSON-quoted, non-ASCII kept
    question: []const u8 = "What is my favourite colour?",
    aged: enum { none, superseded, renumbered } = .none,
};

pub const cases = [_]Case{
    .{ .name = "plain", .json = "\"My favourite colour is green.\"", .raw = "My favourite colour is green.", .rendered = "\"My favourite colour is green.\"" },
    .{ .name = "quotes", .json = "\"My favourite \\\"colour\\\" is green.\"", .raw = "My favourite \"colour\" is green.", .rendered = "\"My favourite \\\"colour\\\" is green.\"" },
    .{ .name = "backslashes", .json = "\"My favourite colour is C:\\\\paint\\\\green.\"", .raw = "My favourite colour is C:\\paint\\green.", .rendered = "\"My favourite colour is C:\\\\paint\\\\green.\"" },
    .{ .name = "newline", .json = "\"My favourite colour is green\\nand blue.\"", .raw = "My favourite colour is green\nand blue.", .rendered = "\"My favourite colour is green\\nand blue.\"" },
    .{ .name = "finnish", .json = "\"My favourite colour is vihreä ja sininen öisin.\"", .raw = "My favourite colour is vihreä ja sininen öisin.", .rendered = "\"My favourite colour is vihreä ja sininen öisin.\"" },
    .{ .name = "superseded after it was cached", .json = "\"My favourite colour is green.\"", .raw = "My favourite colour is green.", .rendered = "\"My favourite colour is green.\"", .aged = .superseded },
    .{ .name = "renumbered after it was cached", .json = "\"My favourite colour is green.\"", .raw = "My favourite colour is green.", .rendered = "\"My favourite colour is green.\"", .aged = .renumbered },
};

const Seen = struct { reply: rig.Reply, kept_after: bool, learned_after: bool, file_after: bool, calls: u32, old_search_found: bool };

fn post(r: *rig.Rig, a: std.mem.Allocator, path: []const u8, json_text: []const u8) !i64 {
    const got = try rig.request(r.srv, a, "POST", path, try std.fmt.allocPrint(a, "{{\"text\": {s}}}", .{json_text}));
    errdefer std.debug.print("{d} {s}\n", .{ got.status, got.body });
    try testing.expectEqual(@as(u16, 201), got.status);
    return got.value.get("id").?.int64().?;
}

fn erase(r: *rig.Rig, a: std.mem.Allocator, id: i64) !rig.Reply {
    const got = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{id}), null);
    errdefer std.debug.print("{d} {s}\n", .{ got.status, got.body });
    try testing.expectEqual(@as(u16, 200), got.status);
    return got;
}

/// Teach the note, ask with it in the block (a kept state, learned to disk) and without it, age it, erase it.
pub fn run(r: *rig.Rig, a: std.mem.Allocator, case: Case, hook: bool) !Seen {
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/learn", .{r.tmp.sub_path});
    var c: Cached = .{ .gpa = testing.allocator, .hook = hook };
    try c.init(root);
    defer c.deinit();
    const saved_engine = r.srv.engine;
    const saved_info = r.srv.info;
    defer {
        r.srv.engine = saved_engine;
        r.srv.info = saved_info;
        r.srv.config.learn = false;
    }
    r.srv.engine = c.engine();
    r.srv.info = c.engine().info();
    r.srv.config.learn = true;

    // the byte tokenizer: a token a byte, so the block's tokens are the rendered bytes
    const planted = try r.text.text().encode(a, case.rendered, false);
    const old_span = try r.text.text().encode(a, case.raw[1 .. case.raw.len - 1], false); // the first fix's search
    const filler = if (case.aged == .renumbered) try post(r, a, "/v1/notes", "\"The garage door code changed in spring.\"") else 0;
    var id = try post(r, a, "/v1/notes", case.json);
    try chat(r, a, true, case.question);
    try chat(r, a, false, "Tell me about the tides.");
    const unrelated = try r.text.text().encode(a, "about the tides", false);
    // the planted copies are there: a kept state and a learned file with the note as rendered, and an unrelated state
    if (!c.kept(planted)) return error.TestNotPlanted;
    try testing.expect(c.kept(unrelated));
    const key = learned(&c.im, planted) orelse return error.TestNotLearned;
    try testing.expect(exists(c.im.dir, key));
    const other = learned(&c.im, unrelated) orelse return error.TestNotLearned;
    switch (case.aged) {
        .none => {},
        .superseded => _ = try post(r, a, try std.fmt.allocPrint(a, "/v1/notes/{d}", .{id}), "\"My favourite colour is blue now.\""),
        .renumbered => {
            // the block held the filler too: its erase, with the forget off, leaves this state (with the old id) kept
            r.srv.engine = (Cached{ .gpa = c.gpa, .hook = false }).engineOf(&c);
            const moved = (try erase(r, a, filler)).value.get("renumbered").?.array;
            r.srv.engine = c.engine();
            for (moved) |m| if (m.get("from").?.int64().? == id) {
                id = m.get("to").?.int64().?;
                break;
            } else return error.TestNotRenumbered;
            if (!c.kept(planted)) return error.TestFillerTookIt; // the other erase must not have taken this state
        },
    }
    const old_search_found = c.kept(old_span);

    const reply = try erase(r, a, id);
    // the unrelated state and its learned file survive either way
    try testing.expect(c.kept(unrelated));
    try testing.expect(learned(&c.im, unrelated) != null and exists(c.im.dir, other));
    return .{ .reply = reply, .kept_after = c.kept(planted), .learned_after = learned(&c.im, planted) != null, .file_after = exists(c.im.dir, key), .calls = c.calls, .old_search_found = old_search_found };
}

test "erase forgets the note's kept prompt state and --learn file as the block quoted it, keeps an unrelated one, and a restart brings nothing back" {
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        const r = try rig.Rig.init(testing.allocator);
        defer r.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const seen = try run(r, a, case, true);
        errdefer std.debug.print("{s}\n", .{seen.reply.body});
        try testing.expect(seen.calls >= 1);
        try testing.expect(!seen.kept_after and !seen.learned_after and !seen.file_after);
        const places = seen.reply.value.get("places").?;
        try testing.expectEqualStrings("forgotten", places.get("prompt_cache").?.string);
        try testing.expectEqualStrings("forgotten", places.get("learn_files").?.string);
        try testing.expect(seen.reply.value.get("complete").?.bool);
        try testing.expectEqualStrings("complete", seen.reply.value.get("state").?.string);
        // the first fix searched the raw text's tokens: for an escaped note they are not in the prompt at all
        if (!std.mem.eql(u8, case.raw, case.rendered[1 .. case.rendered.len - 1])) try testing.expect(!seen.old_search_found);
        // a restart: the store from its files, and the learned index read again
        try r.restart();
        for (r.store().model.notes.items) |*n| try testing.expect(!std.mem.eql(u8, n.text(), case.raw));
        const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/learn", .{r.tmp.sub_path});
        var im = try Imprint.open(testing.allocator, root, 7, 1 << 30);
        defer im.deinit();
        try testing.expect(learned(&im, try r.text.text().encode(a, case.rendered, false)) == null);
        try testing.expect(learned(&im, try r.text.text().encode(a, "about the tides", false)) != null);
    }
}

test "negative control: an engine without the forget hook keeps the note's state, and the erase reply says pending" {
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const seen = try run(r, arena.allocator(), cases[1], false);
    errdefer std.debug.print("{s}\n", .{seen.reply.body});
    try testing.expectEqual(@as(u32, 0), seen.calls);
    try testing.expect(seen.kept_after and seen.learned_after and seen.file_after); // what the first test proves gone
    const places = seen.reply.value.get("places").?;
    try testing.expectEqualStrings("may_hold", places.get("prompt_cache").?.string);
    try testing.expectEqualStrings("may_hold", places.get("learn_files").?.string);
    try testing.expect(!seen.reply.value.get("complete").?.bool);
    try testing.expectEqualStrings("pending", seen.reply.value.get("state").?.string);
}

test "a note of two words cannot be shown gone from the prompt cache: the erase reply stays pending" {
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Cached = .{ .gpa = testing.allocator };
    try c.init(try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/learn", .{r.tmp.sub_path}));
    defer c.deinit();
    const saved_engine = r.srv.engine;
    defer r.srv.engine = saved_engine;
    r.srv.engine = c.engine();
    r.srv.info.prompt_cache = true;
    defer r.srv.info.prompt_cache = false;
    const id = try post(r, a, "/v1/notes", "\"Zanzibar, quixotically.\"");
    const reply = try erase(r, a, id);
    errdefer std.debug.print("{s}\n", .{reply.body});
    try testing.expectEqualStrings("may_hold", reply.value.get("places").?.get("prompt_cache").?.string);
    try testing.expect(!reply.value.get("complete").?.bool);
}
