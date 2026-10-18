//! notes-sa-bench: postings and suffix-array index side by side (build, lookups, writes, merges, erases).
const std = @import("std");
const server = @import("server");
const ops = server.notes_ops;
const index = server.notes_index;
const model_mod = server.notes_model;
const Store = server.notes_store.Store;
const Kind = server.notes_store.IndexKind;
const Allocator = std.mem.Allocator;

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

fn pct(xs: []u64, p: usize) f64 {
    if (xs.len == 0) return 0;
    std.sort.pdq(u64, xs, {}, std.sort.asc(u64));
    return @as(f64, @floatFromInt(xs[@min(xs.len - 1, (xs.len * p + 99) / 100 -| 1)])) / 1e3;
}

const Q = struct { text: []const u8, past: bool };

/// Every question REPS times, round robin: the whole retrieve (encode, lookup and render, fit) and the lookup alone.
fn lookups(store: *Store, text: server.model_text.Text, qs: []const Q, reps: usize, a: Allocator, io: std.Io, total: *std.ArrayList(u64), inner: *std.ArrayList(u64), digest: *u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var h = std.hash.Wyhash.init(0);
    for (0..reps) |r| for (qs) |q| {
        _ = arena.reset(.retain_capacity);
        const qa = arena.allocator();
        const t0 = now(io);
        const ids = try text.encode(qa, q.text, false);
        const got = try store.retrieve(qa, text, ids, q.past, 512, &.{});
        const ns = now(io) - t0;
        if (r > 0) { // the first round warms the caches and the kept scratch
            try total.append(a, ns);
            try inner.append(a, @intCast(got.lookup_ns));
        } else {
            h.update(got.block);
            h.update(std.mem.sliceAsBytes(got.ids));
        }
    };
    digest.* = h.final();
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len < 6 or argv.len > 10) {
        std.debug.print("usage: notes-sa-bench MODEL_DIR SNAPSHOT REF.json OUT_DIR WRITES [SIDE_MAX [sync|thread [postings|sa [HARD_MAX]]]]\n", .{});
        return 2;
    }
    const sync = argv.len >= 8 and std.mem.eql(u8, argv[7], "sync"); // merges in the write, not on a thread
    const hard_max: ?u32 = if (argv.len == 10) try std.fmt.parseInt(u32, argv[9], 10) else null;
    const only: ?Kind = if (argv.len >= 9) std.meta.stringToEnum(Kind, argv[8]) orelse return 2 else null;
    const side_max: u32 = if (argv.len >= 7) try std.fmt.parseInt(u32, argv[6], 10) else 1024;
    var problem: []const u8 = "";
    const ht = try server.hf_text.HfText.load(gpa, io, argv[1], null, a, &problem);
    defer ht.deinit();
    const text = ht.text();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, argv[2], gpa, .unlimited);
    defer gpa.free(bytes);
    const ref = try std.Io.Dir.cwd().readFileAlloc(io, argv[3], a, .limited(64 << 20));
    const doc = (try server.json.parse(a, ref)).ok;
    var qs: std.ArrayList(Q) = .empty;
    for (doc.get("questions").?.items().?) |q| try qs.append(a, .{ .text = q.strField("question").?, .past = q.get("past").?.bool });
    const writes = try std.fmt.parseInt(usize, argv[5], 10);
    const m = try model_mod.parse(gpa, bytes);
    defer m.deinit();
    const n = m.notes.items.len;
    const reps: usize = if (n >= 100_000) 20 else 50;
    const builds: usize = if (n >= 100_000) 5 else 20;
    var out: std.Io.Writer.Allocating = .init(a);
    for ([_]Kind{ .postings, .sa }) |kind| {
        if (only) |k| if (k != kind) continue;
        // 1. the index build from a parsed model (what a load and, for postings, every write does)
        var build_ns: std.ArrayList(u64) = .empty;
        for (0..builds) |_| {
            const t0 = now(io);
            const idx = try index.Index.buildKind(gpa, m, kind);
            const ns = now(io) - t0;
            idx.deinit();
            try build_ns.append(a, ns);
        }
        // 2. the lookups on the loaded store
        const snap = try std.fmt.allocPrint(a, "{s}/{s}-{d}.snap.json", .{ argv[4], @tagName(kind), n });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snap, .data = bytes });
        const journal = try std.mem.concat(a, u8, &.{ snap, ".journal" });
        std.Io.Dir.cwd().deleteFile(io, journal) catch {};
        const store = Store.openIndexed(gpa, io, snap, text, argv[1], kind, &problem) catch |e| {
            std.debug.print("open: {s} ({s})\n", .{ problem, @errorName(e) });
            return 1;
        };
        defer store.deinit();
        store.side_max = side_max;
        store.bw.background_merge = !sync;
        store.bw.hard_max = hard_max;
        var t_load: std.ArrayList(u64) = .empty;
        var i_load: std.ArrayList(u64) = .empty;
        var d_load: u64 = 0;
        try lookups(store, text, qs.items, reps, a, io, &t_load, &i_load, &d_load);
        // 3. writes as the live bench makes them (no erases among them): the side buffer fills, merges past side_max
        var write_ns: std.ArrayList(u64) = .empty;
        var merge_write_ns: std.ArrayList(u64) = .empty; // a write whose version is on a new core (made here or on a thread)
        var start_ns: std.ArrayList(u64) = .empty; // a write that began a merge on its own thread (the notes copied)
        var all_ns: std.ArrayList(u64) = .empty;
        var vbuild_ns: std.ArrayList(u64) = .empty;
        var why: ops.Refusal = .{};
        for (0..writes) |k| {
            var wa = std.heap.ArenaAllocator.init(gpa);
            defer wa.deinit();
            const w = wa.allocator();
            const item = try std.fmt.allocPrint(w, "my item {d}", .{k / 4});
            const last = store.model.notes.items[store.model.notes.items.len - 1];
            const merges = store.merges;
            const was_merging = store.bw.merging != null;
            const t0 = now(io);
            _ = switch (k % 4) {
                0 => try ops.perform(store, w, .{ .op = .add, .text = try std.fmt.allocPrint(w, "My item {d} is red.", .{k / 4}), .subject = item }, &why),
                1 => try ops.perform(store, w, .{ .op = .change, .text = try std.fmt.allocPrint(w, "My item {d} is blue now.", .{k / 4}), .target = last.id }, &why),
                2 => try ops.perform(store, w, .{ .op = .add, .text = try std.fmt.allocPrint(w, "my item {d} is blue now", .{k / 4}), .subject = item }, &why),
                else => try ops.perform(store, w, .{ .op = .take_back, .text = "I take that back.", .target = last.id }, &why),
            };
            const ns = now(io) - t0;
            try all_ns.append(a, ns);
            try (if (store.merges != merges) &merge_write_ns else if (!was_merging and store.bw.merging != null) &start_ns else &write_ns).append(a, ns);
            if (k % 50 == 25) { // the version build alone, at this point (the write's own share of its time)
                const t1 = now(io);
                const v = try store.build();
                try vbuild_ns.append(a, now(io) - t1);
                v.idx.deinit();
                gpa.destroy(v);
            }
        }
        const ix = store.current.idx;
        const delta_bytes: usize = if (ix.layer.core != null) ix.arena.bytes() else 0; // read now: a merge below frees it
        const delta_notes: usize = ix.notes() - ix.layer.core_n;
        const side = if (ix.base) |b| ix.notes() - b.notes else 0;
        // 4. the lookups on the written store, the side buffer as the writes left it
        var t_written: std.ArrayList(u64) = .empty;
        var i_written: std.ArrayList(u64) = .empty;
        var d_written: u64 = 0;
        try lookups(store, text, qs.items, reps, a, io, &t_written, &i_written, &d_written);
        // 5. an on-demand merge (sa: the side buffer into a new base; postings: the index built again), then erases
        var merge_ns: std.ArrayList(u64) = .empty;
        for (0..3) |_| {
            const t0 = now(io);
            try store.merge();
            try merge_ns.append(a, now(io) - t0);
        }
        var t_merged: std.ArrayList(u64) = .empty;
        var i_merged: std.ArrayList(u64) = .empty;
        var d_merged: u64 = 0;
        try lookups(store, text, qs.items, reps, a, io, &t_merged, &i_merged, &d_merged);
        var erase_ns: std.ArrayList(u64) = .empty;
        for (0..3) |_| {
            var wa = std.heap.ArenaAllocator.init(gpa);
            defer wa.deinit();
            const last = store.model.notes.items[store.model.notes.items.len - 1];
            const t0 = now(io);
            _ = try ops.erase(store, wa.allocator(), last.id, &why);
            try erase_ns.append(a, now(io) - t0);
        }
        const o = &out.writer;
        try o.print("{{\"merges_on\":\"{s}\",", .{if (sync) "the write" else "a thread"});
        try o.print("\"kind\":\"{s}\",\"snapshot\":\"{s}\",\"notes\":{d},\"questions\":{d},\"reps\":{d},\"side_max\":{d},\"writes\":{d},\"notes_after\":{d},\"side_after\":{d},\"merges\":{d}", .{ @tagName(kind), std.fs.path.basename(argv[2]), n, qs.items.len, reps, side_max, writes, store.model.notes.items.len, side, store.merges });
        try o.print(",\"build_ms\":{{\"p50\":{d:.2},\"min\":{d:.2},\"n\":{d}}}", .{ pct(build_ns.items, 50) / 1e3, pct(build_ns.items, 0) / 1e3, build_ns.items.len });
        try o.print(",\"lookup_us\":{{\"p50\":{d:.1},\"p95\":{d:.1},\"inner_p50\":{d:.1},\"inner_p95\":{d:.1},\"n\":{d},\"digest\":\"{x}\"}}", .{ pct(t_load.items, 50), pct(t_load.items, 95), pct(i_load.items, 50), pct(i_load.items, 95), t_load.items.len, d_load });
        try o.print(",\"write_ms\":{{\"p50\":{d:.2},\"p95\":{d:.2},\"n\":{d}}},\"merge_write_ms\":{{\"p50\":{d:.2},\"max\":{d:.2},\"n\":{d}}}", .{ pct(write_ns.items, 50) / 1e3, pct(write_ns.items, 95) / 1e3, write_ns.items.len, pct(merge_write_ns.items, 50) / 1e3, pct(merge_write_ns.items, 100) / 1e3, merge_write_ns.items.len });
        try o.print(",\"merge_start_ms\":{{\"p50\":{d:.2},\"max\":{d:.2},\"n\":{d}}}", .{ pct(start_ns.items, 50) / 1e3, pct(start_ns.items, 100) / 1e3, start_ns.items.len });
        try o.print(",\"all_writes_ms\":{{\"p50\":{d:.2},\"p95\":{d:.2},\"p99\":{d:.2},\"max\":{d:.2},\"n\":{d}}}", .{ pct(all_ns.items, 50) / 1e3, pct(all_ns.items, 95) / 1e3, pct(all_ns.items, 99) / 1e3, pct(all_ns.items, 100) / 1e3, all_ns.items.len });
        try o.print(",\"version_build_ms\":{{\"p50\":{d:.2},\"p95\":{d:.2},\"n\":{d}}}", .{ pct(vbuild_ns.items, 50) / 1e3, pct(vbuild_ns.items, 95) / 1e3, vbuild_ns.items.len });
        try o.print(",\"lookup_written_us\":{{\"p50\":{d:.1},\"p95\":{d:.1},\"inner_p50\":{d:.1},\"inner_p95\":{d:.1},\"digest\":\"{x}\"}}", .{ pct(t_written.items, 50), pct(t_written.items, 95), pct(i_written.items, 50), pct(i_written.items, 95), d_written });
        try o.print(",\"merge_ms\":{{\"p50\":{d:.2},\"max\":{d:.2}}},\"lookup_merged_us\":{{\"p50\":{d:.1},\"p95\":{d:.1},\"digest\":\"{x}\"}}", .{ pct(merge_ns.items, 50) / 1e3, pct(merge_ns.items, 100) / 1e3, pct(t_merged.items, 50), pct(t_merged.items, 95), d_merged });
        try o.print(",\"delta_bytes\":{d},\"delta_notes\":{d}", .{ delta_bytes, delta_notes });
        try o.print(",\"hard_max\":{d},\"waits\":{d},\"wait_ms\":{d:.2}", .{ store.bw.hardLimit(store.side_max), store.bw.waits, @as(f64, @floatFromInt(store.bw.wait_ns)) / 1e6 });
        try o.print(",\"erase_ms\":{{\"p50\":{d:.2},\"max\":{d:.2},\"n\":{d}}}}}\n", .{ pct(erase_ns.items, 50) / 1e3, pct(erase_ns.items, 100) / 1e3, erase_ns.items.len });
        std.Io.Dir.cwd().deleteFile(io, journal) catch {};
        std.Io.Dir.cwd().deleteFile(io, snap) catch {};
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return 0;
}
