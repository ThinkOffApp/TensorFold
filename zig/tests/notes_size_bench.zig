//! notes-size-bench MODEL_DIR REF_DIR SNAPSHOT...: the bytes a loaded --notes store holds, one JSON line per snapshot.
const std = @import("std");
const server = @import("server");
const index = server.notes_index;
const model_mod = server.notes_model;
const Store = server.notes_store.Store;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Passes everything to the C allocator; counts the bytes asked for and the bytes malloc's blocks hold (malloc_size).
const Counter = struct {
    child: Allocator = std.heap.c_allocator,
    live: usize = 0,
    peak: usize = 0,
    held: usize = 0,
    held_peak: usize = 0,
    blocks: usize = 0,

    fn allocator(c: *Counter) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(ctx: *anyopaque) *Counter {
        return @ptrCast(@alignCast(ctx));
    }

    fn move(c: *Counter, old: usize, new: usize, old_held: usize, new_held: usize) void {
        c.live = c.live + new - old;
        c.held = c.held + new_held - old_held;
        c.peak = @max(c.peak, c.live);
        c.held_peak = @max(c.held_peak, c.held);
    }

    fn mallocSize(p: [*]u8) usize {
        return std.c.malloc_size(@ptrCast(p));
    }

    fn alloc(ctx: *anyopaque, len: usize, al: Alignment, ra: usize) ?[*]u8 {
        const c = of(ctx);
        const p = c.child.rawAlloc(len, al, ra) orelse return null;
        c.blocks += 1;
        c.move(0, len, 0, mallocSize(p));
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, al: Alignment, new_len: usize, ra: usize) bool {
        const c = of(ctx);
        if (!c.child.rawResize(m, al, new_len, ra)) return false;
        c.move(m.len, new_len, 0, 0); // in place: the same malloc block
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c = of(ctx);
        const old_held = mallocSize(m.ptr);
        const p = c.child.rawRemap(m, al, new_len, ra) orelse return null;
        c.move(m.len, new_len, old_held, mallocSize(p));
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, al: Alignment, ra: usize) void {
        const c = of(ctx);
        const h = mallocSize(m.ptr);
        c.child.rawFree(m, al, ra);
        c.blocks -= 1;
        c.move(m.len, 0, h, 0);
    }
};

/// An arena's nodes: bytes from its child, headers, and the newest node's tail (an overflowed node's end_index is not).
const ArenaUse = struct { nodes: usize = 0, held: usize = 0, header: usize = 0, cap: usize = 0, newest_tail: usize = 0 };

fn arenaUse(ar: std.heap.ArenaAllocator) ArenaUse {
    var u: ArenaUse = .{};
    for ([_]@TypeOf(ar.state.used_list){ ar.state.used_list, ar.state.free_list }, 0..) |first, list| {
        var it = first;
        while (it) |node| : (it = node.next) {
            const size = @as(usize, @bitCast(node.size)) & ~@as(usize, 1);
            const header = @sizeOf(@TypeOf(node.*));
            if (list == 0 and node == ar.state.used_list.?) u.newest_tail = size - header -| node.end_index;
            u.nodes += 1;
            u.held += size;
            u.header += header;
        }
    }
    u.cap = u.held - u.header;
    return u;
}

/// The bytes of [start, end) in whole pages that are resident (mincore): allocated is not the same as touched.
fn resident(start: usize, end: usize) !usize {
    const page = std.heap.pageSize();
    const lo = std.mem.alignForward(usize, start, page);
    const hi = std.mem.alignBackward(usize, end, page);
    if (hi <= lo) return 0;
    const vec = try std.heap.c_allocator.alloc(u8, (hi - lo) / page);
    defer std.heap.c_allocator.free(vec);
    if (std.c.mincore(@ptrFromInt(lo), hi - lo, vec.ptr) != 0) return error.Mincore;
    var n: usize = 0;
    for (vec) |v| n += @intFromBool(v & 1 != 0);
    return n * page;
}

/// The index's exact arena: what it asked its child for (each allocation's own size), its record list the overhead.
fn exactUse(e: anytype) ArenaUse {
    const header = e.held.capacity * @sizeOf(@TypeOf(e.held.items[0]));
    return .{ .nodes = e.held.items.len, .held = e.bytes(), .header = header, .cap = e.bytes() - header, .newest_tail = 0 };
}

/// The newest node's unused tail as an address range.
fn newestTail(ar: std.heap.ArenaAllocator) [2]usize {
    const node = ar.state.used_list orelse return .{ 0, 0 };
    const size = @as(usize, @bitCast(node.size)) & ~@as(usize, 1);
    const base = @intFromPtr(node);
    return .{ base + @sizeOf(@TypeOf(node.*)) + node.end_index, base + size };
}

/// The bytes one allocation of a hash map of this capacity takes, measured on a probe map of the same type.
fn mapBytes(comptime M: type, cap: usize) !usize {
    if (cap == 0) return 0;
    var want: u32 = @intCast(cap * 80 / 100);
    while (want > 0) : (want -= 1) {
        var c: Counter = .{};
        var probe: M = .empty;
        try probe.ensureTotalCapacity(c.allocator(), want);
        const got = probe.capacity();
        const bytes = c.live;
        probe.deinit(c.allocator());
        if (got == cap) return bytes;
        if (got < cap) break;
    }
    return error.NoProbe;
}

/// index.zig's Raw (private there): the copy of each note Index.build makes in its arena and never frees.
const RawMirror = struct { id: u32, state: index.State, entity: u32, pair: u32, value_ent: i32, told: i64, line: []const u8, cost: u32, tokens: []const u32 };

const Item = struct { part: []const u8, what: []const u8, bytes: usize, grade: []const u8 };

const Report = struct {
    a: Allocator,
    items: std.ArrayList(Item) = .empty,
    fn add(r: *Report, part: []const u8, what: []const u8, bytes: usize, grade: []const u8) !void {
        try r.items.append(r.a, .{ .part = part, .what = what, .bytes = bytes, .grade = grade });
    }
};

fn groupBytes(g: index.Groups) usize {
    return (g.off.len + g.items.len) * 4;
}

fn sliceBytes(comptime T: type, xs: []const []const T) usize {
    var s: usize = xs.len * @sizeOf([]const T);
    for (xs) |x| s += x.len * @sizeOf(T);
    return s;
}

/// The model's own allocations walked field by field; returns the bytes outside its arena.
fn walkModel(r: *Report, m: *const model_mod.Model) !usize {
    const Note = model_mod.Note;
    var text: usize = 0;
    var line: usize = 0;
    var ids: usize = 0;
    var source: usize = 0;
    for (m.notes.items) |n| {
        text += n.text.len;
        line += n.line.len;
        ids += n.tokens.len;
        if (n.source) |s| source += s.len;
    }
    const recs = m.notes.items.len * @sizeOf(Note);
    const spare = (m.notes.capacity - m.notes.items.len) * @sizeOf(Note);
    try r.add("notes", "model: note records (Note structs)", recs, "measured");
    try r.add("notes", "model: note list spare capacity (ensureTotalCapacity grows by 1.5)", spare, "measured");
    try r.add("notes", "model: note texts", text, "measured");
    try r.add("notes", "model: rendered lines", line, "measured");
    try r.add("notes", "model: token ids (u32)", ids * 4, "measured");
    try r.add("notes", "model: write sources", source, "measured");
    var names: usize = m.entities.capacity * @sizeOf([]u8);
    for (m.entities.items) |e| names += e.len;
    try r.add("entities", "model: entity names", names, "measured");
    var attrs: usize = m.attributes.capacity * @sizeOf([]u8);
    for (m.attributes.items) |x| attrs += x.len;
    try r.add("entities", "model: attribute names", attrs, "measured");
    var pairs: usize = m.pairs.capacity * @sizeOf(model_mod.Pair);
    for (m.pairs.items) |p| pairs += p.ids.capacity * 4;
    try r.add("entities", "model: (entity, attribute) pairs and their note ids", pairs, "measured");
    var phrases: usize = m.phrases.capacity * @sizeOf(model_mod.Phrase);
    for (m.phrases.items) |p| phrases += p.keys.len * 4;
    try r.add("entities", "model: entity phrases (keys)", phrases, "measured");
    try r.add("other", "model: Model struct", @sizeOf(model_mod.Model), "measured");
    return @sizeOf(model_mod.Model) + recs + spare + text + line + ids * 4 + source + names + attrs + pairs + phrases;
}

/// The model's arena: the vocabulary tables and the fixed strings.
fn walkModelArena(r: *Report, m: *const model_mod.Model) !void {
    const u = arenaUse(m.arena);
    const vkey = m.vkey.len * 4;
    const vwordy = m.vwordy.len;
    const strs = m.head.len + m.cur_title.len + m.hist_title.len + m.tokenizer_sha256.len;
    try r.add("vocab", "model arena: token id -> index key (u32 per vocabulary id)", vkey, "measured");
    try r.add("vocab", "model arena: token id -> wordy (bool per vocabulary id)", vwordy, "measured");
    try r.add("other", "model arena: head, titles, tokenizer hash", strs, "measured");
    try r.add("other", "model arena: node headers", u.header, "measured");
    try r.add("other", "model arena: unused node tails and alignment padding", u.cap - vkey - vwordy - strs, "measured");
}

/// The index's arena walked field by field, the pieces it keeps but cannot reach, and the rest (alignment).
fn walkIndex(r: *Report, idx: *const index.Index, m: *const model_mod.Model) !void {
    const n = idx.notes();
    const ne = m.entities.items.len;
    const u = exactUse(idx.arena);
    const cols = n * (@sizeOf(u32) * 5 + @sizeOf(index.State) + @sizeOf(i64) + @sizeOf(i32));
    const lines: usize = n * @sizeOf([]const u8); // slices of the model's lines: the bytes are counted there
    const id_place = idx.id_place.len * 4;
    try r.add("notes", "index: per-note columns (id, state, told, rank, entity, pair, value, cost)", cols, "measured");
    try r.add("notes", "index: rendered lines (slices of the model's)", lines, "measured");
    try r.add("notes", "index: note id -> place", id_place, "measured");
    const grams = try mapBytes(@TypeOf(idx.grams), idx.grams.capacity());
    const post = idx.post.len * 4;
    try r.add("grams", "index: n-gram table (u128 key, 16-byte postings head, 1 control byte; 80% load)", grams, "measured");
    try r.add("grams", "index: postings (u32 note place per n-gram per note)", post, "measured");
    const ent_cur = groupBytes(idx.ent_cur);
    const ent_keys = groupBytes(idx.ent_keys);
    const pair_notes = groupBytes(idx.pair_notes);
    const phrases = try mapBytes(@TypeOf(idx.phrases), idx.phrases.capacity());
    try r.add("entities", "index: entity -> current notes", ent_cur, "measured");
    try r.add("entities", "index: entity -> pairs", ent_keys, "measured");
    try r.add("entities", "index: pair -> notes", pair_notes, "measured");
    try r.add("entities", "index: entity phrase table", phrases, "measured");
    const reach = cols + lines + id_place + grams + post + ent_cur + ent_keys + pair_notes + phrases;
    // the build leaves nothing behind in the arena now (Raw copies, groupsOf's counts, outgrown phrase tables)
    const raw: usize = 0;
    const groups: usize = 0;
    const grown: usize = 0;
    _ = ne;
    try r.add("other", "index: Index struct", @sizeOf(index.Index), "measured");
    try r.add("other", "index arena: its record of each allocation (exact sizes, no nodes)", u.header, "measured");
    const rest = @as(i64, @intCast(u.cap)) - @as(i64, @intCast(reach + raw + groups + grown));
    if (rest < 0) return error.ArenaWalkOver; // a derived piece is wrong: the walk claims more than the arena holds
    if (@as(usize, @intCast(rest)) < u.newest_tail) return error.ArenaTailOver;
    try r.add("other", "index arena: unused tail of its newest node", u.newest_tail, "measured");
    try r.add("other", "index arena: unused tails of earlier nodes and alignment padding (the rest)", @as(usize, @intCast(rest)) - u.newest_tail, "measured");
}

fn sumOf(items: []const Item, part: ?[]const u8) usize {
    var s: usize = 0;
    for (items) |it| if (part == null or std.mem.eql(u8, it.part, part.?)) {
        s += it.bytes;
    };
    return s;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len < 4) {
        std.debug.print("usage: notes-size-bench MODEL_DIR REF_DIR SNAPSHOT...\n", .{});
        return 2;
    }
    var problem: []const u8 = "";
    // the model's tokenizer only (tokenizer.json and its configs), under its own allocator: not counted
    const ht = try server.hf_text.HfText.load(std.heap.c_allocator, io, argv[1], null, a, &problem);
    defer ht.deinit();
    const text = ht.text();
    var out: std.Io.Writer.Allocating = .init(a);
    for (argv[3..]) |path| {
        const journal = try std.mem.concat(a, u8, &.{ path, ".journal" });
        if (std.Io.Dir.cwd().access(io, journal, .{})) |_| {
            std.debug.print("{s} exists: this bench measures a snapshot with no writes since\n", .{journal});
            return 2;
        } else |_| {}
        // 1. first, as the server opens it (tokenizer only, no weights), then the set's questions: a scratch stays
        var cs: Counter = .{};
        const store = Store.open(cs.allocator(), io, path, text, argv[1], &problem) catch |e| {
            std.debug.print("{s}: {s} ({s})\n", .{ path, problem, @errorName(e) });
            return 1;
        };
        defer store.deinit();
        const opened = cs.live;
        const opened_held = cs.held;
        const opened_blocks = cs.blocks;
        const open_peak = cs.peak;
        const name = std.fs.path.stem(std.fs.path.stem(path));
        const ref_path = try std.fmt.allocPrint(a, "{s}/{s}.ref.json", .{ argv[2], name });
        const ref = try std.Io.Dir.cwd().readFileAlloc(io, ref_path, a, .limited(64 << 20));
        const doc = (try server.json.parse(a, ref)).ok;
        var asked: usize = 0;
        var same: usize = 0;
        for (doc.get("questions").?.items().?) |q| {
            var qa = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer qa.deinit();
            const qids = try text.encode(qa.allocator(), q.strField("question").?, false);
            const past = q.get("past").?.bool;
            const found = try store.retrieve(qa.allocator(), text, qids, past, 512, &.{});
            const want = q.get("ids").?.items().?;
            var eq = want.len == found.ids.len;
            if (eq) for (want, found.ids) |w, f| {
                if (w.int64().? != f) eq = false;
            };
            asked += 1;
            if (eq) same += 1;
        }
        // the server's own copy: are the arena tail and the note list's spare capacity in memory, or only reserved?
        const tail: [2]usize = .{ 0, 0 }; // the index arena has no tail now: each allocation is its own size
        const tail_resident = try resident(tail[0], tail[1]);
        const nl = store.model.notes;
        const spare_lo = @intFromPtr(nl.items.ptr) + nl.items.len * @sizeOf(model_mod.Note);
        const spare_hi = @intFromPtr(nl.items.ptr) + nl.capacity * @sizeOf(model_mod.Note);
        const spare_resident = try resident(spare_lo, spare_hi);
        // the control: the postings were written at build, so their pages must be resident
        const post_lo = @intFromPtr(store.current.idx.post.ptr);
        const post_hi = post_lo + store.current.idx.post.len * 4;
        const post_resident = try resident(post_lo, post_hi);
        const post_pages = std.mem.alignBackward(usize, post_hi, std.heap.pageSize()) -| std.mem.alignForward(usize, post_lo, std.heap.pageSize());
        const scratch = cs.live - opened;
        const scratch_held = cs.held - opened_held;

        // 2. as Store.loadJournaled does it: the model, then the index, each under its own counter, walked to the byte
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.c_allocator, .unlimited);
        defer std.heap.c_allocator.free(bytes);
        var rep: Report = .{ .a = a };
        var cm: Counter = .{};
        const m = try model_mod.parse(cm.allocator(), bytes);
        defer m.deinit();
        var ci: Counter = .{};
        const idx = try index.Index.build(ci.allocator(), m);
        defer idx.deinit();
        const direct = try walkModel(&rep, m);
        try walkModelArena(&rep, m);
        try walkIndex(&rep, idx, m);
        const model_arena = arenaUse(m.arena).held;
        const index_arena = exactUse(idx.arena).held;
        // the walk must come to what the counters saw, to the byte
        const model_gap = @as(i64, @intCast(cm.live)) - @as(i64, @intCast(direct + model_arena));
        const index_gap = @as(i64, @intCast(ci.live)) - @as(i64, @intCast(@sizeOf(index.Index) + index_arena));
        const walked = sumOf(rep.items.items, null);

        // 3. each note's stored ids against the engine tokenizer's encode of its text (no special tokens)
        var ids_equal: usize = 0;
        var text_bytes: usize = 0;
        var non_ascii: usize = 0;
        var token_ids: usize = 0;
        var line_bytes: usize = 0;
        for (store.model.notes.items) |n| {
            var ea = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer ea.deinit();
            const enc = try text.encode(ea.allocator(), n.text, false);
            if (std.mem.eql(u32, enc, n.tokens)) ids_equal += 1;
            text_bytes += n.text.len;
            for (n.text) |ch| non_ascii += @intFromBool(ch >= 0x80);
            token_ids += n.tokens.len;
            line_bytes += n.line.len;
        }
        const notes = store.model.notes.items.len;
        const ix = store.current.idx;

        const w = &out.writer;
        try w.print("{{\"snapshot\":\"{s}\"", .{std.fs.path.basename(path)});
        const fields = [_]struct { []const u8, i64 }{
            .{ "file_bytes", @intCast(bytes.len) },                    .{ "notes", @intCast(notes) },
            .{ "current", ix.n_cur },                                  .{ "history", ix.n_hist },
            .{ "entities", @intCast(store.model.entities.items.len) }, .{ "attributes", @intCast(store.model.attributes.items.len) },
            .{ "pairs", @intCast(store.model.pairs.items.len) },       .{ "phrases", @intCast(store.model.phrases.items.len) },
            .{ "grams", ix.grams.count() },                            .{ "grams_capacity", ix.grams.capacity() },
            .{ "postings", @intCast(ix.post.len) },                    .{ "vocab", @intCast(store.model.vkey.len) },
            .{ "text_bytes", @intCast(text_bytes) },                   .{ "text_non_ascii_bytes", @intCast(non_ascii) },
            .{ "line_bytes", @intCast(line_bytes) },                   .{ "token_ids", @intCast(token_ids) },
            .{ "token_id_width", @sizeOf(u32) },                       .{ "ids_equal_encode", @intCast(ids_equal) },
            .{ "model_live", @intCast(cm.live) },                      .{ "model_parse_peak", @intCast(cm.peak) },
            .{ "index_live", @intCast(ci.live) },                      .{ "index_build_peak", @intCast(ci.peak) },
            .{ "model_gap", model_gap },                               .{ "index_gap", index_gap },
            .{ "walked", @intCast(walked) },                           .{ "store_live", @intCast(opened) },
            .{ "store_held", @intCast(opened_held) },                  .{ "store_blocks", @intCast(opened_blocks) },
            .{ "store_open_peak", @intCast(open_peak) },               .{ "store_open_held_peak", @intCast(cs.held_peak) },
            .{ "scratch", @intCast(scratch) },                         .{ "scratch_held", @intCast(scratch_held) },
            .{ "asked", @intCast(asked) },                             .{ "ids_as_python", @intCast(same) },
            .{ "sizeof_Note", @sizeOf(model_mod.Note) },               .{ "sizeof_Model", @sizeOf(model_mod.Model) },
            .{ "sizeof_Index", @sizeOf(index.Index) },                 .{ "sizeof_Store", @sizeOf(Store) },
            .{ "sizeof_Raw", @sizeOf(RawMirror) },                     .{ "page", @intCast(std.heap.pageSize()) },
            .{ "arena_tail", @intCast(tail[1] - tail[0]) },            .{ "arena_tail_resident", @intCast(tail_resident) },
            .{ "spare", @intCast(spare_hi - spare_lo) },               .{ "spare_resident", @intCast(spare_resident) },
            .{ "post_whole_pages", @intCast(post_pages) },             .{ "post_resident", @intCast(post_resident) },
        };
        for (fields) |f| try w.print(",\"{s}\":{d}", .{ f[0], f[1] });
        try w.writeAll(",\"items\":[");
        for (rep.items.items, 0..) |it, k| {
            if (k > 0) try w.writeAll(",");
            try w.print("{{\"part\":\"{s}\",\"what\":\"{s}\",\"bytes\":{d},\"grade\":\"{s}\"}}", .{ it.part, it.what, it.bytes, it.grade });
        }
        try w.writeAll("]}\n");
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return 0;
}
