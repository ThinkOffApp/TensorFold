//! --notes: LLWZ's note lookup inside the server, per chat request, before the template renders the prompt.
const std = @import("std");
const json = @import("json.zig");
const errors = @import("errors.zig");
const messages = @import("messages.zig");
const model_text = @import("model_text.zig");
const log = @import("log.zig");
const clock = @import("clock.zig");
const index = @import("notes/index.zig");
const lookup = @import("notes/lookup.zig");
const past_mod = @import("notes/past.zig");
const Value = json.Value;
const Cx = errors.Cx;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// How a snapshot's tokenizer was checked: the tokenizer.json SHA-256 it names, or its vocabulary size only.
pub const Check = enum { sha256, vocabulary_only };

/// The most of tokenizer.json the startup check reads (the grammar compiler reads it under the same limit).
pub const tokenizer_limit: usize = 256 << 20;

/// One owner's notes (a snapshot from LLWZ's zengine/notes_export.py), read-only, and lookup scratch for its threads.
pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    idx: *index.Index,
    mutex: std.Io.Mutex = .init,
    free: std.ArrayList(*lookup.Scratch) = .empty,
    load_ms: f64 = 0,
    check: Check = .vocabulary_only,

    /// Loads the snapshot at `path` for a model whose tokenizer is `text` (its tokenizer.json lies in `model_dir`).
    pub fn open(gpa: Allocator, io: std.Io, path: []const u8, text: model_text.Text, model_dir: []const u8, problem: *[]const u8) !*Store {
        return openLimited(gpa, io, path, text, model_dir, tokenizer_limit, problem);
    }

    /// open() with the tokenizer.json read limit given; a named hash passes only when the model's is read and equal.
    pub fn openLimited(gpa: Allocator, io: std.Io, path: []const u8, text: model_text.Text, model_dir: []const u8, limit: usize, problem: *[]const u8) !*Store {
        const t0 = clock.nowNs(io);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            problem.* = "the snapshot file cannot be read";
            return e;
        };
        defer gpa.free(bytes);
        const s = try load(gpa, io, bytes, text, problem);
        errdefer s.deinit();
        if (s.idx.tokenizer_sha256.len > 0) {
            const sha = try tokenizerSha(gpa, io, model_dir, limit, problem);
            if (!std.mem.eql(u8, &sha, s.idx.tokenizer_sha256)) {
                problem.* = "the snapshot names a tokenizer.json SHA-256 that is not this model's: it was exported with another tokenizer";
                return error.TokenizerMismatch;
            }
            s.check = .sha256;
        }
        s.load_ms = clock.seconds(clock.nowNs(io) - t0) * 1e3;
        return s;
    }

    /// The startup log line: what was loaded, and how its tokenizer was checked.
    pub fn startupLine(s: *const Store, buf: []u8, path: []const u8) []const u8 {
        const ix = s.idx;
        const checked = switch (s.check) {
            .sha256 => "tokenizer checked: the model's tokenizer.json SHA-256 equals the snapshot's",
            .vocabulary_only => "tokenizer checked by vocabulary size only (vocabulary-only compatibility): the snapshot names no tokenizer.json SHA-256",
        };
        return std.fmt.bufPrint(buf, "notes: {d} notes ({d} current) from {s}, cap {d}, loaded in {d:.1} ms; {s}; a chat request sends \"notes\": true to have them looked up", .{ ix.notes(), ix.n_cur, path, ix.settings.cap, s.load_ms, checked }) catch buf;
    }

    /// A snapshot's JSON text as a store, checked against the model's vocabulary size.
    pub fn load(gpa: Allocator, io: std.Io, bytes: []const u8, text: model_text.Text, problem: *[]const u8) !*Store {
        const idx = index.Index.load(gpa, bytes) catch |e| {
            problem.* = switch (e) {
                error.Unsupported => "the snapshot needs what this lookup does not do (n_max over 4, or a stand-in tokenizer)",
                error.OutOfMemory => "out of memory",
                error.BadSnapshot => "the file is not a valid lw-notes-snapshot/1 snapshot",
            };
            return e;
        };
        errdefer idx.deinit();
        if (idx.vkey.len != text.vocabSize()) {
            problem.* = "the snapshot's vocabulary is not the model tokenizer's size";
            return error.BadSnapshot;
        }
        const s = try gpa.create(Store);
        s.* = .{ .gpa = gpa, .io = io, .idx = idx };
        return s;
    }

    pub fn deinit(s: *Store) void {
        for (s.free.items) |sc| {
            sc.deinit();
            s.gpa.destroy(sc);
        }
        s.free.deinit(s.gpa);
        s.idx.deinit();
        s.gpa.destroy(s);
    }

    fn take(s: *Store) Allocator.Error!*lookup.Scratch {
        s.mutex.lockUncancelable(s.io);
        const kept = s.free.pop();
        s.mutex.unlock(s.io);
        if (kept) |sc| return sc;
        const sc = try s.gpa.create(lookup.Scratch);
        errdefer s.gpa.destroy(sc);
        sc.* = try lookup.Scratch.init(s.gpa, s.idx);
        return sc;
    }

    fn give(s: *Store, sc: *lookup.Scratch) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.free.append(s.gpa, sc) catch {
            sc.deinit();
            s.gpa.destroy(sc);
        };
    }

    /// NoteStore.retrieve(owner, question, cap, past, exclude) from the question's ids, fit() counted by `text`.
    pub fn retrieve(s: *Store, a: Allocator, text: model_text.Text, qids: []const u32, past: bool, cap: u32, exclude: []const u32) Failure!Found {
        const sc = try s.take();
        defer s.give(sc);
        const io = s.io;
        const t0 = clock.nowNs(io);
        const packed_notes = try lookup.lookup(s.idx, sc, qids, past, cap, exclude);
        const chosen = try a.dupe(u32, packed_notes.chosen);
        var shown = try lookup.render(s.idx, sc, chosen);
        const t1 = clock.nowNs(io);
        // fit(): the whole block counted by the model's tokenizer; the lowest ranked note goes while it is over the cap
        var n = chosen.len;
        var tokens: usize = 0;
        while (n > 0) {
            tokens = (text.encode(a, shown.block, false) catch return error.Tokenizer).len;
            if (tokens <= cap) break;
            n -= 1;
            tokens = 0;
            shown = try lookup.render(s.idx, sc, chosen[0..n]);
        }
        const t2 = clock.nowNs(io);
        return .{
            .ids = try a.dupe(u32, shown.ids),
            .block = try a.dupe(u8, shown.block),
            .tokens = tokens,
            .pack_tokens = packed_notes.tokens,
            .dropped = chosen.len - n,
            .candidates = packed_notes.candidates,
            .lookup_ns = t1 - t0,
            .fit_ns = t2 - t1,
        };
    }
};

pub const Failure = error{ OutOfMemory, Tokenizer };

/// What retrieve() found.
pub const Found = struct {
    ids: []const u32,
    block: []const u8, // "" when nothing is retrieved: then no system message goes in
    tokens: usize, // the block's tokens by the model's tokenizer (fit()'s count)
    pack_tokens: u32, // pack()'s sum of the parts
    dropped: usize, // notes fit() took out
    candidates: u32,
    lookup_ns: i96,
    fit_ns: i96,
};

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

/// The SHA-256 of `model_dir`/tokenizer.json in hex; a file that cannot be read is an error naming why, never a pass.
fn tokenizerSha(gpa: Allocator, io: std.Io, model_dir: []const u8, limit: usize, problem: *[]const u8) ![64]u8 {
    if (model_dir.len == 0) {
        problem.* = "the snapshot names a tokenizer.json SHA-256, and the server has no model folder to read tokenizer.json from";
        return error.NoModelDir;
    }
    const path = try std.fs.path.join(gpa, &.{ model_dir, "tokenizer.json" });
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |e| {
        problem.* = switch (e) {
            error.FileNotFound => "the snapshot names a tokenizer.json SHA-256, and the model folder has no tokenizer.json to check it against",
            error.StreamTooLong => "the snapshot names a tokenizer.json SHA-256, and the model's tokenizer.json is over the read limit (256 MiB), so it cannot be checked",
            error.OutOfMemory => "out of memory reading the model's tokenizer.json",
            else => "the snapshot names a tokenizer.json SHA-256, and the model's tokenizer.json cannot be read to check it",
        };
        return e;
    };
    defer gpa.free(bytes);
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &out, .{});
    return std.fmt.bytesToHex(out, .lower);
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
    const list = raw.items() orelse return cx.refuse("messages must be a non-empty list");
    const out = try cx.a.alloc(Value, list.len + 1);
    const first = try json.newObject(cx.a);
    try first.put(cx.a, "role", .{ .string = "system" });
    try first.put(cx.a, "content", .{ .string = block });
    out[0] = .{ .object = first };
    @memcpy(out[1..], list);
    return messages.normalize(cx, .{ .array = out }, "system", needs_user_after_tool);
}

/// For a chat request that asks: the lookup on its last user message, and `normalized` with the block put first.
pub fn apply(store: *Store, text: model_text.Text, needs_user_after_tool: bool, cx: *Cx, body: Value, normalized: *Value) errors.Refused!?Used {
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
    const cap = ask.cap orelse store.idx.settings.cap;
    const found = store.retrieve(cx.a, text, qids, past, cap, ask.exclude) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Tokenizer => cx.other("the tokenizer cannot count the notes block"),
    };
    if (found.block.len > 0) normalized.* = try withBlock(cx, body.get("messages").?, found.block, needs_user_after_tool);
    return .{
        .found = found,
        .past = past,
        .past_given = ask.past != null,
        .cap = cap,
        .question_tokens = qids.len,
        .tokenize_ns = t1 - t0,
        .total_ns = clock.nowNs(io) - t0,
        .in_store = store.idx.notes(),
        .echo = ask.echo,
    };
}
