//! Vendored from LLWZ notes-zig a81d1a9 (zig/notes/src/notes.zig; MIT, (c) 2026 ThinkOff): a note snapshot's index.
const std = @import("std");
const builtin = @import("builtin");
const json = @import("../json.zig");
const Value = json.Value;
const Allocator = std.mem.Allocator;

/// A log function, called through a pointer.
pub const LogFn = *const fn (f64) callconv(.c) f64;

fn zigLog(x: f64) callconv(.c) f64 {
    return @log(x);
}

/// The C library's log (CPython's math.log calls it), found by name: Zig's own differs in the last bit for some inputs.
pub fn libmLog() LogFn {
    // RTLD_DEFAULT: the handle that searches every loaded image (-2 on Apple systems, 0 elsewhere)
    const default: ?*anyopaque = if (builtin.os.tag.isDarwin()) @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))) else null;
    if (std.c.dlsym(default, "log")) |p| return @ptrCast(@alignCast(p));
    return &zigLog;
}

pub fn isZigLog(f: LogFn) bool {
    return f == &zigLog;
}

/// A key that is the token id itself has this bit; a fold string's key is its place in the interned list.
pub const key_id: u32 = 0x8000_0000;
/// No key: an unused place in a packed n-gram, and the key of a token id the vocabulary lacks (it matches nothing).
pub const none_key: u32 = 0xFFFF_FFFF;
/// N-grams are packed into one u128, four keys of 32 bits, so n_max is at most 4.
pub const max_n = 4;
/// subjects() looks for entity phrases of 2 to 8 keys.
pub const max_phrase = 8;
pub const no_note: u32 = 0xFFFF_FFFF;

pub const State = enum(u8) { current = 0, superseded = 1, tombstoned = 2 };
pub const Hop = enum { subject, subject_value, none };

pub const Settings = struct {
    cap: u32,
    n_min: u32,
    n_max: u32,
    fold: bool,
    hop: Hop,
    hop_weight: f64,
    hop_from: u32,
    hop_history: bool,
    min_rel: f64,
    subject: f64,
    punct: bool,
};

pub const LoadError = error{ BadSnapshot, Unsupported } || Allocator.Error;

pub const Gram = u128;

/// Keys packed into one u128; the unused places hold none_key, so (a, b) and (a, b, c) never meet.
pub fn packGram(keys: []const u32) Gram {
    var g: Gram = 0;
    var j: usize = 0;
    while (j < max_n) : (j += 1) {
        const k: u32 = if (j < keys.len) keys[j] else none_key;
        g |= @as(Gram, k) << @intCast(32 * j);
    }
    return g;
}

pub const GramCtx = struct {
    pub fn hash(_: GramCtx, g: Gram) u64 {
        const lo: u64 = @truncate(g);
        const hi: u64 = @truncate(g >> 64);
        const m = @as(u128, lo ^ 0xa076_1d64_78bd_642f) *% @as(u128, hi ^ 0xe703_7ed1_a0b4_28db);
        return @as(u64, @truncate(m)) ^ @as(u64, @truncate(m >> 64));
    }
    pub fn eql(_: GramCtx, a: Gram, b: Gram) bool {
        return a == b;
    }
};

pub const Phrase = [max_phrase]u32;
pub const PhraseCtx = struct {
    pub fn hash(_: PhraseCtx, p: Phrase) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&p));
    }
    pub fn eql(_: PhraseCtx, a: Phrase, b: Phrase) bool {
        return std.mem.eql(u32, &a, &b);
    }
};

pub fn packPhrase(keys: []const u32) Phrase {
    var p: Phrase = @splat(none_key);
    @memcpy(p[0..keys.len], keys);
    return p;
}

/// Postings of one n-gram: note places in the current view, then in the history view.
pub const Post = struct { cur_off: u32, cur_len: u32, hist_off: u32, hist_len: u32 };

/// One note as the snapshot gives it.
const Raw = struct { id: u32, state: State, entity: u32, pair: u32, value_ent: i32, told: i64, line: []const u8, cost: u32, tokens: []const u32 };

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    log: LogFn,
    settings: Settings,
    head: []const u8,
    cur_title: []const u8,
    hist_title: []const u8,
    fx_head: u32,
    fx_cur: u32,
    fx_hist: u32,
    fx_nl: u32,
    vkey: []const u32,
    vwordy: []const bool,
    /// The tokenizer.json SHA-256 the snapshot was exported with ("" when it names none).
    tokenizer_sha256: []const u8,
    // the notes, by place (0..notes-1); ids are Python's note ids
    note_id: []const u32,
    state: []const State,
    told: []const i64,
    trank: []const u32, // place in the order (-told, id): Python's tie-break after the score
    entity: []const u32,
    pair: []const u32,
    value_ent: []const i32,
    line: []const []const u8,
    cost: []const u32,
    min_line: i64, // the least any line can add in pack(): its cost and a line break
    id_place: []const u32, // a note id -> its place, or no_note
    ent_cur: []const []const u32, // entity -> places of its current notes (O.ent_cur)
    ent_keys: []const []const u32, // entity -> its pairs (O.ent_keys)
    pair_notes: []const []const u32, // pair -> places of its notes, every state, oldest first (O.by_key)
    grams: std.HashMapUnmanaged(Gram, Post, GramCtx, 80),
    post: []const u32,
    phrases: std.HashMapUnmanaged(Phrase, u32, PhraseCtx, 80),
    phrase_max: usize,
    n_cur: u32,
    n_hist: u32,

    pub fn notes(self: *const Index) usize {
        return self.note_id.len;
    }

    /// A note id's place in the index, if the snapshot has that note.
    pub fn placeOfId(self: *const Index, id: u32) ?u32 {
        if (id >= self.id_place.len or self.id_place[id] == no_note) return null;
        return self.id_place[id];
    }

    pub fn deinit(self: *Index) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Reads a snapshot (notes_export.py's JSON) and builds the index, checking notes and distinct n-grams per view.
    pub fn load(gpa: Allocator, text: []const u8) LoadError!*Index {
        var parse_arena = std.heap.ArenaAllocator.init(gpa);
        defer parse_arena.deinit();
        const s = switch (try json.parse(parse_arena.allocator(), text)) {
            .ok => |v| v,
            .err => return error.BadSnapshot,
        };
        if (!std.mem.eql(u8, try str(s, "format"), "lw-notes-snapshot/1")) return error.BadSnapshot;
        const vocab = try need(s, "vocab");
        if (vocab.get("dense")) |d| if (d.truthy()) return error.Unsupported; // a stand-in tokenizer's own numbering

        const self = try gpa.create(Index);
        errdefer gpa.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.log = libmLog();
        try self.readSettings(try need(s, "settings"));
        self.head = try a.dupe(u8, try str(s, "head"));
        self.cur_title = try a.dupe(u8, try str(s, "cur_title"));
        self.hist_title = try a.dupe(u8, try str(s, "hist_title"));
        const fixed = try need(s, "fixed");
        self.fx_head = try uint(fixed, "head");
        self.fx_cur = try uint(fixed, "current");
        self.fx_hist = try uint(fixed, "history");
        self.fx_nl = try uint(fixed, "nl");
        const tok = s.get("tokenizer");
        self.tokenizer_sha256 = try a.dupe(u8, if (tok) |t| t.strField("sha256") orelse "" else "");

        // the vocabulary: every token id's key and wordy flag
        const size = try uint(vocab, "size");
        const vk = try arr(vocab, "key");
        const vw_text = try str(vocab, "wordy");
        if (vk.len != size or vw_text.len != size) return error.BadSnapshot;
        const vkey = try a.alloc(u32, size);
        for (vk, vkey) |k, *slot| slot.* = try asU32(k);
        self.vkey = vkey;
        const vw = try a.alloc(bool, size);
        for (vw_text, vw) |c, *slot| slot.* = c == '1';
        self.vwordy = vw;

        const entities = try arr(s, "entities");
        const pairs = try arr(s, "pairs");
        const raw = try readNotes(parse_arena.allocator(), try arr(s, "notes"), entities.len, pairs.len);
        try self.placeNotes(gpa, raw, try need(s, "n"));
        try self.readGroups(entities, pairs);
        self.phrases = .empty;
        self.phrase_max = 0;
        try self.readPhrases(try arr(s, "phrases"), entities.len);
        try self.buildPostings(gpa, raw);
        var gc: u32 = 0;
        var gh: u32 = 0;
        var it = self.grams.valueIterator();
        while (it.next()) |p| {
            if (p.cur_len > 0) gc += 1;
            if (p.hist_len > 0) gh += 1;
        }
        const grams = try need(s, "grams");
        if (gc != try uint(grams, "current") or gh != try uint(grams, "history")) return error.BadSnapshot;
        return self;
    }

    fn readSettings(self: *Index, js: Value) LoadError!void {
        const n_min = try uint(js, "n_min");
        const n_max = try uint(js, "n_max");
        if (n_min < 1 or n_min > n_max) return error.BadSnapshot;
        if (n_max > max_n) return error.Unsupported;
        const hop = try str(js, "hop");
        self.settings = .{
            .cap = try uint(js, "cap"),
            .n_min = n_min,
            .n_max = n_max,
            .fold = try boolean(js, "fold"),
            .hop = if (std.mem.eql(u8, hop, "subject")) .subject else if (std.mem.eql(u8, hop, "subject+value"))
                .subject_value
            else if (std.mem.eql(u8, hop, "none")) .none else return error.BadSnapshot,
            .hop_weight = try num(js, "hop_weight"),
            .hop_from = try uint(js, "hop_from"),
            .hop_history = try boolean(js, "hop_history"),
            .min_rel = try num(js, "min_rel"),
            .subject = try num(js, "subject"),
            .punct = try boolean(js, "punct"),
        };
    }

    /// The notes by place, with Python's tie order (-told, id) and the least a line can add.
    fn placeNotes(self: *Index, gpa: Allocator, raw: []const Raw, counts: Value) LoadError!void {
        const a = self.arena.allocator();
        const n = raw.len;
        const note_id = try a.alloc(u32, n);
        const state = try a.alloc(State, n);
        const told = try a.alloc(i64, n);
        const entity = try a.alloc(u32, n);
        const pair = try a.alloc(u32, n);
        const value_ent = try a.alloc(i32, n);
        const line = try a.alloc([]const u8, n);
        const cost = try a.alloc(u32, n);
        var max_id: u32 = 0;
        for (raw) |x| max_id = @max(max_id, x.id);
        const id_place = try a.alloc(u32, @as(usize, max_id) + 1);
        @memset(id_place, no_note);
        var n_cur: u32 = 0;
        var n_hist: u32 = 0;
        for (raw, 0..) |x, k| {
            if (id_place[x.id] != no_note) return error.BadSnapshot;
            id_place[x.id] = @intCast(k);
            note_id[k] = x.id;
            state[k] = x.state;
            if (x.state == .current) n_cur += 1 else n_hist += 1;
            told[k] = x.told;
            entity[k] = x.entity;
            pair[k] = x.pair;
            value_ent[k] = x.value_ent;
            line[k] = try a.dupe(u8, x.line);
            cost[k] = x.cost;
        }
        if (n_cur != try uint(counts, "current") or n_hist != try uint(counts, "history")) return error.BadSnapshot;
        const by = try gpa.alloc(u32, n);
        defer gpa.free(by);
        for (by, 0..) |*x, k| x.* = @intCast(k);
        const TieOrder = struct {
            told: []const i64,
            id: []const u32,
            fn less(c: @This(), x: u32, y: u32) bool {
                if (c.told[x] != c.told[y]) return c.told[x] > c.told[y];
                return c.id[x] < c.id[y];
            }
        };
        std.sort.pdq(u32, by, TieOrder{ .told = told, .id = note_id }, TieOrder.less);
        const trank = try a.alloc(u32, n);
        for (by, 0..) |x, r| trank[x] = @intCast(r);
        self.note_id = note_id;
        self.state = state;
        self.told = told;
        self.trank = trank;
        self.entity = entity;
        self.pair = pair;
        self.value_ent = value_ent;
        self.line = line;
        self.cost = cost;
        var least: i64 = std.math.maxInt(i64);
        for (cost) |c| least = @min(least, @as(i64, c) + self.fx_nl);
        self.min_line = least;
        self.id_place = id_place;
        self.n_cur = n_cur;
        self.n_hist = n_hist;
    }

    /// O.ent_cur, O.ent_keys and O.by_key, as note places.
    fn readGroups(self: *Index, entities: []const Value, pairs: []const Value) LoadError!void {
        const a = self.arena.allocator();
        const ent_cur = try a.alloc([]const u32, entities.len);
        const ent_keys = try a.alloc([]const u32, entities.len);
        for (entities, 0..) |e, k| {
            ent_cur[k] = try self.places(try arr(e, "cur"));
            const keys = try u32s(a, try arr(e, "keys"));
            for (keys) |p| if (p >= pairs.len) return error.BadSnapshot;
            ent_keys[k] = keys;
        }
        const pair_notes = try a.alloc([]const u32, pairs.len);
        for (pairs, 0..) |p, k| pair_notes[k] = try self.places(try arr(p, "ids"));
        self.ent_cur = ent_cur;
        self.ent_keys = ent_keys;
        self.pair_notes = pair_notes;
    }

    fn places(self: *Index, ids: []const Value) LoadError![]const u32 {
        const out = try self.arena.allocator().alloc(u32, ids.len);
        for (ids, out) |v, *slot| slot.* = self.placeOfId(try asU32(v)) orelse return error.BadSnapshot;
        return out;
    }

    /// Entity phrases: only 2 to 8 keys can ever match (subjects() looks at those lengths).
    fn readPhrases(self: *Index, phrases: []const Value, n_entities: usize) LoadError!void {
        const a = self.arena.allocator();
        var keys: [max_phrase]u32 = undefined;
        for (phrases) |p| {
            const entity = try uint(p, "entity");
            if (entity >= n_entities) return error.BadSnapshot;
            const ks = try arr(p, "keys");
            if (ks.len < 2 or ks.len > max_phrase) continue;
            for (ks, 0..) |k, j| keys[j] = try asU32(k);
            try self.phrases.put(a, packPhrase(keys[0..ks.len]), entity);
            self.phrase_max = @max(self.phrase_max, ks.len);
        }
    }

    /// The postings of both views, from each note's token ids by the same grams() as a question's.
    fn buildPostings(self: *Index, gpa: Allocator, raw: []const Raw) LoadError!void {
        const a = self.arena.allocator();
        const Hit = struct { entry: u32, note: u32 };
        var hits: std.ArrayList(Hit) = .empty;
        defer hits.deinit(gpa);
        var keys: std.ArrayList(u32) = .empty;
        defer keys.deinit(gpa);
        var gl: std.ArrayList(Gram) = .empty;
        defer gl.deinit(gpa);
        var entries: std.ArrayList(Post) = .empty; // counts first, then offsets
        defer entries.deinit(gpa);
        var map: std.HashMapUnmanaged(Gram, u32, GramCtx, 80) = .empty;
        defer map.deinit(gpa);
        for (raw, 0..) |x, k| {
            keys.clearRetainingCapacity();
            for (x.tokens) |t| try keys.append(gpa, self.keyOf(t));
            gl.clearRetainingCapacity();
            try self.gramsOf(gpa, x.tokens, keys.items, &gl);
            for (gl.items) |g| {
                const r = try map.getOrPut(gpa, g);
                if (!r.found_existing) {
                    r.value_ptr.* = @intCast(entries.items.len);
                    try entries.append(gpa, .{ .cur_off = 0, .cur_len = 0, .hist_off = 0, .hist_len = 0 });
                }
                const e = &entries.items[r.value_ptr.*];
                if (self.state[k] == .current) e.cur_len += 1 else e.hist_len += 1;
                try hits.append(gpa, .{ .entry = r.value_ptr.*, .note = @intCast(k) });
            }
        }
        var off: u32 = 0;
        for (entries.items) |*e| {
            e.cur_off = off;
            off += e.cur_len;
            e.hist_off = off;
            off += e.hist_len;
        }
        const post = try a.alloc(u32, off);
        const fill = try gpa.alloc(u32, entries.items.len * 2);
        defer gpa.free(fill);
        @memset(fill, 0);
        for (hits.items) |h| {
            const e = entries.items[h.entry];
            if (self.state[h.note] == .current) {
                post[e.cur_off + fill[2 * h.entry]] = h.note;
                fill[2 * h.entry] += 1;
            } else {
                post[e.hist_off + fill[2 * h.entry + 1]] = h.note;
                fill[2 * h.entry + 1] += 1;
            }
        }
        self.post = post;
        self.grams = .empty;
        try self.grams.ensureTotalCapacity(a, @intCast(entries.items.len));
        var it = map.iterator();
        while (it.next()) |kv| self.grams.putAssumeCapacity(kv.key_ptr.*, entries.items[kv.value_ptr.*]);
    }

    pub inline fn keyOf(self: *const Index, t: u32) u32 {
        return if (t < self.vkey.len) self.vkey[t] else none_key;
    }

    inline fn wordyOf(self: *const Index, t: u32) bool {
        return t < self.vwordy.len and self.vwordy[t];
    }

    /// NoteStore.grams: n from n_min to n_max at every start, distinct, in the order first met (Python keeps a set).
    pub fn gramsOf(self: *const Index, gpa: Allocator, ids: []const u32, keys: []const u32, out: *std.ArrayList(Gram)) Allocator.Error!void {
        const st = self.settings;
        var n: usize = st.n_min;
        while (n <= st.n_max) : (n += 1) {
            if (keys.len < n) break;
            var j: usize = 0;
            while (j + n <= keys.len) : (j += 1) {
                if (n == 1 and !st.punct and !self.wordyOf(ids[j])) continue; // punctuation alone is no key
                const g = packGram(keys[j..][0..n]);
                if (std.mem.indexOfScalar(Gram, out.items, g) == null) try out.append(gpa, g);
            }
        }
    }
};

/// The snapshot's notes, checked against its entity and pair counts.
fn readNotes(a: Allocator, list: []const Value, n_entities: usize, n_pairs: usize) LoadError![]Raw {
    const out = try a.alloc(Raw, list.len);
    for (list, out) |x, *r| {
        const st = try uint(x, "state");
        const entity = try uint(x, "entity");
        const pair = try uint(x, "pair");
        const value_ent = try int(x, "value_ent");
        if (entity >= n_entities or pair >= n_pairs or value_ent < -1 or value_ent >= @as(i64, @intCast(n_entities))) return error.BadSnapshot;
        r.* = .{
            .id = try uint(x, "id"),
            .state = std.enums.fromInt(State, st) orelse return error.BadSnapshot,
            .entity = entity,
            .pair = pair,
            .value_ent = @intCast(value_ent),
            .told = try int(x, "told"),
            .line = try str(x, "line"),
            .cost = try uint(x, "cost"),
            .tokens = try u32s(a, try arr(x, "tokens")),
        };
    }
    return out;
}

fn need(v: Value, key: []const u8) LoadError!Value {
    return v.get(key) orelse error.BadSnapshot;
}

fn int(v: Value, key: []const u8) LoadError!i64 {
    return (try need(v, key)).int64() orelse error.BadSnapshot;
}

fn asU32(v: Value) LoadError!u32 {
    const x = v.int64() orelse return error.BadSnapshot;
    return std.math.cast(u32, x) orelse error.BadSnapshot;
}

fn uint(v: Value, key: []const u8) LoadError!u32 {
    return asU32(try need(v, key));
}

fn num(v: Value, key: []const u8) LoadError!f64 {
    const x = try need(v, key);
    if (x == .bool) return error.BadSnapshot;
    return x.float64() orelse error.BadSnapshot;
}

fn boolean(v: Value, key: []const u8) LoadError!bool {
    const x = try need(v, key);
    return if (x == .bool) x.bool else error.BadSnapshot;
}

fn str(v: Value, key: []const u8) LoadError![]const u8 {
    return (try need(v, key)).str() orelse error.BadSnapshot;
}

fn arr(v: Value, key: []const u8) LoadError![]Value {
    return (try need(v, key)).items() orelse error.BadSnapshot;
}

fn u32s(a: Allocator, list: []const Value) LoadError![]u32 {
    const out = try a.alloc(u32, list.len);
    for (list, out) |v, *slot| slot.* = try asU32(v);
    return out;
}

/// Reads a snapshot file and loads it.
pub fn loadFile(gpa: Allocator, io: std.Io, path: []const u8) !*Index {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(text);
    return Index.load(gpa, text);
}

test "packGram keeps lengths apart" {
    const a = packGram(&.{ 1, 2 });
    const b = packGram(&.{ 1, 2, none_key });
    const c = packGram(&.{ 1, 2, 3 });
    try std.testing.expect(a == b); // none_key is never a real key, so this pair cannot occur in a snapshot
    try std.testing.expect(a != c);
    try std.testing.expect(packGram(&.{1}) != packGram(&.{ 1, 0 }));
}
