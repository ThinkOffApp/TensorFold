//! --notes-promote-every: nightly promotion in the server: its thread, the chat lookup's hooks, and /v1/promotion.
const std = @import("std");
const api = @import("engine_api");
const json = @import("json.zig");
const errors = @import("errors.zig");
const log = @import("log.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const ops = @import("notes_ops.zig");
const notes_route = @import("notes_route.zig");
const past_mod = @import("notes/past.zig");
const slide = @import("slide.zig");
const slide_ask = @import("slide_ask.zig");
const side = @import("slide_side.zig");
const wording = @import("slide_words.zig");
const prompts = @import("slide_prompts.zig");
const routes = @import("routes.zig");
const http_body = @import("http_body.zig");
const Server = @import("server.zig").Server;
const Conn = @import("http_conn.zig").Conn;
const Store = notes_route.Store;
const Value = json.Value;
const Allocator = std.mem.Allocator;

/// How a note's own question is asked for: the model writes what its user would ask to hear the note again.
const question_prompt = "The user once told you: \"{s}\"\nWrite the one short question the user would ask you later to hear this again, in the user's own words (for example: What is my dog's name?). Reply with the question only.";

/// Tokens a night's question is answered in at most (the learner's own checks read 48).
pub const answer_tokens = 48;

/// What `--notes-promote-*` asked for.
pub const Options = struct { every_ms: i64, settings: promote.Settings = .{} };

/// "600", "600s", "10m", "24h" in milliseconds (null: not a duration of a second or more).
pub fn parseDuration(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    const unit: i64 = switch (text[text.len - 1]) {
        's' => 1000,
        'm' => 60_000,
        'h' => 3_600_000,
        '0'...'9' => 1000,
        else => return null,
    };
    const digits = if (std.ascii.isDigit(text[text.len - 1])) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(i64, digits, 10) catch return null;
    if (n < 1 or n > 366 * 24 * 3600) return null;
    return n * unit;
}

/// A note's promotion key: its write's source, or "s<id>" for a snapshot's note.
pub fn keyOf(a: Allocator, v: ops.View) Allocator.Error![]const u8 {
    return if (v.source) |s| a.dupe(u8, s) else std.fmt.allocPrint(a, "s{d}", .{v.id});
}

/// A night's stop check for the learner and the chat calls: true once the server stops.
const Stop = struct {
    flag: *std.atomic.Value(bool),
    pub fn check(s: Stop) bool {
        return s.flag.load(.acquire);
    }
};

pub const Promoter = struct {
    gpa: Allocator,
    io: std.Io,
    srv: *Server,
    store: *Store,
    path: []u8, // the state file, SNAPSHOT.promote
    every_ms: i64,
    state: promote.State, // the night thread's alone
    mu: std.Io.Mutex = .init, // everything below
    seen: std.StringHashMapUnmanaged(u32) = .empty, // key -> nights done when first in a block
    retrieved: std.StringHashMapUnmanaged(void) = .empty,
    weights: std.ArrayList([]u8) = .empty, // the in-weights keys production leaves out
    gen: u64 = 1, // bumped when `weights` changes
    cache_ver: u64 = 0,
    cache_gen: u64 = 0,
    cache_keys: std.AutoHashMapUnmanaged(u32, []u8) = .empty, // note id -> key, at cache_ver
    cache_excl: std.ArrayList(u32) = .empty,
    report: []u8 = &.{}, // the state as last written
    nights_done: u32 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    wake: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    last_end_ms: i64 = 0,

    /// The promoter for `store`, its state read from SNAPSHOT.promote when there is one; the thread not started.
    pub fn init(gpa: Allocator, io: std.Io, srv: *Server, store: *Store, snapshot: []const u8, o: Options, problem: *[]const u8) !*Promoter {
        const p = try gpa.create(Promoter);
        errdefer gpa.destroy(p);
        const path = try std.fmt.allocPrint(gpa, "{s}.promote", .{snapshot});
        errdefer gpa.free(path);
        var state = promote.State.init(gpa, o.settings);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20))) |bytes| {
            defer gpa.free(bytes);
            state.deinit();
            state = pjson.decode(gpa, bytes, o.settings) catch {
                problem.* = "the promotion state file cannot be read as tf-notes-promote/1";
                return error.BadState;
            };
        } else |e| if (e != error.FileNotFound) {
            problem.* = "the promotion state file cannot be read";
            return e;
        }
        p.* = .{ .gpa = gpa, .io = io, .srv = srv, .store = store, .path = path, .every_ms = o.every_ms, .state = state, .nights_done = state.nights_done, .last_end_ms = clockMs(io) };
        try p.publish();
        return p;
    }

    pub fn start(p: *Promoter) !void {
        p.thread = try std.Thread.spawn(.{ .stack_size = 16 << 20 }, loop, .{p});
    }

    pub fn deinit(p: *Promoter) void {
        p.stop.store(true, .release);
        if (p.thread) |t| t.join();
        const g = p.gpa;
        var it = p.seen.keyIterator();
        while (it.next()) |k| g.free(k.*);
        p.seen.deinit(g);
        p.retrieved.deinit(g);
        for (p.weights.items) |k| g.free(k);
        p.weights.deinit(g);
        p.clearCache();
        p.cache_keys.deinit(g);
        p.cache_excl.deinit(g);
        g.free(p.report);
        g.free(p.path);
        p.state.deinit();
        g.destroy(p);
    }

    fn clearCache(p: *Promoter) void {
        var it = p.cache_keys.valueIterator();
        while (it.next()) |k| p.gpa.free(k.*);
        p.cache_keys.clearRetainingCapacity();
        p.cache_excl.clearRetainingCapacity();
    }

    /// The report and the in-weights keys from the state, for the hooks and GET /v1/promotion.
    fn publish(p: *Promoter) !void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const bytes = try p.gpa.dupe(u8, try pjson.encode(&p.state, arena.allocator()));
        const keys = try p.state.inWeights(arena.allocator());
        p.mu.lockUncancelable(p.io);
        defer p.mu.unlock(p.io);
        p.gpa.free(p.report);
        p.report = bytes;
        for (p.weights.items) |k| p.gpa.free(k);
        p.weights.clearRetainingCapacity();
        for (keys) |k| try p.weights.append(p.gpa, try p.gpa.dupe(u8, k));
        p.gen += 1;
        p.nights_done = p.state.nights_done;
    }

    /// The note ids and keys at the store's version now (the writer's lock taken once after each write).
    fn refresh(p: *Promoter) !void {
        const v = p.store.acquire();
        const ver = v.idx.ver;
        p.store.release(v);
        if (ver == p.cache_ver and p.gen == p.cache_gen) return;
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const list = try ops.list(p.store, arena.allocator(), false);
        p.clearCache();
        for (list) |n| {
            const key = try p.gpa.dupe(u8, try keyOf(arena.allocator(), n));
            errdefer p.gpa.free(key);
            try p.cache_keys.put(p.gpa, n.id, key);
            for (p.weights.items) |w| if (std.mem.eql(u8, w, key)) try p.cache_excl.append(p.gpa, n.id);
        }
        p.cache_ver = ver;
        p.cache_gen = p.gen;
    }

    /// A chat request's body with the in-weights notes' ids added to its notes_exclude (only for "notes": true).
    pub fn requestBody(p: *Promoter, a: Allocator, body: Value) Allocator.Error!Value {
        const on = body.get("notes") orelse return body;
        if (on != .bool or !on.bool) return body;
        p.mu.lockUncancelable(p.io);
        defer p.mu.unlock(p.io);
        p.refresh() catch return body;
        if (p.cache_excl.items.len == 0) return body;
        var ids: std.ArrayList(Value) = .empty;
        if (body.field("notes_exclude")) |x| if (x.items()) |xs| try ids.appendSlice(a, xs);
        for (p.cache_excl.items) |id| try ids.append(a, try json.intValue(a, id));
        const o = try json.copyObject(a, body.object);
        try o.put(a, "notes_exclude", .{ .array = ids.items });
        return .{ .object = o };
    }

    /// The note ids a chat request's block held: each counts as used (retrieved) for its note's promotion.
    pub fn sawBlock(p: *Promoter, ids: []const u32) void {
        if (ids.len == 0) return;
        p.mu.lockUncancelable(p.io);
        defer p.mu.unlock(p.io);
        p.refresh() catch return;
        for (ids) |id| {
            const key = p.cache_keys.get(id) orelse continue;
            if (p.seen.contains(key)) continue;
            const own = p.gpa.dupe(u8, key) catch return;
            p.seen.put(p.gpa, own, p.nights_done) catch {
                p.gpa.free(own);
                return;
            };
            p.retrieved.put(p.gpa, own, {}) catch {};
        }
    }

    fn loop(p: *Promoter) void {
        // an erase a stop or a failure left half done is finished first
        p.srv.teacher.learning.lockUncancelable(p.io);
        p.drainPending();
        p.srv.teacher.learning.unlock(p.io);
        while (!p.stop.load(.acquire)) {
            std.Io.sleep(p.io, .fromMilliseconds(500), .awake) catch {};
            const due = clockMs(p.io) - p.last_end_ms >= p.every_ms;
            if (!due and !p.wake.load(.acquire)) continue;
            p.wake.store(false, .release);
            p.runNight();
            p.last_end_ms = clockMs(p.io);
        }
    }

    /// One night under the learner's lock; on failure the state goes back to the file (an open night: a rebuild next).
    pub fn runNight(p: *Promoter) void {
        p.running.store(true, .release);
        defer p.running.store(false, .release);
        p.srv.teacher.learning.lockUncancelable(p.io);
        defer p.srv.teacher.learning.unlock(p.io);
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        var b: Backend = .{ .p = p };
        b.recover(arena.allocator()) catch {};
        p.drainPending();
        log.line("notes promotion: night {d} begins", .{p.state.nights_done + 1});
        const n = promote.night(&p.state, arena.allocator(), &b) catch |e| {
            log.line("notes promotion: night {d} stopped ({s}); the state is the file's, and the next night rebuilds", .{ p.state.nights_done + 1, @errorName(e) });
            p.reload();
            return;
        };
        if (n.worse_list.len > 0) log.line("notes promotion: night {d}: worse: {s}", .{ n.night, n.worse_list });
        log.line("notes promotion: night {d}: {d} due, {d} stale, plan {s} ({d} tried, {d} rejected), {d} taught ({d} kept, {d} missed), {d} worse of {d} probes; alone {d} of {d} right, {d} left the prompt, {d} back; {d} in weights, {d} in the pocket; {d} asks in {d:.1} s", .{ n.night, n.due, n.stale, n.plan, n.tries, n.rejected, n.taught, n.kept, n.missed, n.worse, n.probes, n.alone_right, n.alone_asked, n.left_prompt, n.back_to_prompt, n.in_weights, n.pocket, n.asks, n.secs });
        p.compact();
        p.publish() catch {};
        p.drainPending();
    }

    /// An erase reaches the pocket: the erased notes' facts' neurons zeroed now, or once the running night ends.
    pub fn erased(p: *Promoter, a: Allocator, sources: []const []const u8) Allocator.Error!Value {
        _ = sources; // the store is the record: every fact in the pocket whose note it no longer holds is a target
        const o = try json.newObject(a);
        if (!p.srv.teacher.learning.tryLock()) {
            try o.put(a, "pending", .{ .bool = true });
            try o.put(a, "message", .{ .string = "the learner is busy (a night or a lesson): the erased note's neurons are zeroed when it is free, before the next night" });
            return .{ .object = o };
        }
        defer p.srv.teacher.learning.unlock(p.io);
        const z = p.zeroErased(a);
        try o.put(a, "pending", .{ .bool = z.failed != null });
        try o.put(a, "zeroed", try json.intValue(a, z.neurons));
        try o.put(a, "facts", try json.intValue(a, z.facts));
        try o.put(a, "ms", try json.intValue(a, z.ms));
        if (z.failed) |why| try o.put(a, "failed", .{ .string = why });
        return .{ .object = o };
    }

    /// What zeroing erased facts did; `failed`: not durably done, tried again before the next night and at a start.
    const Zeroed = struct { neurons: usize = 0, facts: usize = 0, ms: i64 = 0, failed: ?[]const u8 = null };

    /// Tests only: a state write or publish that fails.
    pub var fail_persist: bool = false;
    pub var fail_publish: bool = false;

    /// Pocket facts whose notes are erased: zeroed and saved first, then the state lets go (zeroing twice is a no-op).
    fn zeroErased(p: *Promoter, a: Allocator) Zeroed {
        var out: Zeroed = .{};
        const t0 = clockMs(p.io);
        const s = &p.state;
        const listed = ops.list(p.store, a, true) catch return .{ .failed = "out of memory listing the notes" };
        var held: std.StringHashMapUnmanaged(void) = .empty;
        for (listed) |v| held.put(a, keyOf(a, v) catch return .{ .failed = "out of memory" }, {}) catch return .{ .failed = "out of memory" };
        var gone: std.ArrayList(promote.Neuron) = .empty;
        var targets: std.ArrayList(*promote.Fact) = .empty;
        for (s.facts.items) |*f| if (promote.active(f.status) and !held.contains(f.key)) {
            gone.appendSlice(a, f.neurons) catch return .{ .failed = "out of memory" };
            targets.append(a, f) catch return .{ .failed = "out of memory" };
        };
        if (targets.items.len == 0) return out;
        out.facts = targets.items.len;
        out.neurons = gone.items.len;
        if (gone.items.len > 0 and !slide.retire(p.srv, a, gone.items)) {
            out.failed = "the learner refused to zero the neurons: they stay recorded and are zeroed at the next try";
            log.line("notes promotion: {s}", .{out.failed.?});
            return out;
        }
        // zeroed and saved in the model's files: now the state lets them go
        var left: std.ArrayList(promote.Neuron) = .empty;
        for (s.pocket) |n| if (!promote.has(gone.items, n)) left.append(s.alloc(), n) catch return .{ .failed = "out of memory" };
        for (targets.items) |f| {
            f.status = .freed;
            f.why = "erased: the note is gone and its neurons were zeroed";
            f.neurons = &.{};
            f.probes = &.{};
            f.alone = 0;
        }
        s.pocket = left.items;
        var b: Backend = .{ .p = p };
        if (fail_persist) {
            out.failed = "the neurons are zeroed in the model's files but the state file was not written: the next try writes it";
        } else b.persist(s) catch {
            out.failed = "the neurons are zeroed in the model's files but the state file was not written: the next try writes it";
        };
        if (out.failed == null) {
            if (fail_publish) {
                out.failed = "the state is written but the in-weights list was not refreshed: the next try refreshes it";
            } else p.publish() catch {
                out.failed = "the state is written but the in-weights list was not refreshed: the next try refreshes it";
            };
        }
        if (out.failed != null) {
            // not durable: the state on file, still holding these facts, comes back for the next try
            p.reload();
            log.line("notes promotion: {s}", .{out.failed.?});
        }
        out.ms = clockMs(p.io) - t0;
        if (out.failed == null) log.line("notes promotion: an erase zeroed {d} neurons of {d} facts in {d} ms", .{ out.neurons, out.facts, out.ms });
        return out;
    }

    /// Erases not yet in the pocket, applied now (the learner's lock held): after a night, before one, at a start.
    pub fn drainPending(p: *Promoter) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        _ = p.zeroErased(arena.allocator());
    }

    /// The state read back from its own bytes: one night's allocations go, the facts stay.
    fn compact(p: *Promoter) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const bytes = pjson.encode(&p.state, arena.allocator()) catch return;
        const fresh = pjson.decode(p.gpa, bytes, p.state.settings) catch return;
        p.state.deinit();
        p.state = fresh;
    }

    fn reload(p: *Promoter) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(p.io, p.path, p.gpa, .limited(256 << 20)) catch return;
        defer p.gpa.free(bytes);
        const back = pjson.decode(p.gpa, bytes, p.state.settings) catch return;
        p.state.deinit();
        p.state = back;
        p.publish() catch {};
    }

    /// GET /v1/promotion: the state as last written, and whether a night runs; POST: a night now.
    pub fn handle(p: *Promoter, conn: *Conn, a: Allocator) void {
        if (std.mem.eql(u8, conn.method, "POST")) {
            _ = http_body.read(conn, a, http_body.limit) catch {};
            if (p.running.load(.acquire)) return conn.sendJson(409, "{\"error\": {\"message\": \"a night is running\"}}");
            p.wake.store(true, .release);
            return conn.sendJson(202, "{\"started\": true}");
        }
        p.mu.lockUncancelable(p.io);
        const body = std.fmt.allocPrint(a, "{{\"running\": {s}, \"every_s\": {d}, \"state\": {s}}}", .{ if (p.running.load(.acquire)) "true" else "false", @divTrunc(p.every_ms, 1000), p.report }) catch {
            p.mu.unlock(p.io);
            return;
        };
        p.mu.unlock(p.io);
        conn.sendJson(200, body);
    }
};

fn clockMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_ms));
}

/// The night's learner, notes and questions: the server's own (slide.teachText, slide_ask, the store's lookup).
const Backend = struct {
    p: *Promoter,

    fn srv(b: *Backend) *Server {
        return b.p.srv;
    }
    fn stopper(b: *Backend) Stop {
        return .{ .flag = &b.p.stop };
    }

    /// After a stop mid-teach: the neurons of a learned graph fact with the text being taught join the pocket.
    fn recover(b: *Backend, a: Allocator) !void {
        const s = &b.p.state;
        const op = s.open orelse return;
        if (op.teaching.len == 0) return;
        const graph = try b.srv().slide.learnedChat(a, 0, std.math.maxInt(usize));
        var all: std.ArrayList(promote.Neuron) = .empty;
        try all.appendSlice(s.alloc(), s.pocket);
        for (graph) |g| if (std.mem.eql(u8, g.text, op.teaching)) for (g.neurons) |n| if (!promote.has(all.items, n)) try all.append(s.alloc(), n);
        s.pocket = all.items;
        s.open.?.teaching = "";
    }

    pub fn notes(b: *Backend, a: Allocator) ![]promote.Note {
        const list = try ops.list(b.p.store, a, false);
        const out = try a.alloc(promote.Note, list.len);
        for (list, out) |v, *n| n.* = .{ .id = v.id, .key = try keyOf(a, v), .text = v.text, .told = v.told, .fact = v.kind == .fact };
        return out;
    }
    pub fn firstSeen(b: *Backend, key: []const u8) ?u32 {
        b.p.mu.lockUncancelable(b.p.io);
        defer b.p.mu.unlock(b.p.io);
        return b.p.seen.get(key);
    }
    pub fn wasRetrieved(b: *Backend, key: []const u8) bool {
        b.p.mu.lockUncancelable(b.p.io);
        defer b.p.mu.unlock(b.p.io);
        return b.p.retrieved.contains(key);
    }
    pub fn nowMs(b: *Backend) i64 {
        return clockMs(b.p.io);
    }

    /// The fact's text through the learn route's own code; a text that splits into facts not all kept keeps none.
    pub fn teach(b: *Backend, a: Allocator, text: []const u8) !promote.Taught {
        if (b.p.stop.load(.acquire)) return error.Stopped;
        var out: slide.Out = .{ .conn = null, .a = a };
        slide.teachText(b.srv(), a, text, "chat", b.stopper(), &out);
        if (b.p.stop.load(.acquire)) return error.Stopped;
        if (out.results.items.len == 0) return .{ .kept = false, .why = "missed: the learner found no fact in its text" };
        const graph = try b.srv().slide.learnedChat(a, 0, std.math.maxInt(usize));
        var neurons: std.ArrayList(promote.Neuron) = .empty;
        var qs: std.ArrayList([]const u8) = .empty;
        var all = true;
        for (out.results.items) |r| {
            all = all and r.recalled;
            if (!r.recalled) continue;
            for (graph) |g| if (g.id == r.id) {
                try neurons.appendSlice(a, g.neurons);
                try qs.appendSlice(a, g.questions);
            };
        }
        if (!all) {
            if (neurons.items.len > 0 and !slide.retire(b.srv(), a, neurons.items)) return error.RetireRefused;
            return .{ .kept = false, .why = "missed: the learner did not keep every fact of its text; it stays a note" };
        }
        return .{ .kept = true, .neurons = neurons.items, .questions = qs.items };
    }

    pub fn retire(b: *Backend, a: Allocator, ns: []const promote.Neuron) !void {
        if (!slide.retire(b.srv(), a, ns)) return error.RetireRefused;
    }

    /// Each question answered by the untaught model with the fact before it, as a lesson writes its answers.
    pub fn references(b: *Backend, a: Allocator, fact: []const u8, qs: []const []const u8) ![]const []const u8 {
        const note = try std.fmt.allocPrint(a, prompts.told_note, .{fact});
        const out = try a.alloc([]const u8, qs.len);
        const Job = struct {
            b: *Backend,
            a: Allocator,
            note: []const u8,
            qs: []const []const u8,
            out: [][]const u8,
            pub fn run(j: *const @This(), i: usize) !void {
                var cx: errors.Cx = .{ .a = j.a };
                j.out[i] = (try slide_ask.askBase(j.b.srv(), &cx, j.note, j.qs[i], answer_tokens, j.b.stopper())).content;
            }
        };
        try side.each(qs.len, &Job{ .b = b, .a = a, .note = note, .qs = qs, .out = out });
        return out;
    }

    /// Each question as production asks it: the store's block for it (these notes left out) first, on the live weights.
    pub fn askAll(b: *Backend, a: Allocator, asks: []const promote.Ask) ![]const []const u8 {
        const out = try a.alloc([]const u8, asks.len);
        const Job = struct {
            b: *Backend,
            a: Allocator,
            asks: []const promote.Ask,
            out: [][]const u8,
            pub fn run(j: *const @This(), i: usize) !void {
                var cx: errors.Cx = .{ .a = j.a };
                const s = j.b.srv();
                const q = j.asks[i];
                var block: ?[]const u8 = null;
                if (q.exclude) |ex| {
                    const qids = s.text.encode(j.a, q.q, false) catch return error.Tokenizer;
                    const st = j.b.p.store;
                    const found = try st.retrieve(j.a, s.text, qids, past_mod.isPast(q.q), st.settings().cap, ex);
                    if (found.block.len > 0) block = found.block;
                }
                j.out[i] = (try slide_ask.ask(s, &cx, block, q.q, answer_tokens, j.b.stopper())).content;
            }
        };
        try side.each(asks.len, &Job{ .b = b, .a = a, .asks = asks, .out = out });
        return out;
    }

    /// The question the note answers, as its user would ask it, written by the untaught model ("" when it gives none).
    pub fn questionOf(b: *Backend, a: Allocator, fact: []const u8) ![]const u8 {
        var cx: errors.Cx = .{ .a = a };
        const ask = try std.fmt.allocPrint(a, question_prompt, .{fact});
        const r = try slide_ask.askBase(b.srv(), &cx, null, ask, 32, b.stopper());
        const q = std.mem.trim(u8, r.content, " \t\r\n\"*");
        return if (q.len > 0 and q.len < 200 and q[q.len - 1] == '?' and std.mem.indexOfScalar(u8, q, '\n') == null) q else "";
    }

    pub fn agrees(_: *Backend, fact: []const u8, question: []const u8, ref: []const u8, reply: []const u8) bool {
        return wording.recalls(fact, question, ref, reply);
    }

    /// Whether a control's changed reply still says nothing new, as the learner's own judge decides.
    pub fn same(b: *Backend, a: Allocator, question: []const u8, before: []const u8, reply: []const u8) !bool {
        var cx: errors.Cx = .{ .a = a };
        const v = try slide_ask.askBase(b.srv(), &cx, null, try std.fmt.allocPrint(a, prompts.same_prompt, .{ question, before, reply }), 4, b.stopper());
        return std.ascii.startsWithIgnoreCase(std.mem.trim(u8, v.content, " \t\r\n\"*"), "no");
    }

    pub fn persist(b: *Backend, s: *const promote.State) !void {
        var arena: std.heap.ArenaAllocator = .init(b.p.gpa);
        defer arena.deinit();
        try pjson.writeFile(arena.allocator(), b.p.path, try pjson.encode(s, arena.allocator()));
    }
};
