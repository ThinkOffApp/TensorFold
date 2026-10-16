//! --notes while a reply decodes: the notes looked up again at its sentence ends, and a note that scores high put in.
const std = @import("std");
const api = @import("engine_api");
const json = @import("json.zig");
const errors = @import("errors.zig");
const log = @import("log.zig");
const clock = @import("clock.zig");
const chat = @import("chat.zig");
const prompt_mod = @import("prompt.zig");
const chunk_plan = @import("chunk_plan.zig");
const model_text = @import("model_text.zig");
const reply_text = @import("reply_text.zig");
const notes_route = @import("notes_route.zig");
const lookup = @import("notes/lookup.zig");
const index = @import("notes/index.zig");
const Mailbox = @import("mailbox.zig").Mailbox;
const Server = @import("server.zig").Server;
const Value = json.Value;
const Cx = errors.Cx;
const Allocator = std.mem.Allocator;

/// A check comes at each sentence end of the reply, and at the latest this many reply tokens after the last one.
pub const every: u32 = 48;
/// The most injections one reply takes.
pub const most: usize = 2;
/// A new note qualifies when the query names its subject and its score, that boost in it, is this share of topWeight.
pub const min_share: f64 = 1.0;

/// Where new notes go: (a) into the first block (the default), or (b) a short block right before the assistant turn.
pub const Place = enum { first, turn };

/// A request's notes_decode (default on), notes_decode_place and notes_decode_dry (checks only, for measuring).
pub const Ask = struct { on: bool = true, place: Place = .first, dry: bool = false };

/// The decode fields of a request; `notes_on`: it asked for notes, which they need.
pub fn asked(cx: *Cx, body: Value, notes_on: bool) errors.Refused!Ask {
    var ask: Ask = .{};
    const on = body.field("notes_decode");
    const place = body.field("notes_decode_place");
    const dry = body.field("notes_decode_dry");
    if (!notes_on) {
        if (on != null or place != null or dry != null) return cx.refuse("notes_decode, notes_decode_place and notes_decode_dry need \"notes\": true");
        return ask;
    }
    if (on) |v| {
        if (v != .bool) return cx.refuse("notes_decode must be a boolean");
        ask.on = v.bool;
    }
    if (dry) |v| {
        if (v != .bool) return cx.refuse("notes_decode_dry must be a boolean");
        ask.dry = v.bool;
    }
    if (place) |v| {
        const s = v.str() orelse "";
        ask.place = if (std.mem.eql(u8, s, "turn")) .turn else if (std.mem.eql(u8, s, "first")) .first else return cx.refuse("notes_decode_place must be \"turn\" or \"first\"");
    }
    return ask;
}

/// Whether a reply piece (one token's text) ends a sentence: a full stop, ! or ? before closing marks, or a line break.
pub fn sentenceEnd(piece: []const u8) bool {
    if (std.mem.indexOfScalar(u8, piece, '\n') != null) return true;
    var end = piece.len;
    while (end > 0 and std.mem.indexOfScalar(u8, "\"')]*_ \t", piece[end - 1]) != null) end -= 1;
    const t = piece[0..end];
    if (t.len > 0 and std.mem.indexOfScalar(u8, ".!?", t[t.len - 1]) != null) return true;
    for ([_][]const u8{ "\u{3002}", "\u{ff01}", "\u{ff1f}", "\u{2026}" }) |m| if (std.mem.endsWith(u8, t, m)) return true;
    return false;
}

/// The weight of a key only one note has, log(1 + (N - 0.5) / 1.5): the lookup's subject boost at subject 1.
pub fn topWeight(idx: *const index.Index, past: bool) f64 {
    const n: u32 = idx.n_cur + (if (past) idx.n_hist else 0);
    if (n == 0) return 0;
    return idx.log(1.0 + (@as(f64, @floatFromInt(n)) - 0.5) / 1.5);
}

/// One note put in while the reply decoded.
pub const Injection = struct {
    ids: []const u32,
    shares: []const f64, // each one's score over topWeight
    at: usize, // reply tokens before it
    place: Place,
    block_tokens: usize, // every note the model sees after it, in tokens
    lookup_ns: i96,
    build_ns: i96 = 0, // the continuation's prompt rendered and its request made
    drain_ns: i96 = 0, // the cancel of the request before it, until the engine let it go
    wait_ns: i96 = 0, // the continuation submitted, until its first token (its prefill, most of it)
    prompt: usize, // the continuation's prompt tokens (the answer so far included)
    cached: ?u32 = null, // of them, restored from a kept state
    pause_ns: ?i96 = null, // last token before it to the first after it, as the reply's thread saw them
};

/// One check's best new note (0: none), and for "notes_echo" replies its first few candidates.
pub const Check = struct { at: usize, best: u32 = 0, share: f64 = 0, ids: []const u32 = &.{}, shares: []const f64 = &.{}, named: []const bool = &.{} };

/// The candidates a "notes_echo" reply lists per check.
const echo_top = 8;

/// What a check found: the new notes that qualify and fit, best first, and the block that holds them.
pub const Hit = struct { ids: []const u32, shares: []const f64, block: []const u8, tokens: usize, lookup_ns: i96 };

/// One reply's decode-time lookup: what is in its notes block so far, and what it put in.
pub const Live = struct {
    a: Allocator,
    on: bool,
    store: *notes_route.Store,
    ver: u64, // the store version the first block was read from; another one stops the checks
    question: []const u8,
    past: bool,
    cap: u32,
    exclude: []const u32, // the client's notes_exclude
    place: Place,
    echo: bool,
    dry: bool = false,
    markers: reply_text.Markers = reply_text.think_markers,
    held: std.ArrayList(u32) = .empty, // every note the model sees: the first block's, then the injected
    late: std.ArrayList(u32) = .empty, // (b): the late block's notes
    block: []const u8, // the first block as the prompt has it now
    prepared_block: []const u8 = "", // the first block in the prepared messages, which every continuation starts from
    block_tokens: usize,
    late_block: []const u8 = "",
    late_tokens: usize = 0,
    injections: std.ArrayList(Injection) = .empty,
    checks: std.ArrayList(Check) = .empty,
    n_checks: usize = 0,
    capped: usize = 0, // checks whose qualifying notes the cap left out
    best: Check = .{ .at = 0 },
    check_ns: i96 = 0,
    since: u32 = 0,
    stopped: ?[]const u8 = null,
    prepared: ?*const chat.Prepared = null,
    base: ?*const api.Request = null,
    first: ?*Mailbox = null,
    boxes: std.ArrayList(*Mailbox) = .empty, // the continuations' mailboxes
    carried: api.Stats = .{}, // the counters of the segments before the current one
    pause_from: ?i96 = null,
    submitted: i96 = 0, // when the last continuation was submitted

    fn stop(l: *Live, why: []const u8) void {
        if (l.stopped == null) l.stopped = why;
    }

    /// No checks for this reply, and why.
    pub fn off(l: *Live, why: []const u8) void {
        l.on = false;
        l.stop(why);
    }

    /// Binds the reply about to be submitted; null when its engine state could not be restarted (then nothing runs).
    pub fn bind(l: *Live, srv: *const Server, prepared: *const chat.Prepared, base: *const api.Request, box: *Mailbox) ?*Live {
        if (!l.on) return null;
        l.prepared = prepared;
        l.base = base;
        l.first = box;
        l.markers = srv.markers;
        const why: ?[]const u8 = if (base.structure != null) "structured output" else if (base.call != null) "a required tool call" else if (base.logprobs != null or base.prompt_logprobs != null) "logprobs" else if (base.think_budget > 0) "a thinking budget" else if (prepared.input.prompt != null) "not a chat" else null;
        if (why) |w| {
            l.stop(w);
            return null;
        }
        return l;
    }

    /// Whether the token just generated (its text `piece`) is a check point; counts it.
    pub fn due(l: *Live, piece: []const u8) bool {
        if (l.stopped != null) return false;
        l.since += 1;
        if (!sentenceEnd(piece) and l.since < every) return false;
        l.since = 0;
        return true;
    }

    /// After a reply token (`collected` the reply so far): the continuation to switch to when a check put notes in.
    pub fn atToken(l: *Live, srv: *Server, a: Allocator, collected: []const u32) chat.Failure!?*api.Request {
        if (l.stopped != null) return null;
        if (!l.due(try srv.text.decode(a, collected[collected.len - 1 ..]))) return null;
        const t0 = clock.nowNs(srv.io);
        defer l.check_ns += clock.nowNs(srv.io) - t0;
        // a thinking reply is read whole: its reasoning is where it names who the question is about (measured)
        const hit = (try l.check(srv.text, a, try srv.text.decode(a, collected), collected.len)) orelse return null;
        const t1 = clock.nowNs(srv.io);
        const next = (try l.continuation(srv, a, collected, hit)) orelse return null;
        try l.took(hit, collected.len, next.prompt.len, clock.nowNs(srv.io) - t1);
        return next;
    }

    /// The lookup over the question and the reply so far; the new notes that score at least min_share and fit the cap.
    pub fn check(l: *Live, text: model_text.Text, a: Allocator, reply: []const u8, at: usize) Allocator.Error!?Hit {
        const s = l.store;
        const t0 = clock.nowNs(s.io);
        const v = s.acquire();
        defer s.release(v);
        const idx = v.idx;
        if (idx.ver != l.ver) {
            l.stop("the notes changed during the reply");
            return null;
        }
        const query = try std.mem.concat(a, u8, &.{ l.question, "\n", try plain(a, reply, .{ l.markers.open, l.markers.close }) });
        const qids = text.encode(a, query, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Template => {
                l.stop("the tokenizer cannot encode the reply");
                return null;
            },
        };
        const k = try s.take(idx);
        defer s.give(k);
        const sc = &k.sc;
        const got = try lookup.lookup(idx, sc, qids, l.past, l.cap, try std.mem.concat(a, u32, &.{ l.exclude, l.held.items }));
        const top = topWeight(idx, l.past);
        if (top == 0) return null;
        const names = try named(a, idx, sc);
        // the best of the lookup's own candidates, named or not: what the threshold is weighed against (diagnostics)
        var first: Check = if (got.chosen.len > 0) .{ .at = at, .best = idx.note_id[got.chosen[0]], .share = scoreOf(sc, got.chosen[0]) / top } else .{ .at = at };
        if (first.share > l.best.share) l.best = first;
        l.n_checks += 1;
        if (l.echo) {
            const n = @min(got.chosen.len, echo_top);
            const ids = try l.a.alloc(u32, n);
            const sh = try l.a.alloc(f64, n);
            const ln = try l.a.alloc(bool, n);
            for (got.chosen[0..n], ids, sh, ln) |p, *id, *x, *y| {
                id.* = idx.note_id[p];
                x.* = scoreOf(sc, p) / top;
                y.* = std.mem.indexOfScalar(u32, names.all, idx.entity[p]) != null;
            }
            first.ids = ids;
            first.shares = sh;
            first.named = ln;
            try l.checks.append(l.a, first);
        }
        if (l.dry) return null;
        // the named entities' notes, not in the block nor excluded, by the lookup's order: score, then told
        const boost = top * idx.settings.subject;
        var keys: std.ArrayList(u128) = .empty;
        var score: std.AutoHashMapUnmanaged(u32, f64) = .empty;
        for (names.all, 0..) |e, i| {
            const extra: f64 = if (i >= names.boosted) boost else 0; // lookup() boosted the first ones itself
            try addNotes(a, &score, sc, idx.ent_cur[e], extra);
            if (l.past) for (idx.ent_keys[e]) |pk| try addNotes(a, &score, sc, idx.pair_notes[pk], extra);
        }
        var it = score.iterator();
        while (it.next()) |kv| {
            const id = idx.note_id[kv.key_ptr.*];
            if (std.mem.indexOfScalar(u32, l.exclude, id) != null or std.mem.indexOfScalar(u32, l.held.items, id) != null) continue;
            if (!l.past and idx.state[kv.key_ptr.*] != .current) continue;
            if (kv.value_ptr.* < min_share * top) continue;
            try keys.append(a, lookup.orderKey(kv.value_ptr.*, idx.trank[kv.key_ptr.*], kv.key_ptr.*));
        }
        std.sort.pdq(u128, keys.items, {}, std.sort.asc(u128));
        const fresh = try a.alloc(u32, keys.items.len); // places, best first
        const shares = try a.alloc(f64, keys.items.len);
        for (keys.items, fresh, shares) |key, *p, *x| {
            p.* = @truncate(key);
            x.* = score.get(p.*).? / top;
        }
        if (fresh.len == 0) return null;
        // the block that would hold them, counted by the model's tokenizer: the lowest goes while it is over the cap
        const kept = try placesOf(a, idx, if (l.place == .first) l.held.items else l.late.items);
        var n = fresh.len;
        while (n > 0) : (n -= 1) {
            const shown = try lookup.render(idx, sc, try std.mem.concat(a, u32, &.{ kept, fresh[0..n] }));
            // (b) after a first block says what notes are: its head is not said again, the titles and lines follow it
            const late = l.place == .turn and l.block.len > 0 and std.mem.startsWith(u8, shown.block, idx.head) and shown.block.len > idx.head.len;
            const block = if (late) shown.block[idx.head.len + 1 ..] else shown.block;
            const counted = text.encode(a, block, false) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Template => return null,
            };
            const tokens = counted.len;
            if ((if (l.place == .first) tokens else l.block_tokens + tokens) > l.cap) continue;
            const ids = try a.alloc(u32, n);
            for (fresh[0..n], ids) |p, *id| id.* = idx.note_id[p];
            return .{ .ids = ids, .shares = shares[0..n], .block = try l.a.dupe(u8, block), .tokens = tokens, .lookup_ns = clock.nowNs(s.io) - t0 };
        }
        l.capped += 1;
        return null;
    }

    /// The continuation request: the prompt rendered with the new notes, the reply so far after it; null: none can be.
    pub fn continuation(l: *Live, srv: *Server, a: Allocator, collected: []const u32, hit: Hit) Allocator.Error!?*api.Request {
        const p = l.prepared.?;
        const base = l.base.?;
        var cx: Cx = .{ .a = a };
        var input = p.input;
        input.messages = (try l.withNotes(srv, a, p.input.messages, hit.block)) orelse return null;
        const rendered = prompt_mod.prepare(srv, &cx, input, p.thinking, p.effort) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Refused => {
                l.stop("the prompt with the new notes cannot be rendered");
                return null;
            },
        };
        const ids = try std.mem.concat(a, u32, &.{ rendered.ids, collected });
        var left = base.max_tokens -| @as(u32, @intCast(collected.len));
        const window = srv.info.context_window;
        if (window > 0) left = @min(left, @as(u32, window) -| @as(u32, @intCast(ids.len)));
        if (left == 0) return null;
        const req = try a.create(api.Request);
        req.* = base.*;
        req.prompt = ids;
        req.max_tokens = left;
        req.history_len = @intCast(rendered.history_len);
        req.rewind_len = @intCast(rendered.rewind_len);
        // the shared cuts and chunk starts as chat.prepare makes them, for the new prompt
        const system_len = prompt_mod.systemPrefixLen(srv, &cx, input.messages, input.tools, rendered.ids, p.thinking, p.effort);
        var shared: std.ArrayList(u32) = .empty;
        if (system_len > 0) for ([_]i64{ @as(i64, @intCast(system_len)) - 2048, @as(i64, @intCast(system_len)) - 512, @intCast(system_len) }) |cut| {
            if (cut >= 512) try shared.append(a, @intCast(cut));
        };
        req.shared_prefixes = shared.items;
        req.chunks = try chunk_plan.withCut(a, try srv.chunks.starts(a, ids), if (srv.chunks.step > 0) @intCast(@max(system_len, 1) - 1) else 0, ids.len, srv.chunks.min_chunk);
        req.decode_spans = prompt_mod.replySpans(srv, &cx, ids) catch &.{};
        if (base.decide != null) req.decide = prompt_mod.decideOf(srv, rendered.ids);
        return req;
    }

    /// The prepared messages with `block` in: (a) in place of the first block, or (b) a system message after the last.
    fn withNotes(l: *Live, srv: *const Server, a: Allocator, messages: Value, block: []const u8) Allocator.Error!?Value {
        const list = messages.items() orelse return null;
        if (l.place == .turn) {
            const out = try a.alloc(Value, list.len + 1);
            @memcpy(out[0..list.len], list);
            out[list.len] = try message(a, srv.late_system, block);
            return .{ .array = out };
        }
        const lead = list.len > 0 and std.mem.eql(u8, list[0].strField("role") orelse "", "system");
        if (!lead) {
            if (l.prepared_block.len > 0) {
                l.stop("the first message is no longer the notes block");
                return null;
            }
            const out = try a.alloc(Value, list.len + 1);
            out[0] = try message(a, "system", block);
            @memcpy(out[1..], list);
            return .{ .array = out };
        }
        const content = list[0].strField("content") orelse "";
        const was = l.prepared_block;
        if (was.len > 0 and !std.mem.startsWith(u8, content, was)) {
            l.stop("the first system message does not start with the notes block");
            return null;
        }
        const rest = if (was.len > 0) content[was.len..] else try std.mem.concat(a, u8, &.{ "\n\n", content });
        const first = try json.copyObject(a, list[0].object);
        try first.put(a, "content", .{ .string = try std.mem.concat(a, u8, &.{ block, rest }) });
        const out = try a.dupe(Value, list);
        out[0] = .{ .object = first };
        return .{ .array = out };
    }

    /// Records an injection the reply is switching to.
    fn took(l: *Live, hit: Hit, at: usize, prompt: usize, build_ns: i96) Allocator.Error!void {
        try l.held.appendSlice(l.a, hit.ids);
        if (l.place == .turn) {
            try l.late.appendSlice(l.a, hit.ids);
            l.late_block = hit.block;
            l.late_tokens = hit.tokens;
        } else {
            l.block = hit.block;
            l.block_tokens = hit.tokens;
        }
        const ids = try l.a.dupe(u32, hit.ids);
        const shares = try l.a.dupe(f64, hit.shares);
        try l.injections.append(l.a, .{ .ids = ids, .shares = shares, .at = at, .place = l.place, .block_tokens = l.block_tokens + l.late_tokens, .lookup_ns = hit.lookup_ns, .build_ns = build_ns, .prompt = prompt });
        if (l.injections.items.len >= most) l.stop("two injections");
    }

    /// The mailbox of the next segment (its request cancelled at `cancelled`); the old one's counters are carried.
    pub fn segment(l: *Live, srv: *const Server, old: *Mailbox, cancelled: i96) Allocator.Error!*Mailbox {
        l.submitted = clock.nowNs(srv.io);
        if (l.injections.items.len > 0) l.injections.items[l.injections.items.len - 1].drain_ns = l.submitted - cancelled;
        l.carried.rounds += old.stats.rounds;
        l.carried.drafted += old.stats.drafted;
        l.carried.accepted += old.stats.accepted;
        if (old.stats.min_rows > 0 and (l.carried.min_rows == 0 or old.stats.min_rows < l.carried.min_rows)) l.carried.min_rows = old.stats.min_rows;
        try l.boxes.ensureUnusedCapacity(l.a, 1);
        const box = try l.a.create(Mailbox);
        box.* = .{ .io = srv.io, .gpa = srv.gpa };
        l.boxes.appendAssumeCapacity(box);
        return box;
    }

    /// Tokens landed at `arrived` from `box`: the pause before them ends; `switching`: a new one starts after them.
    pub fn landed(l: *Live, id: []const u8, arrived: i96, box: *const Mailbox, switching: bool) void {
        if (l.pause_from) |from| if (box != l.first) {
            const inj = &l.injections.items[l.injections.items.len - 1];
            inj.pause_ns = arrived - from;
            inj.wait_ns = arrived - l.submitted;
            inj.cached = box.cached;
            l.pause_from = null;
            logLine(id, inj);
        };
        if (switching) l.pause_from = arrived;
    }

    /// The last segment's mailbox as the reply's: the earlier segments' counters, the first one's prompt pass.
    pub fn carry(l: *const Live, m: *Mailbox) void {
        const f = l.first orelse return;
        if (m == f) return;
        m.stats.rounds += l.carried.rounds;
        m.stats.drafted += l.carried.drafted;
        m.stats.accepted += l.carried.accepted;
        if (l.carried.min_rows > 0 and (m.stats.min_rows == 0 or l.carried.min_rows < m.stats.min_rows)) m.stats.min_rows = l.carried.min_rows;
        m.stats.prefill_seconds = f.stats.prefill_seconds;
        m.cached = f.cached;
        m.prefilled_ns = f.prefilled_ns;
        std.mem.swap([]u32, &m.widths, &f.widths);
        std.mem.swap([]bool, &m.raised, &f.raised);
    }

    pub fn free(l: *Live) void {
        for (l.boxes.items) |b| b.deinit();
        l.boxes.clearRetainingCapacity();
    }

    /// The reply's notes.decode field.
    pub fn value(l: *const Live, a: Allocator) Allocator.Error!Value {
        const o = try json.newObject(a);
        try o.put(a, "on", .{ .bool = l.on });
        if (!l.on) {
            if (l.stopped) |s| try o.put(a, "stopped", .{ .string = s });
            return .{ .object = o };
        }
        try o.put(a, "place", .{ .string = @tagName(l.place) });
        if (l.dry) try o.put(a, "dry", .{ .bool = true });
        try o.put(a, "min_share", .{ .float = min_share });
        try o.put(a, "checks", try json.intValue(a, l.n_checks));
        try o.put(a, "capped", try json.intValue(a, l.capped));
        try o.put(a, "check_us", .{ .float = micro(l.check_ns) });
        try o.put(a, "best_share", .{ .float = l.best.share });
        try o.put(a, "best_id", if (l.best.best > 0) try json.intValue(a, l.best.best) else .null);
        const list = try a.alloc(Value, l.injections.items.len);
        for (l.injections.items, list) |*inj, *slot| slot.* = try injectionValue(a, inj);
        try o.put(a, "injected", .{ .array = list });
        try o.put(a, "ids", try intsValue(a, l.held.items));
        try o.put(a, "stopped", if (l.stopped) |s| .{ .string = s } else .null);
        if (!l.echo) return .{ .object = o };
        const checks = try a.alloc(Value, l.checks.items.len);
        for (l.checks.items, checks) |c, *slot| {
            const x = try json.newObject(a);
            try x.put(a, "at", try json.intValue(a, c.at));
            try x.put(a, "best_id", if (c.best > 0) try json.intValue(a, c.best) else .null);
            try x.put(a, "share", .{ .float = c.share });
            try x.put(a, "ids", try intsValue(a, c.ids));
            const ln = try a.alloc(Value, c.named.len);
            for (c.named, ln) |b, *v| v.* = .{ .bool = b };
            try x.put(a, "named", .{ .array = ln });
            const sh = try a.alloc(Value, c.shares.len);
            for (c.shares, sh) |f, *v| v.* = .{ .float = f };
            try x.put(a, "shares", .{ .array = sh });
            slot.* = .{ .object = x };
        }
        try o.put(a, "check_list", .{ .array = checks });
        try o.put(a, "block", .{ .string = if (l.place == .first) l.block else l.late_block });
        return .{ .object = o };
    }
};

/// Sets up the decode-time lookup of a chat request that asked for notes (`used`); null when it asked for none.
pub fn setup(srv: *const Server, cx: *Cx, body: Value, used: ?*const notes_route.Used, messages: Value) errors.Refused!?*Live {
    const store = srv.notes orelse return null;
    const ask = try asked(cx, body, used != null);
    const u = used orelse return null;
    const notes_ask = (try notes_route.asked(cx, body)) orelse notes_route.Ask{};
    const l = try cx.a.create(Live);
    // (b) needs a template that keeps a later system message in place; a template that makes it a user turn gets (a)
    const place: Place = if (ask.place == .turn and !std.mem.eql(u8, srv.late_system, "system")) .first else ask.place;
    l.* = .{ .a = cx.a, .on = ask.on, .store = store, .ver = u.found.ver, .question = notes_route.lastUser(messages), .past = u.past, .cap = u.cap, .exclude = notes_ask.exclude, .place = place, .echo = u.echo, .dry = ask.dry, .block = u.found.block, .prepared_block = u.found.block, .block_tokens = if (u.found.block.len > 0) u.found.tokens else 0 };
    try l.held.appendSlice(cx.a, u.found.ids);
    return l;
}

/// The entities the query names: first the `boosted` ones lookup() matched (names of 2 to 8 keys), then one-key names.
const Named = struct { all: []const u32, boosted: usize };

fn named(a: Allocator, idx: *const index.Index, sc: *const lookup.Scratch) Allocator.Error!Named {
    var out: std.ArrayList(u32) = .empty;
    for (sc.found.items) |e| if (std.mem.indexOfScalar(u32, out.items, e) == null) try out.append(a, e);
    const boosted = out.items.len;
    for (sc.qkeys.items) |k| if (idx.names.get(k)) |e| if (std.mem.indexOfScalar(u32, out.items, e) == null) try out.append(a, e);
    return .{ .all = out.items, .boosted = boosted };
}

/// A note's score in this lookup (0: it has none).
fn scoreOf(sc: *const lookup.Scratch, p: u32) f64 {
    return if (sc.slot[p].stamp == sc.gen) sc.slot[p].score else 0;
}

/// Each note in `notes` with its lookup score plus `extra` (the subject boost lookup() gives only longer names).
fn addNotes(a: Allocator, score: *std.AutoHashMapUnmanaged(u32, f64), sc: *const lookup.Scratch, notes: []const u32, extra: f64) Allocator.Error!void {
    for (notes) |p| {
        const r = try score.getOrPut(a, p);
        r.value_ptr.* = (if (r.found_existing) r.value_ptr.* else scoreOf(sc, p)) + extra;
    }
}

fn message(a: Allocator, role: []const u8, content: []const u8) Allocator.Error!Value {
    const o = try json.newObject(a);
    try o.put(a, "role", .{ .string = role });
    try o.put(a, "content", .{ .string = content });
    return .{ .object = o };
}

/// The reply's text without the think markers, which are no words of it.
fn plain(a: Allocator, reply: []const u8, markers: [2][]const u8) Allocator.Error![]const u8 {
    var out: []const u8 = reply;
    for ([_][]const u8{ markers[0], markers[1], "<think>", "</think>" }) |m| if (m.len > 0 and std.mem.indexOf(u8, out, m) != null) {
        out = try std.mem.replaceOwned(u8, a, out, m, " ");
    };
    return out;
}

fn placesOf(a: Allocator, idx: *const index.Index, ids: []const u32) Allocator.Error![]const u32 {
    const out = try a.alloc(u32, ids.len);
    var n: usize = 0;
    for (ids) |id| if (idx.placeOfId(id)) |p| {
        out[n] = p;
        n += 1;
    };
    return out[0..n];
}

fn micro(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e3;
}

fn intsValue(a: Allocator, xs: []const u32) Allocator.Error!Value {
    const out = try a.alloc(Value, xs.len);
    for (xs, out) |x, *slot| slot.* = try json.intValue(a, x);
    return .{ .array = out };
}

fn injectionValue(a: Allocator, inj: *const Injection) Allocator.Error!Value {
    const o = try json.newObject(a);
    try o.put(a, "ids", try intsValue(a, inj.ids));
    const shares = try a.alloc(Value, inj.shares.len);
    for (inj.shares, shares) |s, *slot| slot.* = .{ .float = s };
    try o.put(a, "shares", .{ .array = shares });
    try o.put(a, "at_token", try json.intValue(a, inj.at));
    try o.put(a, "place", .{ .string = @tagName(inj.place) });
    try o.put(a, "block_tokens", try json.intValue(a, inj.block_tokens));
    try o.put(a, "lookup_us", .{ .float = micro(inj.lookup_ns) });
    try o.put(a, "prompt_tokens", try json.intValue(a, inj.prompt));
    try o.put(a, "cached_tokens", if (inj.cached) |c| try json.intValue(a, c) else .null);
    try o.put(a, "pause_ms", if (inj.pause_ns) |p| .{ .float = micro(p) / 1e3 } else .null);
    try o.put(a, "build_us", .{ .float = micro(inj.build_ns) });
    try o.put(a, "drain_ms", .{ .float = micro(inj.drain_ns) / 1e3 });
    try o.put(a, "wait_ms", .{ .float = micro(inj.wait_ns) / 1e3 });
    return .{ .object = o };
}

/// The server's line for one injection: which notes, after which reply token, and the pause it made.
fn logLine(id: []const u8, inj: *const Injection) void {
    var buf: [200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (inj.ids, 0..) |n, k| w.print("{s}{d}", .{ if (k > 0) "," else "", n }) catch break;
    const cached = inj.cached orelse 0;
    log.line("notes decode {s}: [{s}] put in after reply token {d} ({s}), pause {d:.1} ms (lookup {d:.1} us, render {d:.1} us, cancel {d:.1} ms, prefill and first token {d:.1} ms); prompt {d} tokens, {d} cached, {d} prefilled; notes {d} tokens", .{
        id,                       w.buffered(),                   inj.at,     @tagName(inj.place), micro(inj.pause_ns orelse 0) / 1e3, micro(inj.lookup_ns), micro(inj.build_ns),
        micro(inj.drain_ns) / 1e3, micro(inj.wait_ns) / 1e3, inj.prompt, cached,              inj.prompt -| cached,            inj.block_tokens,
    });
}
