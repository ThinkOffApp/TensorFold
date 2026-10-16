//! notes-live-bench MODEL_DIR SNAPSHOT REF.json OUT_DIR WRITES: 8 threads look up alone, during writes, after.
const std = @import("std");
const server = @import("server");
const ops = server.notes_ops;
const Store = server.notes_store.Store;
const Allocator = std.mem.Allocator;

const threads = 8;

const Shared = struct {
    store: *Store,
    text: server.model_text.Text,
    questions: []const []const u8,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(u8) = .init(0), // 0 alone, 1 during the writes, 2 alone after
    times: [3][threads]std.ArrayList(u64) = @splat(@splat(.empty)),
    failed: std.atomic.Value(u32) = .init(0),
};

fn reader(sh: *Shared, k: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var n: usize = k * 7;
    while (!sh.stop.load(.acquire)) : (n += 1) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const q = sh.questions[n % sh.questions.len];
        const phase = sh.phase.load(.acquire);
        const t0 = std.Io.Clock.awake.now(sh.io).toNanoseconds();
        // as a chat request does it: the question encoded, looked up, fit() counted
        const ids = sh.text.encode(a, q, false) catch return fail(sh);
        _ = sh.store.retrieve(a, sh.text, ids, false, 512, &.{}) catch return fail(sh);
        const ns: u64 = @intCast(std.Io.Clock.awake.now(sh.io).toNanoseconds() - t0);
        sh.times[phase][k].append(std.heap.page_allocator, ns) catch return fail(sh);
    }
}

fn fail(sh: *Shared) void {
    _ = sh.failed.fetchAdd(1, .monotonic);
}

fn pct(xs: []u64, p: usize) f64 {
    if (xs.len == 0) return 0;
    std.sort.pdq(u64, xs, {}, std.sort.asc(u64));
    return @as(f64, @floatFromInt(xs[@min(xs.len - 1, (xs.len * p + 99) / 100 -| 1)])) / 1e3;
}

fn all(a: Allocator, lists: []std.ArrayList(u64)) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    for (lists) |l| try out.appendSlice(a, l.items);
    return out.items;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 6) {
        std.debug.print("usage: notes-live-bench MODEL_DIR SNAPSHOT REF.json OUT_DIR WRITES\n", .{});
        return 2;
    }
    var problem: []const u8 = "";
    const ht = try server.hf_text.HfText.load(gpa, io, argv[1], null, a, &problem);
    defer ht.deinit();
    const text = ht.text();
    const ref = try std.Io.Dir.cwd().readFileAlloc(io, argv[3], a, .limited(64 << 20));
    const doc = (try server.json.parse(a, ref)).ok;
    var qs: std.ArrayList([]const u8) = .empty;
    for (doc.get("questions").?.array) |q| try qs.append(a, q.strField("question").?);
    // the snapshot copied beside a fresh journal
    const snap = try std.fs.path.join(a, &.{ argv[4], "bench.snap.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, argv[2], a, .unlimited);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snap, .data = bytes });
    const journal = try std.mem.concat(a, u8, &.{ snap, ".journal" });
    std.Io.Dir.cwd().deleteFile(io, journal) catch {};
    const store = Store.open(gpa, io, snap, text, argv[1], &problem) catch |e| {
        std.debug.print("open: {s} ({s})\n", .{ problem, @errorName(e) });
        return 1;
    };
    defer store.deinit();
    const base = store.model.notes.items.len;
    const writes = try std.fmt.parseInt(usize, argv[5], 10);
    var sh: Shared = .{ .store = store, .text = text, .questions = qs.items, .io = io };
    var ts: [threads]std.Thread = undefined;
    for (&ts, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, reader, .{ &sh, k });
    std.Io.sleep(io, .fromSeconds(2), .awake) catch {};
    sh.phase.store(1, .release);
    var write_ns: std.ArrayList(u64) = .empty;
    var erase_ns: std.ArrayList(u64) = .empty;
    var why: ops.Refusal = .{};
    var k: usize = 0;
    while (k < writes) : (k += 1) {
        var wa = std.heap.ArenaAllocator.init(gpa);
        defer wa.deinit();
        const w = wa.allocator();
        const item = try std.fmt.allocPrint(w, "my item {d}", .{k / 4});
        const last = store.model.notes.items[store.model.notes.items.len - 1];
        const t0 = std.Io.Clock.awake.now(io).toNanoseconds();
        var is_erase = false;
        _ = switch (k % 4) {
            0 => try ops.perform(store, w, .{ .op = .add, .text = try std.fmt.allocPrint(w, "My item {d} is red.", .{k / 4}), .subject = item }, &why),
            1 => try ops.perform(store, w, .{ .op = .change, .text = try std.fmt.allocPrint(w, "My item {d} is blue now.", .{k / 4}), .target = last.id }, &why),
            2 => try ops.perform(store, w, .{ .op = .add, .text = try std.fmt.allocPrint(w, "my item {d} is blue now", .{k / 4}), .subject = item }, &why),
            else => if (k % 100 == 99) blk: {
                is_erase = true;
                _ = try ops.erase(store, w, last.id, &why);
                break :blk try ops.perform(store, w, .{ .op = .add, .text = "I like long walks.", .subject = item }, &why);
            } else try ops.perform(store, w, .{ .op = .take_back, .text = "I take that back.", .target = last.id }, &why),
        };
        const ns: u64 = @intCast(std.Io.Clock.awake.now(io).toNanoseconds() - t0);
        try (if (is_erase) &erase_ns else &write_ns).append(a, ns);
    }
    sh.phase.store(2, .release);
    std.Io.sleep(io, .fromSeconds(2), .awake) catch {};
    sh.stop.store(true, .release);
    for (ts) |t| t.join();
    const alone = try all(a, &sh.times[0]);
    const during = try all(a, &sh.times[1]);
    const after = try all(a, &sh.times[2]);
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{{\"snapshot\":\"{s}\",\"notes_before\":{d},\"notes_after\":{d},\"writes\":{d},\"erases\":{d},\"failed\":{d}," ++
        "\"alone\":{{\"n\":{d},\"p50_us\":{d:.1},\"p95_us\":{d:.1}}},\"during\":{{\"n\":{d},\"p50_us\":{d:.1},\"p95_us\":{d:.1}}}," ++
        "\"after\":{{\"n\":{d},\"p50_us\":{d:.1},\"p95_us\":{d:.1}}},\"write_us\":{{\"p50\":{d:.1},\"p95\":{d:.1}}},\"erase_us\":{{\"p50\":{d:.1},\"p95\":{d:.1}}}}}\n", .{
        std.fs.path.basename(argv[2]), base,          store.model.notes.items.len, write_ns.items.len, erase_ns.items.len, sh.failed.load(.acquire),
        alone.len,                     pct(alone, 50), pct(alone, 95),               during.len,         pct(during, 50),    pct(during, 95),
        after.len,                     pct(after, 50), pct(after, 95),               pct(write_ns.items, 50), pct(write_ns.items, 95), pct(erase_ns.items, 50), pct(erase_ns.items, 95),
    });
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return 0;
}
