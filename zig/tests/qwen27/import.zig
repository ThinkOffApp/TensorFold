//! #1594 step 2b's Mac half: a prompt state in hybrid_state's order restored into slot 0, its tail prefilled, logits.
const std = @import("std");
const mtl = @import("metal");
const q = @import("tensorfold").qwen27;
const host = @import("qwen27_served");
const hs = @import("fabric").hybrid_state;

const help =
    \\tf-qwen27-import MODEL IDS.json export AT OUT: this Mac's state after AT tokens, in hybrid_state's order, to OUT
    \\tf-qwen27-import MODEL IDS.json import FILE exact|close: FILE restored, the rest prefilled, logits against fresh
;

fn read(a: std.mem.Allocator, r: *const q.decode_round.Runner, st: *q.snapshot.State) ![]u8 {
    try st.landed(); // a save's blit is not waited for: it lands before the copy reads it
    const buffer = try r.model.device.buffer(st.bytes, mtl.ResourceOptions.shared | mtl.ResourceOptions.untracked);
    defer buffer.deinit();
    const cb = r.model.queue.commandBuffer();
    const e = cb.blit();
    e.copy(st.buf, 0, buffer, 0, st.bytes);
    e.end();
    cb.commit();
    cb.wait();
    if (cb.failure() != null) return error.SnapshotGpuFailure;
    return a.dupe(u8, buffer.contents()[0..st.bytes]);
}

fn logits(a: std.mem.Allocator, r: *const q.decode_round.Runner) ![]f32 {
    const ref = r.model.frame.get(.logits);
    const raw = ref.buffer.contents()[ref.offset..][0 .. r.model.config.vocab * 2];
    const out = try a.alloc(f32, r.model.config.vocab);
    for (out, 0..) |*x, i| x.* = @bitCast(@as(u32, std.mem.readInt(u16, raw[i * 2 ..][0..2], .little)) << 16);
    return out;
}

fn argmax(xs: []const f32) usize {
    var best: usize = 0;
    for (xs, 0..) |x, i| if (x > xs[best]) {
        best = i;
    };
    return best;
}

/// KL(p || q) of the two softmaxes, in nats.
fn kl(p: []const f32, qq: []const f32) f64 {
    var mp: f64 = -std.math.inf(f64);
    var mq: f64 = -std.math.inf(f64);
    for (p, qq) |x, y| {
        mp = @max(mp, x);
        mq = @max(mq, y);
    }
    var zp: f64 = 0;
    var zq: f64 = 0;
    for (p, qq) |x, y| {
        zp += @exp(@as(f64, x) - mp);
        zq += @exp(@as(f64, y) - mq);
    }
    var d: f64 = 0;
    for (p, qq) |x, y| {
        const lp = @as(f64, x) - mp - @log(zp);
        const lq = @as(f64, y) - mq - @log(zq);
        d += @exp(lp) * (lp - lq);
    }
    return d;
}

/// The state's bytes in this order must be exactly what this engine snapshots, or the geometry is not this model's.
fn sized(r: *const q.decode_round.Runner, at: u32) !void {
    if (q.snapshot.slotBytes(r, null, at) != hs.qwen27.bytes(at)) return error.HybridGeometryDiffers;
}

fn exportState(a: std.mem.Allocator, io: std.Io, r: *q.decode_round.Runner, ids: []const u32, at: u32, out: []const u8) !void {
    try sized(r, at);
    try r.reset(0);
    try (q.session.Session{ .runner = r }).promptChunk(ids[0..at], false);
    const st = try q.snapshot.saveSlot(a, r, 0, null, at, null);
    defer q.snapshot.drop(a, st);
    const body = try read(a, r, st);
    defer a.free(body);
    const header = hs.Header.of(hs.qwen27, at, ids);
    var f = try std.Io.Dir.cwd().createFile(io, out, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, std.mem.asBytes(&header));
    try f.writeStreamingAll(io, body);
    std.debug.print("RESULT export: Metal state after {d} of {d} tokens, {d} bytes, to {s}\n", .{ at, ids.len, body.len, out });
}

fn importState(a: std.mem.Allocator, io: std.Io, r: *q.decode_round.Runner, ids: []const u32, path: []const u8, exact: bool) !void {
    const file = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 30));
    defer a.free(file);
    if (file.len < @sizeOf(hs.Header)) return error.NotAHybridState;
    var header: hs.Header = undefined;
    @memcpy(std.mem.asBytes(&header), file[0..@sizeOf(hs.Header)]);
    try header.check(hs.qwen27, ids);
    const body = file[@sizeOf(hs.Header)..];
    if (body.len != header.total) return error.HybridStateLength;
    try sized(r, header.at);
    const session = q.session.Session{ .runner = r };
    // the Mac's own pass over the whole prompt: what the restored state must lead to
    try r.reset(0);
    try session.promptChunk(ids, true);
    const want = try logits(a, r);
    defer a.free(want);
    // a blank state filled with the file's bytes, restored over a slot that held the whole prompt
    const st = try q.snapshot.blank(a, r, null, header.at);
    defer q.snapshot.drop(a, st);
    @memcpy(st.buf.contents()[0..body.len], body);
    try q.snapshot.restoreSlot(a, r, 0, null, st);
    try session.promptChunk(ids[header.at..], true);
    const got = try logits(a, r);
    defer a.free(got);
    var worst: f32 = 0;
    for (want, got) |x, y| worst = @max(worst, @abs(x - y));
    const same = std.mem.eql(f32, want, got);
    const tw = argmax(want);
    const tg = argmax(got);
    const d = kl(want, got);
    std.debug.print("RESULT import: restored {d} tokens, prefilled {d}; logits {s}, worst |diff| {d:.4}, KL {e:.3} nats, first token {d} vs {d}\n", .{ header.at, ids.len - header.at, if (same) "bit-equal" else "differ", worst, d, tg, tw });
    if (exact and !same) return error.ImportNotExact;
    if (tw != tg) return error.ImportFirstTokenDiffers;
    std.debug.print("PASS import ({s})\n", .{if (exact) "exact" else "close: same first token"});
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) {
        std.debug.print("{s}", .{help});
        return error.Usage;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(16 << 20));
    const ids = (try std.json.parseFromSlice([]u32, a, text, .{})).value;
    if (ids.len < 2) return error.PromptTooShort;
    const pool = mtl.objc.Pool.push();
    defer pool.pop();
    var why: []const u8 = "";
    const h = try host.open(init.gpa, init.io, args[1], .{ .context = @intCast(ids.len + 64), .streams = 1, .cache_gib = 0 }, a, &why);
    defer host.close(h);
    for (ids) |id| if (id >= h.model.config.vocab) return error.BadToken;
    if (std.mem.eql(u8, args[3], "export")) {
        const at = try std.fmt.parseInt(u32, args[4], 10);
        if (at == 0 or at >= ids.len) return error.MarkOutOfRange;
        return exportState(init.gpa, init.io, &h.runner, ids, at, args[5]);
    }
    if (std.mem.eql(u8, args[3], "import")) return importState(init.gpa, init.io, &h.runner, ids, args[4], std.mem.eql(u8, args[5], "exact"));
    std.debug.print("{s}", .{help});
    return error.Usage;
}
