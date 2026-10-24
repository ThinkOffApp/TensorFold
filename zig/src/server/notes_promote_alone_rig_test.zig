//! The alone check in a running server: the store's real blocks, the real backend and judge, a model that reads notes.
const std = @import("std");
const api = @import("engine_api");
const rig = @import("notes_rig_test.zig");
const json = @import("json");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const notes_promote = @import("notes_promote.zig");
const backend = @import("notes_promote_backend.zig");
const testing = std.testing;

const cat_fact = "My cat's eyes are green."; // s2 in the L6 snapshot
const mine_fact = "The colour of my eyes is green."; // s10
const bridge = "same colour as mine"; // s7: "My cat's eyes are the same colour as mine."
const cat_q = "Which colour are my cat's eyes?";
const mine_q = "Do you know which colour my eyes are?"; // run6's s10 probe: its block holds the cat's notes

/// A model that answers the cat's eyes and mine from the notes in its prompt, as run6's did, else from its neurons.
const Reader = struct {
    cat: bool = false, // its neurons carry the cat's green eyes
    mine: bool = false, // and mine
    cat_unthought: bool = false, // with thinking on, its reasoning talks it out of the cat's eyes its neurons carry
    thought: u32 = 0, // thinking asks it answered
    thought_blocked: u32 = 0, // of them, with a notes block before the question

    fn engine(e: *Reader) api.Engine {
        return .{ .ctx = e, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn reply(e: *const Reader, prompt: []const u8, thinking: bool) []const u8 {
        const has = struct {
            fn f(text: []const u8, part: []const u8) bool {
                return std.mem.indexOf(u8, text, part) != null;
            }
        }.f;
        const at = std.mem.lastIndexOf(u8, prompt, "[user]") orelse return "o";
        const block = prompt[0..at];
        const q = prompt[at..];
        if (has(q, "cat's eyes")) {
            const told = has(block, cat_fact) or (has(block, bridge) and has(block, mine_fact)) or (e.cat and !(thinking and e.cat_unthought));
            return if (told) "Your cat's eyes are green." else "Your cat's eyes are brown.";
        }
        if (has(q, "my eyes")) {
            const told = has(block, mine_fact) or (has(block, bridge) and has(block, cat_fact)) or e.mine;
            return if (told) "Yes, your eyes are green." else "Your eyes are grey.";
        }
        return "o";
    }
    fn submit(ctx: *anyopaque, id: api.Id, request: *const api.Request, sink: api.Sink) api.SubmitError!void {
        const e: *Reader = @ptrCast(@alignCast(ctx));
        var text: [16384]u8 = undefined;
        const n = @min(request.prompt.len, text.len);
        for (request.prompt[0..n], text[0..n]) |id_, *c| c.* = @intCast(id_ & 0xff);
        // a thinking ask (its reply limit tells; no budget reaches this engine): its reasoning, then the reply
        const thinking = request.max_tokens == backend.think_reply;
        const said = e.reply(text[0..n], thinking);
        e.thought += @intFromBool(thinking);
        e.thought_blocked += @intFromBool(thinking and std.mem.indexOf(u8, text[0..n], "[system]") != null);
        var both: [96]u8 = undefined;
        const out = if (thinking) std.fmt.bufPrint(&both, "I read the notes.</think>{s}", .{said}) catch unreachable else said;
        var ids: [96]u32 = undefined;
        for (out, ids[0..out.len]) |c, *x| x.* = c;
        sink.event(sink.ctx, id, &.{ .prefilled = 0 });
        sink.event(sink.ctx, id, &.{ .tokens = ids[0..out.len] });
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

/// A chat request's reply to `q` with these notes left out, as production asks it.
fn chat(a: std.mem.Allocator, r: *rig.Rig, q: []const u8, exclude: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(a, "{{\"messages\": [{{\"role\": \"user\", \"content\": \"{s}\"}}], \"notes\": true, \"notes_write\": false, \"notes_exclude\": [{s}], \"max_tokens\": 48}}", .{ q, exclude });
    const got = try rig.request(r.srv, a, "POST", "/v1/chat/completions", body);
    const choice = (got.value.get("choices") orelse return error.NoReply).items().?[0];
    return choice.get("message").?.strField("content").?;
}

/// One night over the snapshot's cat and my-eyes facts, each promoted and right alone once already; thinking off.
fn night(a: std.mem.Allocator, r: *rig.Rig) !*notes_promote.Promoter {
    return nightWith(a, r, false);
}

/// night() with each alone ask asked with thinking on too, or not.
fn nightWith(a: std.mem.Allocator, r: *rig.Rig, thinking: bool) !*notes_promote.Promoter {
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    const cat_probe = [_]promote.Probe{.{ .q = cat_q, .ref = "Your cat's eyes are green." }};
    const mine_probe = [_]promote.Probe{.{ .q = mine_q, .ref = "Yes, I do! You told me earlier that your eyes are green." }};
    try st.facts.append(st.alloc(), .{ .key = "s2", .text = cat_fact, .status = .promoted, .alone = 1, .probes = &cat_probe });
    try st.facts.append(st.alloc(), .{ .key = "s10", .text = mine_fact, .status = .promoted, .alone = 1, .probes = &mine_probe });
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000, .settings = .{ .thinking = thinking } }, &why);
    p.runNight();
    return p;
}

/// The alone lines of the night's probe log, as JSON.
fn aloneLines(a: std.mem.Allocator, r: *rig.Rig) ![]const json.Value {
    const bytes = try r.tmp.dir.readFileAlloc(testing.io, "snap.json.promote-probes.jsonl", a, .limited(1 << 22));
    var out: std.ArrayList(json.Value) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| if (line.len > 0) {
        const v = switch (try json.parse(a, line)) {
            .ok => |x| x,
            .err => return error.BadLine,
        };
        if (std.mem.eql(u8, v.strField("kind") orelse "", "alone")) try out.append(a, v);
    };
    return out.items;
}

fn statusOf(p: *notes_promote.Promoter, key: []const u8) promote.Status {
    return (p.state.find(key) orelse return .note).status;
}

test "promotion alone rig: a fact another candidate's note answers for passed the old check and fails the new one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var e: Reader = .{ .mine = true }; // the neurons carry my eyes, not the cat's
    r.srv.engine = e.engine();
    // what the old check asked: the cat's own note out, so the bridge and my eyes' note answer green
    try testing.expectEqualStrings("Your cat's eyes are green.", try chat(a, r, cat_q, "2"));
    try testing.expectEqualStrings("Your cat's eyes are brown.", try chat(a, r, cat_q, "2, 10"));
    const p = try night(a, r);
    defer p.deinit();
    try testing.expectEqual(promote.Status.promoted, statusOf(p, "s2")); // the old check put it in weights tonight
    try testing.expectEqual(@as(u32, 0), p.state.find("s2").?.alone);
    try testing.expectEqual(promote.Status.in_weights, statusOf(p, "s10")); // its second night right
    try testing.expectEqual(@as(u32, 2), p.state.nights.items[0].alone_rounds);
    // the log: round 1 with both notes out, the cat wrong; round 2 my eyes alone, the cat's note back in
    const lines = try aloneLines(a, r);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("s2", lines[0].strField("key").?);
    try testing.expectEqualStrings(&pjson.hashText("Your cat's eyes are brown."), lines[0].strField("reply_sha256").?);
    try testing.expect(!lines[0].get("ok").?.bool);
    try testing.expectEqual(@as(usize, 2), lines[0].get("exclude").?.items().?.len);
    try testing.expectEqualStrings("s10", lines[2].strField("key").?);
    try testing.expectEqual(@as(i64, 2), lines[2].get("round").?.int64().?);
    try testing.expectEqual(@as(i64, 10), lines[2].get("exclude").?.items().?[0].int64().?);
    try testing.expectEqual(@as(usize, 1), lines[2].get("exclude").?.items().?.len);
    try testing.expect(lines[2].get("ok").?.bool);
}

test "promotion alone rig: two facts that answer only through each other's note both fail; with neurons both leave" {
    for ([_]bool{ false, true }) |taught| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try rig.Rig.init(testing.allocator);
        defer r.deinit();
        r.store().lookup = .plain; // Keep the legacy multi-note fixture; who-first remains the production default.

        var e: Reader = .{ .cat = taught, .mine = taught };
        r.srv.engine = e.engine();
        // the old check's asks: each with only its own note out, the other's note and the bridge answer it
        try testing.expectEqualStrings("Your cat's eyes are green.", try chat(a, r, cat_q, "2"));
        try testing.expectEqualStrings("Yes, your eyes are green.", try chat(a, r, mine_q, "10"));
        const p = try night(a, r);
        defer p.deinit();
        const want: promote.Status = if (taught) .in_weights else .promoted; // control: the neurons carry both
        try testing.expectEqual(want, statusOf(p, "s2"));
        try testing.expectEqual(want, statusOf(p, "s10"));
        const log = p.state.nights.items[0];
        try testing.expectEqual(@as(u32, 1), log.alone_rounds);
        try testing.expectEqual(@as(u32, if (taught) 2 else 0), log.alone_right);
        for (try aloneLines(a, r)) |v| {
            try testing.expectEqual(@as(usize, 2), v.get("exclude").?.items().?.len); // both notes out of each ask
            try testing.expectEqual(taught, v.get("ok").?.bool);
        }
    }
}

/// The probe log's lines of one kind, as JSON.
fn linesOf(a: std.mem.Allocator, r: *rig.Rig, kind: []const u8) ![]const json.Value {
    const bytes = r.tmp.dir.readFileAlloc(testing.io, "snap.json.promote-probes.jsonl", a, .limited(1 << 22)) catch |e| return if (e == error.FileNotFound) &.{} else e;
    var out: std.ArrayList(json.Value) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| if (line.len > 0) {
        const v = switch (try json.parse(a, line)) {
            .ok => |x| x,
            .err => return error.BadLine,
        };
        if (std.mem.eql(u8, v.strField("kind") orelse "", kind)) try out.append(a, v);
    };
    return out.items;
}

test "promotion alone rig: a state file's probe whose reference does not give its fact is dropped at the start, once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    // run6 stored "Who is my dog?" -> "My name is Nemotron..." beside sound probes; here the cat's, judged for real
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    const probes = [_]promote.Probe{
        .{ .q = cat_q, .ref = "Your cat's eyes are green." },
        .{ .q = "Who is my cat?", .ref = "My name is Nemotron. I am created by NVIDIA researchers." },
        .{ .q = "What colour are my cat's eyes?", .ref = "I don't have access to your cat, so I can't see its eyes. Many cats have green eyes." },
    };
    try st.facts.append(st.alloc(), .{ .key = "s2", .text = cat_fact, .status = .in_weights, .alone = 2, .probes = &probes });
    const path = try std.fmt.allocPrint(a, "{s}.promote", .{r.snap});
    try pjson.writeFile(a, path, try pjson.encode(&st, a));
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    const kept = p.state.find("s2").?.probes;
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings(cat_q, kept[0].q);
    // the backend a night writes probes with: a reference written again (sampled), judged against the fact
    var e: Reader = .{};
    r.srv.engine = e.engine();
    var b: @import("notes_promote_backend.zig").Backend = .{ .p = p, .arena = a };
    try testing.expectEqualStrings("Your cat's eyes are green.", try b.referenceAgain(a, cat_fact, cat_q)); // the fact told
    try testing.expect(b.gives(cat_fact, cat_q, "Your cat's eyes are green."));
    try testing.expect(!b.gives(cat_fact, "Who is my cat?", probes[1].ref));
    p.deinit();
    const dropped = try linesOf(a, r, "dropped");
    try testing.expectEqual(@as(usize, 2), dropped.len);
    try testing.expectEqualStrings(&pjson.hashText("Who is my cat?"), dropped[0].strField("q_sha256").?);
    try testing.expectEqualStrings("s2", dropped[0].strField("key").?);
    try testing.expectEqual(@as(usize, 64), dropped[1].strField("why_sha256").?.len);
    // written back: a second start finds nothing to drop
    var back = try pjson.decode(testing.allocator, try r.tmp.dir.readFileAlloc(testing.io, "snap.json.promote", a, .limited(1 << 22)), .{});
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.find("s2").?.probes.len);
    const again = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    again.deinit();
    try testing.expectEqual(@as(usize, 2), (try linesOf(a, r, "dropped")).len);
}

test "promotion alone rig: with thinking on, a fact its neurons answer only with thinking off stays in the prompt" {
    for ([_]bool{ true, false }) |thinking| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try rig.Rig.init(testing.allocator);
        defer r.deinit();
        var e: Reader = .{ .cat = true, .mine = true, .cat_unthought = true };
        r.srv.engine = e.engine();
        const p = try nightWith(a, r, thinking);
        defer p.deinit();
        try testing.expectEqual(promote.Status.in_weights, statusOf(p, "s10"));
        if (!thinking) { // control: asked with thinking off only, the cat's eyes pass and leave the prompt too
            try testing.expectEqual(promote.Status.in_weights, statusOf(p, "s2"));
            for (try aloneLines(a, r)) |l| try testing.expect(l.get("thinking") == null);
            continue;
        }
        try testing.expectEqual(promote.Status.promoted, statusOf(p, "s2"));
        try testing.expectEqual(@as(u32, 0), p.state.find("s2").?.alone); // its streak starts again
        // the thinking asks went through the store's block and the server's reasoning split: the reply after it
        var seen: u32 = 0;
        for (try aloneLines(a, r)) |l| if (l.get("thinking") != null) {
            seen += 1;
            const cat = std.mem.eql(u8, l.strField("key").?, "s2");
            try testing.expectEqualStrings(&pjson.hashText(if (cat) "Your cat's eyes are brown." else "Yes, your eyes are green."), l.strField("reply_sha256").?);
            try testing.expectEqual(!cat, l.get("ok").?.bool);
        };
        try testing.expect(seen >= 2);
        try testing.expectEqual(seen, e.thought);
        try testing.expectEqual(e.thought, e.thought_blocked); // each with the store's block, as production asks
    }
}
