//! --notes-promote-every: nightly promotion in the server: its thread, the chat lookup's hooks, and /v1/promotion.
const std = @import("std");
const api = @import("engine_api");
const json = @import("json.zig");
const log = @import("log.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const ops = @import("notes_ops.zig");
const notes_route = @import("notes_route.zig");
const slide = @import("slide.zig");
const wording = @import("slide_words.zig");
const routes = @import("routes.zig");
const http_body = @import("http_body.zig");
const Server = @import("server.zig").Server;
const Conn = @import("http_conn.zig").Conn;
const Store = notes_route.Store;
const Value = json.Value;
const Allocator = std.mem.Allocator;

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

pub const agreesWith = @import("notes/promote_judge.zig").agreesWith;

/// The night's learner, notes and questions (notes_promote_backend.zig).
const Backend = @import("notes_promote_backend.zig").Backend;

/// Tokens a night's question is answered in at most (the learner's own checks read 48).
pub const answer_tokens = @import("notes_promote_backend.zig").answer_tokens;

/// A note's promotion key: its write's source, or "s<id>" for a snapshot's note.
pub fn keyOf(a: Allocator, v: ops.View) Allocator.Error![]const u8 {
    return if (v.source) |s| a.dupe(u8, s) else std.fmt.allocPrint(a, "s{d}", .{v.id});
}

/// A night's stop check for the learner and the chat calls: true once the server stops.
pub const Stop = struct {
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
    publish_pending: bool = false, // the in-weights list and report lag the state: refreshed at the next try

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
        p.repairProbes();
        _ = p.tryPublish(); // a failure leaves it marked: the start's first step refreshes it
        return p;
    }

    /// Stored probes whose reference does not give its fact (or a degenerate wording): dropped once, logged.
    fn repairProbes(p: *Promoter) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        var b: Backend = .{ .p = p, .arena = arena.allocator() };
        const n = promote.repair(&p.state, arena.allocator(), &b) catch return; // memory short: the next start tries again
        if (n == 0) return;
        log.line("notes promotion: {d} stored probes dropped on load (each logged above and in {s}-probes.jsonl)", .{ n, p.path });
        b.persist(&p.state) catch log.line("notes promotion: the repaired state was not written; the next start repairs it again", .{});
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

    /// publish(), its failure kept in `publish_pending` (every caller goes through here, the test switch too).
    pub fn tryPublish(p: *Promoter) bool {
        const ok = if (fail_publish) false else if (p.publish()) |_| true else |_| false;
        p.publish_pending = !ok;
        return ok;
    }

    /// Report and in-weights keys staged whole, swapped in with the generation bump; a failure changes nothing.
    fn publish(p: *Promoter) !void {
        const g = p.gpa;
        var arena: std.heap.ArenaAllocator = .init(g);
        defer arena.deinit();
        const bytes = try g.dupe(u8, try pjson.encode(&p.state, arena.allocator()));
        errdefer g.free(bytes);
        const keys = try p.state.inWeights(arena.allocator());
        var staged: std.ArrayList([]u8) = .empty;
        errdefer {
            for (staged.items) |k| g.free(k);
            staged.deinit(g);
        }
        try staged.ensureTotalCapacityPrecise(g, keys.len);
        for (keys) |k| staged.appendAssumeCapacity(try g.dupe(u8, k));
        p.mu.lockUncancelable(p.io);
        const old_report = p.report;
        var old_weights = p.weights;
        p.report = bytes;
        p.weights = staged;
        p.gen += 1;
        p.nights_done = p.state.nights_done;
        p.mu.unlock(p.io);
        g.free(old_report);
        for (old_weights.items) |k| g.free(k);
        old_weights.deinit(g);
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

    /// One night under the learner's lock; on failure the state is marked to rebuild (nothing is reloaded).
    pub fn runNight(p: *Promoter) void {
        p.running.store(true, .release);
        defer p.running.store(false, .release);
        p.srv.teacher.learning.lockUncancelable(p.io);
        defer p.srv.teacher.learning.unlock(p.io);
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        var b: Backend = .{ .p = p, .arena = arena.allocator() };
        p.drainPending();
        log.line("notes promotion: night {d} begins", .{p.state.nights_done + 1});
        const n = promote.nightOrRebuild(&p.state, arena.allocator(), &b) catch |e| {
            // no reload (it allocates): the state in memory holds every neuron placed and is marked to rebuild
            log.line("notes promotion: night {d} stopped ({s}); the next night zeroes every promotion neuron and teaches again", .{ p.state.nights_done + 1, @errorName(e) });
            b.persist(&p.state) catch {}; // the file already says the night is open, which a start reads as a rebuild
            _ = p.tryPublish();
            return;
        };
        if (n.worse_list.len > 0) log.line("notes promotion: night {d}: worse: {s}", .{ n.night, n.worse_list });
        log.line("notes promotion: night {d}: {d} due, {d} stale, plan {s} ({d} tried, {d} rejected; {d} one by one, {d} blamed), {d} taught ({d} kept, {d} missed), {d} worse of {d} probes; alone {d} of {d} right in {d} rounds, {d} left the prompt, {d} back; {d} in weights, {d} in the pocket; {d} asks in {d:.1} s", .{ n.night, n.due, n.stale, n.plan, n.tries, n.rejected, n.one_by_one, n.blamed, n.taught, n.kept, n.missed, n.worse, n.probes, n.alone_right, n.alone_asked, n.alone_rounds, n.left_prompt, n.back_to_prompt, n.in_weights, n.pocket, n.asks, n.secs });
        p.compact();
        _ = p.tryPublish();
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
        if (targets.items.len == 0) {
            // nothing left to zero, but an in-weights list an earlier try could not refresh is refreshed now
            if (p.publish_pending and !p.tryPublish()) out.failed = "the in-weights list could not be refreshed: the next try refreshes it";
            return out;
        }
        out.facts = targets.items.len;
        out.neurons = gone.items.len;
        if (gone.items.len > 0 and !slide.retire(p.srv, a, gone.items)) {
            out.failed = "the neurons were not zeroed and saved: they stay recorded and are zeroed at the next try";
            log.line("notes promotion: {s}", .{out.failed.?});
            return out;
        }
        // zeroed and saved in the model's files: now the state lets them go, the old values kept to put back
        var left: std.ArrayList(promote.Neuron) = .empty;
        for (s.pocket) |n| if (!promote.has(gone.items, n)) left.append(s.alloc(), n) catch return .{ .failed = "out of memory" };
        var was: std.ArrayList(promote.Fact) = .empty;
        for (targets.items) |f| was.append(a, f.*) catch return .{ .failed = "out of memory" };
        const old_pocket = s.pocket;
        for (targets.items) |f| {
            f.status = .freed;
            f.why = "erased: the note is gone and its neurons were zeroed";
            f.neurons = &.{};
            f.probes = &.{};
            f.alone = 0;
        }
        s.pocket = left.items;
        var b: Backend = .{ .p = p, .arena = a };
        if (fail_persist) {
            out.failed = "the neurons are zeroed in the model's files but the state file was not written: the next try writes it";
        } else b.persist(s) catch {
            out.failed = "the neurons are zeroed in the model's files but the state file was not written: the next try writes it";
        };
        if (out.failed != null) {
            // not durable: the facts and the pocket as the file still has them, put back without allocating
            for (targets.items, was.items) |f, w| f.* = w;
            s.pocket = old_pocket;
            log.line("notes promotion: {s}", .{out.failed.?});
        } else if (!p.tryPublish()) {
            // durable on file; only the in-memory list lags, and it stays marked until a refresh succeeds
            out.failed = "the state is written but the in-weights list was not refreshed: the next try refreshes it";
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

    /// GET /v1/promotion: the state as last written, and whether a night runs; POST: a night now.
    pub fn handle(p: *Promoter, conn: *Conn, a: Allocator) void {
        if (std.mem.eql(u8, conn.method, "POST")) {
            _ = http_body.read(conn, a, http_body.limit) catch {};
            if (p.running.load(.acquire)) return conn.sendJson(409, "{\"error\": {\"message\": \"a night is running\"}}");
            p.wake.store(true, .release);
            return conn.sendJson(202, "{\"started\": true}");
        }
        p.mu.lockUncancelable(p.io);
        const body = std.fmt.allocPrint(a, "{{\"running\": {s}, \"every_s\": {d}, \"state\": {s}}}", .{ if (p.running.load(.acquire)) "true" else "false", @divTrunc(p.every_ms, 1000), if (p.report.len > 0) p.report else "null" }) catch {
            p.mu.unlock(p.io);
            return;
        };
        p.mu.unlock(p.io);
        conn.sendJson(200, body);
    }
};

pub fn clockMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_ms));
}
