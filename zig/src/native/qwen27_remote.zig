//! #1594 step 2b on the Mac: a prompt prefix the GB10 prefilled, pulled over an MKVH link into a blank Qwen27 state.
const std = @import("std");
const tf = @import("tensorfold");
const api = @import("engine_api");
const q = tf.qwen27;
const fabric = tf.fabric;
const ps = fabric.prefill_source;
const hs = fabric.hybrid_state;
const hx = fabric.hybrid_export;
const Filled = api.lane_remote.Filled;

/// Tokens to an attention layer's page row in the hand-off; the GB10's export uses the same.
pub const block: u32 = 16;

/// The lane host's remote source: one pull at a time over its link, each into a blank state of this runner's shape.
pub const Pull = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runner: *const q.decode_round.Runner,
    remote: ps.Remote, // protocol 2, its policy, the link's client and the trigger that asks the GB10
    mutex: std.Io.Mutex = .init,
    pulls: u64 = 0,
    ns: u64 = 0, // wall time of every pull, the trigger's prefill included

    pub fn source(p: *Pull) api.lane_remote.Source {
        return .{ .ptr = p, .fill = fill, .drop = drop };
    }

    /// A prefix of `prompt` on a page-row boundary, filled remotely and landed whole, or an error naming why not.
    pub fn pull(p: *Pull, prompt: []const u32) !?Filled {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const src = p.remote.source();
        const offer = src.offer(prompt, 0) orelse return null;
        const at: u32 = std.math.cast(u32, offer.upto) orelse return error.PrefixTooLong;
        const plan: hx.Plan = .{ .g = hs.qwen27, .s = hx.qwen27, .at = at, .block = block };
        try plan.check();
        if (q.snapshot.slotBytes(p.runner, null, at) != hs.qwen27.bytes(at)) return error.HybridGeometryDiffers;
        const t0 = fabric.words.nowNs();
        const st = try q.snapshot.blank(p.gpa, p.runner, null, at);
        errdefer q.snapshot.drop(p.gpa, st);
        var landing: hx.Landing = .{ .plan = plan, .image = st.buf.contents()[0..@intCast(hs.qwen27.bytes(at))] };
        try src.fill(prompt, offer, .{ .ptr = &landing, .put_fn = hx.Landing.putAny, .commit_fn = committed, .abort_fn = aborted });
        if (!landing.whole()) return error.PartialState;
        p.pulls += 1;
        p.ns += fabric.words.nowNs() - t0;
        return .{ .saved = st, .at = at };
    }

    fn fill(ptr: *anyopaque, prompt: []const u32) anyerror!?Filled {
        const p: *Pull = @ptrCast(@alignCast(ptr));
        return p.pull(prompt);
    }

    fn drop(ptr: *anyopaque, saved: *anyopaque) void {
        const p: *Pull = @ptrCast(@alignCast(ptr));
        q.snapshot.drop(p.gpa, @ptrCast(@alignCast(saved)));
    }

    fn committed(_: *anyopaque, _: u64, _: ps.Provenance) void {} // landing.whole() is the check, after fill
    fn aborted(_: *anyopaque) void {} // the caller drops the blank state
};
