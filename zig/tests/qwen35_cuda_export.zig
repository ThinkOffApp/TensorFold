//! `tf-qwen35-cuda <model> export <ids.json> <at> <out>`: #1594 step 2b's GB10 half, a kept state in hybrid order.
const std = @import("std");
const cuda = @import("cuda");
const q = @import("qwen35");
const hs = @import("hybrid_state");
const E = q.engine;

pub fn run(init: std.process.Init, a: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len != 6) return 2;
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], a, .limited(16 << 20));
    const ids = (try std.json.parseFromSlice([]u32, a, text, .{})).value;
    const at = try std.fmt.parseInt(u32, args[4], 10);
    if (at == 0 or at >= ids.len) return error.MarkOutOfRange;
    var driver = try cuda.Driver.open();
    defer driver.close();
    var ctx = try cuda.Context.init(&driver, 0);
    defer ctx.deinit();
    const e = try E.Engine.init(init.gpa, init.io, &ctx, args[1], false, null);
    defer e.deinit();
    // the copy is this model's state in this engine's order: its sizes must be the hybrid order's, piece for piece
    const l = q.reuse.layoutOf(e, at);
    if (l.total() != hs.qwen27.bytes(at) or e.g.stateBytes() != hs.qwen27.fixed() or e.g.recBytes() != hs.qwen27.rec_bytes or
        e.g.convBytes() != hs.qwen27.conv_bytes or e.g.deltas() != hs.qwen27.linear) return error.HybridGeometryDiffers;
    var cache = try E.Cache.init(init.gpa, e, ids.len + 64);
    defer cache.deinit(init.gpa);
    const t0 = std.Io.Clock.awake.now(init.io).toNanoseconds();
    var buf: [E.max_rows]u32 = undefined;
    var done: usize = 0;
    while (done < at) {
        const k = @min(E.max_rows, at - done);
        @memcpy(buf[0..k], ids[done..][0..k]);
        try e.forward(&.{.{ .cache = &cache, .rows = k }}, buf[0..k], .last);
        done += k;
    }
    try e.stream.synchronize();
    const t1 = std.Io.Clock.awake.now(init.io).toNanoseconds();
    const copy = try q.reuse.saveCache(e, &cache, at, &.{}, false);
    defer q.reuse.dropCopy(e, copy);
    if (copy.delta != 0) return error.RotaryShift; // a text prompt's: an image prompt's state is not this tool's
    var ranges: std.ArrayList(hs.Range) = .empty;
    try hs.cudaRanges(hs.qwen27, at, 0, &ranges, a); // the copy's host bytes, without cuda_disk.zig's words
    const body = try a.alloc(u8, @intCast(hs.qwen27.bytes(at)));
    try hs.gather(copy.host.bytes[0..copy.len], ranges.items, body);
    const t2 = std.Io.Clock.awake.now(init.io).toNanoseconds();
    const header = hs.Header.of(hs.qwen27, at, ids);
    var f = try std.Io.Dir.cwd().createFile(init.io, args[5], .{});
    defer f.close(init.io);
    try f.writeStreamingAll(init.io, std.mem.asBytes(&header));
    try f.writeStreamingAll(init.io, body);
    const ms = struct {
        fn of(ns: i96) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.of;
    std.debug.print("RESULT export: CUDA state after {d} of {d} tokens, {d} bytes, to {s}; prefill {d:.1} ms, save and order {d:.1} ms\n", .{ at, ids.len, body.len, args[5], ms(t1 - t0), ms(t2 - t1) });
    return 0;
}
