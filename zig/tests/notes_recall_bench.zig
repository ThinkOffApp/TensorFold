//! notes-recall MODEL_DIR DIR [off | all:MAX | longest]: recall at the cap on the paper's sets (tools/notes/recall_export.py),
//! with the suffix-array index and its longer matches off or on. Per question: the engine's lookup as the server
//! makes it (is_past, cap 512), against Python retrieve()'s ids and block, and whether every needed note came back.
//! One JSON line per group (L1-L6, L7; or the listing's own) and mode.
const std = @import("std");
const server = @import("server");
const Store = server.notes_store.Store;
const past_mod = server.notes_past;
const index = server.notes_index;

fn pct(xs: []u64, p: usize) u64 {
    if (xs.len == 0) return 0;
    std.sort.pdq(u64, xs, {}, std.sort.asc(u64));
    return xs[@min(xs.len - 1, (xs.len * p + 99) / 100 -| 1)];
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 4) {
        std.debug.print("usage: notes-recall MODEL_DIR DIR off|all:MAX|longest\n", .{});
        return 2;
    }
    var long: index.Long = .{};
    if (std.mem.eql(u8, argv[3], "longest")) {
        long.mode = .longest;
    } else if (std.mem.startsWith(u8, argv[3], "all:")) {
        long = .{ .mode = .all, .max = try std.fmt.parseInt(u8, argv[3][4..], 10) };
    } else if (!std.mem.eql(u8, argv[3], "off")) return 2;
    var problem: []const u8 = "";
    const ht = try server.hf_text.HfText.load(gpa, io, argv[1], null, a, &problem);
    defer ht.deinit();
    const text = ht.text();
    const listing = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ argv[2], "index.json" }), a, .limited(1 << 20));
    const stems = (try server.json.parse(a, listing)).ok;
    var out: std.Io.Writer.Allocating = .init(a);
    var groups: std.ArrayList([]const u8) = .empty; // in the listing's order
    for (stems.items().?) |st| {
        const g = st.strField("group").?;
        for (groups.items) |x| {
            if (std.mem.eql(u8, x, g)) break;
        } else try groups.append(a, g);
    }
    for (groups.items) |group| {
        var asked: usize = 0;
        var with_needed: usize = 0;
        var hit: usize = 0;
        var py_hit: usize = 0;
        var same_ids: usize = 0;
        var same_block: usize = 0;
        var past_same: usize = 0;
        var gained: usize = 0; // needed notes all back here, not in Python's (off) block
        var lost: usize = 0;
        var notes_total: usize = 0;
        var unneeded: usize = 0;
        var long_q: usize = 0; // questions with an n-gram over n_max weighted
        var long_n: usize = 0;
        var tokens: std.ArrayList(u64) = .empty;
        var py_tokens: std.ArrayList(u64) = .empty;
        for (stems.items().?) |st| {
            if (!std.mem.eql(u8, st.strField("group").?, group)) continue;
            const stem = st.strField("stem").?;
            const snap = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.snap.json", .{ argv[2], stem }), gpa, .unlimited);
            defer gpa.free(snap);
            const store = Store.loadIndexed(gpa, io, snap, text, .sa, &problem) catch |e| {
                std.debug.print("{s}: {s} ({s})\n", .{ stem, problem, @errorName(e) });
                return 1;
            };
            defer store.deinit();
            store.long = long;
            const ref = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}.ref.json", .{ argv[2], stem }), a, .limited(16 << 20));
            const doc = (try server.json.parse(a, ref)).ok;
            for (doc.get("questions").?.items().?) |q| {
                var qa = std.heap.ArenaAllocator.init(gpa);
                defer qa.deinit();
                const question = q.strField("question").?;
                const past = past_mod.isPast(question);
                const got = try store.retrieve(qa.allocator(), text, try text.encode(qa.allocator(), question, false), past, 512, &.{});
                asked += 1;
                long_q += @intFromBool(got.long > 0);
                long_n += got.long;
                past_same += @intFromBool(past == q.get("past").?.bool);
                const want = q.get("ids").?.items().?;
                var eq = want.len == got.ids.len;
                if (eq) for (want, got.ids) |w, g| {
                    eq = eq and w.int64().? == g;
                };
                same_ids += @intFromBool(eq);
                same_block += @intFromBool(std.mem.eql(u8, q.strField("block").?, got.block));
                try tokens.append(a, got.tokens);
                try py_tokens.append(a, @intCast(q.get("tokens").?.int64().?));
                notes_total += got.ids.len;
                const need = q.get("need").?.items().?;
                for (got.ids) |g| {
                    var needed = false;
                    for (need) |x| needed = needed or x.int64().? == g;
                    unneeded += @intFromBool(!needed);
                }
                if (need.len == 0) continue;
                with_needed += 1;
                var all_here = true;
                var all_py = true;
                for (need) |x| {
                    const id = x.int64().?;
                    var here = false;
                    for (got.ids) |g| here = here or g == id;
                    var py = false;
                    for (want) |w| py = py or w.int64().? == id;
                    all_here = all_here and here;
                    all_py = all_py and py;
                }
                hit += @intFromBool(all_here);
                py_hit += @intFromBool(all_py);
                gained += @intFromBool(all_here and !all_py);
                lost += @intFromBool(!all_here and all_py);
            }
        }
        try out.writer.print("{{\"group\":\"{s}\",\"long\":\"{s}\",\"questions\":{d},\"with_needed\":{d},\"recall\":{d},\"python_recall\":{d},\"gained\":{d},\"lost\":{d}," ++
            "\"ids_as_python\":{d},\"block_as_python\":{d},\"past_as_python\":{d},\"tokens_p50\":{d},\"tokens_p95\":{d},\"python_tokens_p50\":{d},\"python_tokens_p95\":{d},\"notes_per_block\":{d:.2},\"unneeded_per_block\":{d:.2},\"questions_with_long\":{d},\"long_ngrams\":{d}}}\n", .{
            group,                   argv[3],                   asked,                     with_needed,              hit,                        py_hit,               gained, lost,
            same_ids,                same_block,                past_same,                 pct(tokens.items, 50),    pct(tokens.items, 95),      pct(py_tokens.items, 50), pct(py_tokens.items, 95),
            @as(f64, @floatFromInt(notes_total)) / @as(f64, @floatFromInt(asked)), @as(f64, @floatFromInt(unneeded)) / @as(f64, @floatFromInt(asked)), long_q, long_n,
        });
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return 0;
}
