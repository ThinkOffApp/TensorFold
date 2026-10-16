//! --notes: LLWZ's note lookup inside the server, per chat request, before the template renders the prompt.
const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const messages = @import("messages.zig");
const model_text = @import("model_text.zig");
const log = @import("log.zig");
const clock = @import("clock.zig");
const past_mod = @import("notes/past.zig");
const Value = json.Value;
const Cx = errors.Cx;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const store_mod = @import("notes_store.zig");
pub const Store = store_mod.Store;
pub const Check = store_mod.Check;
pub const tokenizer_limit = store_mod.tokenizer_limit;
pub const Failure = store_mod.Failure;
pub const Found = store_mod.Found;

/// What a chat request asks of the notes: its fields "notes", "notes_exclude", "notes_past", "notes_cap", "notes_echo".
pub const Ask = struct {
    exclude: []const u32 = &.{},
    past: ?bool = null, // null: notes.is_past(question), as retrieve() decides
    cap: ?u32 = null, // null: the snapshot's cap
    echo: bool = false, // the block itself in the reply's "notes" field
};

fn optBool(cx: *Cx, body: Value, key: []const u8) errors.Refused!?bool {
    const v = body.field(key) orelse return null;
    if (v != .bool) return cx.fail(.request, "{s} must be a boolean", .{key});
    return v.bool;
}

/// The request's notes fields, or null when it asks for none ("notes": true, or a "notes_exclude" list).
pub fn asked(cx: *Cx, body: Value) errors.Refused!?Ask {
    const on = try optBool(cx, body, "notes");
    var ask: Ask = .{};
    var listed = false;
    if (body.field("notes_exclude")) |x| {
        if (x != .array) return cx.refuse("notes_exclude must be a list of note ids");
        const ids = try cx.a.alloc(u32, x.array.len);
        for (x.array, ids) |v, *slot| {
            const n = if (v == .int) v.int64() else null;
            slot.* = std.math.cast(u32, n orelse -1) orelse return cx.refuse("notes_exclude must be a list of note ids");
        }
        ask.exclude = ids;
        listed = true;
    }
    ask.past = try optBool(cx, body, "notes_past");
    ask.echo = (try optBool(cx, body, "notes_echo")) orelse false;
    if (body.field("notes_cap")) |c| {
        const n = if (c == .int) c.int64() else null;
        if (n == null or n.? < 1 or n.? > std.math.maxInt(u32)) return cx.refuse("notes_cap must be a whole number of tokens, 1 or more");
        ask.cap = @intCast(n.?);
    }
    if (on == false and listed) return cx.refuse("notes is false but notes_exclude names notes to leave out");
    if (on == true or listed) return ask;
    if (ask.past != null or ask.cap != null or ask.echo) return cx.refuse("notes_past, notes_cap and notes_echo need \"notes\": true");
    return null;
}

/// One request's lookup, as its reply and the server's log report it.
pub const Used = struct {
    found: Found,
    past: bool,
    past_given: bool,
    cap: u32,
    question_tokens: usize,
    tokenize_ns: i96,
    total_ns: i96,
    in_store: usize,
    echo: bool,

    /// The reply's "notes" field.
    pub fn value(u: *const Used, a: Allocator) Allocator.Error!Value {
        const o = try json.newObject(a);
        const ids = try a.alloc(Value, u.found.ids.len);
        for (u.found.ids, ids) |id, *slot| slot.* = try json.intValue(a, id);
        try o.put(a, "ids", .{ .array = ids });
        try o.put(a, "past", .{ .bool = u.past });
        try o.put(a, "past_from", .{ .string = if (u.past_given) "request" else "question" });
        try o.put(a, "cap", try json.intValue(a, u.cap));
        try o.put(a, "tokens", try json.intValue(a, u.found.tokens));
        try o.put(a, "pack_tokens", try json.intValue(a, u.found.pack_tokens));
        try o.put(a, "dropped", try json.intValue(a, u.found.dropped));
        try o.put(a, "candidates", try json.intValue(a, u.found.candidates));
        try o.put(a, "notes_in_store", try json.intValue(a, u.in_store));
        try o.put(a, "question_tokens", try json.intValue(a, u.question_tokens));
        try o.put(a, "tokenize_us", .{ .float = micro(u.tokenize_ns) });
        try o.put(a, "lookup_us", .{ .float = micro(u.found.lookup_ns) });
        try o.put(a, "fit_us", .{ .float = micro(u.found.fit_ns) });
        try o.put(a, "total_us", .{ .float = micro(u.total_ns) });
        try o.put(a, "block_sha256", if (u.found.block.len > 0) .{ .string = try hexSha(a, u.found.block) } else .null);
        if (u.echo) try o.put(a, "block", .{ .string = u.found.block });
        return .{ .object = o };
    }

    /// The server's line for the request: the note ids, the tokens and the times.
    pub fn logLine(u: *const Used, id: []const u8) void {
        var buf: [600]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (u.found.ids, 0..) |n, k| w.print("{s}{d}", .{ if (k > 0) "," else "", n }) catch break;
        log.line("notes {s}: [{s}] {d} tokens of {d}, past {s}, {d} candidates; tokenize {d:.1} us, lookup {d:.1} us, fit {d:.1} us, total {d:.1} us", .{
            id,                     w.buffered(),                 u.found.tokens,            u.cap, if (u.past) "yes" else "no", u.found.candidates,
            micro(u.tokenize_ns), micro(u.found.lookup_ns), micro(u.found.fit_ns), micro(u.total_ns),
        });
    }
};

fn micro(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e3;
}

fn hexSha(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &out, .{});
    const hex = std.fmt.bytesToHex(out, .lower);
    return a.dupe(u8, &hex);
}

/// The last user message's text in normalized messages ("" when there is none).
pub fn lastUser(list: Value) []const u8 {
    if (list != .array) return "";
    var k = list.array.len;
    while (k > 0) {
        k -= 1;
        const m = list.array[k];
        if (std.mem.eql(u8, json.strOr(m.get("role")), "user")) return json.strOr(m.get("content"));
    }
    return "";
}

/// The client's messages with the block as the first system message, normalized as the client's own would be.
pub fn withBlock(cx: *Cx, raw: Value, block: []const u8, needs_user_after_tool: bool) errors.Refused!Value {
    return withBlockAt(cx, raw, block, needs_user_after_tool, false);
}

/// withBlock(), or with `before_user` the block as a system message right before the last user message.
pub fn withBlockAt(cx: *Cx, raw: Value, block: []const u8, needs_user_after_tool: bool, before_user: bool) errors.Refused!Value {
    const list = raw.items() orelse return cx.refuse("messages must be a non-empty list");
    var at: usize = 0;
    if (before_user) {
        var k = list.len;
        while (k > 0) : (k -= 1) if (std.mem.eql(u8, list[k - 1].strField("role") orelse "", "user")) {
            at = k - 1;
            break;
        };
    }
    const out = try cx.a.alloc(Value, list.len + 1);
    const first = try json.newObject(cx.a);
    try first.put(cx.a, "role", .{ .string = "system" });
    try first.put(cx.a, "content", .{ .string = block });
    @memcpy(out[0..at], list[0..at]);
    out[at] = .{ .object = first };
    @memcpy(out[at + 1 ..], list[at..]);
    return messages.normalize(cx, .{ .array = out }, "system", needs_user_after_tool);
}

/// How the block is looked up and placed: the hop (null: the snapshot's), and before the last user message or first.
pub const Shape = struct { hop: ?@import("notes/index.zig").Hop = null, before_user: bool = false };

/// For a chat request that asks: the lookup on its last user message, and `normalized` with the block put first.
pub fn apply(store: *Store, text: model_text.Text, needs_user_after_tool: bool, cx: *Cx, body: Value, normalized: *Value) errors.Refused!?Used {
    return applyShaped(store, text, needs_user_after_tool, cx, body, normalized, .{});
}

/// apply() with the lookup's hop and the block's place as `shape` says.
pub fn applyShaped(store: *Store, text: model_text.Text, needs_user_after_tool: bool, cx: *Cx, body: Value, normalized: *Value, shape: Shape) errors.Refused!?Used {
    const ask = try asked(cx, body) orelse return null;
    const io = store.io;
    const t0 = clock.nowNs(io);
    const question = lastUser(normalized.*);
    const qids = text.encode(cx.a, question, false) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Template => cx.other("the tokenizer cannot encode the question for the notes"),
    };
    const t1 = clock.nowNs(io);
    const past = ask.past orelse past_mod.isPast(question);
    const cap = ask.cap orelse store.settings().cap;
    const found = store.retrieveWith(cx.a, text, qids, past, cap, ask.exclude, shape.hop) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Tokenizer => cx.other("the tokenizer cannot count the notes block"),
    };
    if (found.block.len > 0) normalized.* = try withBlockAt(cx, body.get("messages").?, found.block, needs_user_after_tool, shape.before_user);
    return .{
        .found = found,
        .past = past,
        .past_given = ask.past != null,
        .cap = cap,
        .question_tokens = qids.len,
        .tokenize_ns = t1 - t0,
        .total_ns = clock.nowNs(io) - t0,
        .in_store = found.in_store,
        .echo = ask.echo,
    };
}
