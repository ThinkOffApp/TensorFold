//! A prompt pass's chunk on a stream's caches, and the extend pass that reads injected context the same way.
const std = @import("std");
const lanes = @import("lanes");
const fwd = @import("forward.zig");
const st = @import("state.zig");
const layers = @import("layers.zig");
const backend = @import("backend.zig");
const Metal = backend.Metal;
const fused_rows = backend.fused_rows;
const max_window = backend.max_window;

/// Rows [at, at + rows) of the `n` ids in the backend's prompt buffer, from the cache's state; the head absorbs them.
pub const Chunk = struct {
    n: usize,
    c: *st.Cache,
    at: usize,
    rows: usize,
    pub fn encode(j: @This(), b: *Metal, e: *fwd.Enc) !void {
        const d = b.m.config.hidden * 2;
        const rows = j.rows;
        const fresh = try b.pool.take();
        var out = b.scratch.x; // the chunk's final-normed rows
        if (rows <= fused_rows) {
            const segs = [_]fwd.Seg{.{ .rows = rows, .cache = j.c, .store = .full, .slot = @intCast(fresh) }};
            b.forward().body(e, &segs, b.prompt, j.at * 4);
        } else {
            const w = &b.wide.?;
            w.chunk(e, b.forward(), j.c, b.prompt, j.at * 4, rows, fresh);
            out = w.s.x;
        }
        j.c.advance(&b.pool, rows, fresh);
        // the head's cache takes each row whose next token the prompt holds, as many rows a call as a window
        const absorbed = @min(j.at + rows, j.n - 1) - j.at;
        if (b.head) |*h| {
            var r: usize = 0;
            while (r < absorbed) : (r += max_window) h.absorb(e, j.c, @min(max_window, absorbed - r), out, r * d, b.prompt, (j.at + 1 + r) * 4);
        }
        j.c.start = 0;
        j.c.rows = rows;
        if (rows > fused_rows) {
            // the last row where the first draw and the head read it
            e.pipe(b.m.kernels.get("tf_copy_rows"));
            e.buf(out, (rows - 1) * d, 0);
            e.buf(b.scratch.x, 0, 1);
            e.run(.{ d / 2, 1, 1 }, .{ 256, 1, 1 });
            j.c.rows = 1;
        }
    }
};

/// Injected context as a prompt pass: the last kept rows again from the slot before them, the pending token, the rest.
pub fn extend(ptr: *anyopaque, s: *lanes.Stream) anyerror!void {
    const self: *Metal = @ptrCast(@alignCast(ptr));
    if (layers.firstAdapter(&self.m.weights) != null or s.prompt_logprobs != null) return error.ExtendUnsupported;
    const c = try self.cacheOf(s);
    try self.drain();
    self.settle(c);
    const ids = s.context.items;
    if (c.len != s.cache_len or ids.len <= c.len + 1) return error.PositionMismatch;
    if (ids.len + max_window > c.kv[0].capacity or ids.len > self.o.capacity) return error.ContextFull;
    if (c.mtp != null and s.drafts and c.mtp_len != c.len) return error.PositionMismatch;
    const from = c.len - c.replay; // where the stream's Mamba slot stands
    c.len = from;
    c.replay = 0;
    c.replay_map = std.simd.iota(u8, st.replay_rows);
    c.compact = null; // the kept rows' keys and values are written again in place
    if (c.mtp != null) c.mtp_len = from;
    @memcpy(self.prompt.slice(u32, ids.len), ids);
    var at = from;
    while (at < ids.len) {
        const rows = @min(self.o.chunk, ids.len - at);
        try self.submit(.prefill, self.next, Chunk{ .n = ids.len, .c = c, .at = at, .rows = rows });
        while (self.flights.items.len > 1) try self.land();
        at += rows;
    }
}
