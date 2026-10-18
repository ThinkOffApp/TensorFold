//! One Metal prompt pass against the same prompt cut in two at each P: the first token and the next K greedy ones.
const std = @import("std");
const mtl = @import("metal");
const tf = @import("tensorfold");

const nm = tf.nemotron;
const lanes = tf.lanes;

fn fail(comptime f: []const u8, a: anytype) noreturn {
    std.debug.print(f ++ "\n", a);
    std.process.exit(2);
}

/// Prompts by name (a JSON object of id arrays), as /v1/tokenize returns them.
fn readPrompts(arena: std.mem.Allocator, path: []const u8) !std.json.ArrayHashMap([]u32) {
    const z = try arena.dupeSentinel(u8, path, 0);
    const f = try mtl.MappedFile.open(z);
    defer f.deinit();
    return std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]u32), arena, f.bytes[0..f.size], .{ .allocate = .alloc_always });
}

/// A prompt's greedy reply of `k` tokens through the lane core, its pass cut at `cuts` (empty: the backend's step).
fn reply(gpa: std.mem.Allocator, cfg: *const lanes.Config, b: *nm.backend.Metal, io: std.Io, ids: []const u32, cuts: []const u32, k: u32, drafts: bool) ![]u32 {
    var clock = lanes.backend.WallClock{ .io = io };
    var engine = lanes.Engine.init(gpa, cfg, b.backend(), clock.clock());
    defer engine.deinit();
    var s = try lanes.Stream.init(gpa, .{ .id = "cut", .prompt = ids, .max_new = k, .drafts = drafts, .chunks = cuts });
    defer s.deinit(gpa);
    try engine.addStream(&s);
    while (engine.activeCount() > 0) try engine.step();
    try b.drain();
    return gpa.dupe(u32, s.emitted());
}

fn sha(ids: []const u32) [8]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [16]u8 = undefined;
    for (ids, 0..) |t, i| {
        if (i > 0) h.update(",");
        h.update(std.fmt.bufPrint(&buf, "{d}", .{t}) catch unreachable);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d[0..4].*, .lower);
}

/// usage: tf-nemotron-cut-check MODEL PROMPTS.json K P[,P...]; P 0 is the uncut pass every other is compared with.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) fail("usage: tf-nemotron-cut-check MODEL PROMPTS.json K P[,P...]", .{});
    const k = try std.fmt.parseInt(u32, args[3], 10);
    var cuts: std.ArrayList(u32) = .empty;
    var it = std.mem.splitScalar(u8, args[4], ',');
    while (it.next()) |p| try cuts.append(arena, try std.fmt.parseInt(u32, p, 10));
    const pool = mtl.objc.Pool.push();
    defer pool.pop();
    const prompts = try readPrompts(arena, args[2]);
    var longest: usize = 0;
    for (prompts.map.values()) |v| longest = @max(longest, v.len);
    const m = try nm.Model.load(gpa, init.io, args[1], true);
    defer m.deinit();
    const b = try nm.backend.Metal.init(gpa, m, .{ .chunk = 8192, .capacity = longest + k + 128, .drafts = true, .streams = 2, .batch_rows = 64 });
    defer b.deinit();
    try nm.timing.measure(b, init.io);
    var cfg = try lanes.Config.init(gpa, b.facts(), nm.backend.max_window, nm.backend.max_window - 1);
    defer cfg.deinit(gpa);
    var unequal: usize = 0;
    for (prompts.map.keys(), prompts.map.values()) |name, ids| for ([_]bool{ false, true }) |drafts| {
        const whole = try reply(gpa, &cfg, b, init.io, ids, &.{}, k, drafts);
        defer gpa.free(whole);
        std.debug.print("{s} {s} n={d} uncut: first {d} sha {s}\n", .{ name, if (drafts) "drafted" else "plain", ids.len, whole[0], &sha(whole) });
        for (cuts.items) |p| {
            if (p == 0 or p >= ids.len) continue;
            const cut = try reply(gpa, &cfg, b, init.io, ids, &.{p}, k, drafts);
            defer gpa.free(cut);
            var same: usize = 0;
            while (same < @min(cut.len, whole.len) and cut[same] == whole[same]) same += 1;
            const equal = same == whole.len and cut.len == whole.len;
            if (!equal) unequal += 1;
            std.debug.print("  P={d}: first {d} ({s}), sha {s}, {s}", .{ p, cut[0], if (cut[0] == whole[0]) "same" else "differs", &sha(cut), if (equal) "EQUAL" else "UNEQUAL" });
            if (!equal) std.debug.print(" at token {d}: {d} vs {d}", .{ same, if (same < cut.len) cut[same] else 0, if (same < whole.len) whole[same] else 0 });
            std.debug.print("\n", .{});
        }
    };
    std.debug.print("{d} cut replies differ from their uncut pass\n", .{unequal});
}
