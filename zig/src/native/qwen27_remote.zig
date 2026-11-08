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
const Flags = api.lane_remote.Flags;
const trigger = @import("remote_trigger.zig");

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

/// What serve refuses before loading: one flag without the other, another model, or a drafter (no taps come across).
pub fn refusal(f: Flags, qwen27: bool, drafter: bool) ?[]const u8 {
    if (!f.on()) return null;
    if (f.url == null or f.link == null) return "--prefill-from and --mcdma-link go together: the GB10 server's URL and the mcdma-rpcd link it answers on";
    if (!qwen27) return "--prefill-from serves Qwen3.8-27B only (#1594 step 2b): serve this model without it";
    if (drafter) return "--prefill-from runs without --drafter for now: a remote prefix carries no drafter taps";
    return null;
}

/// The prefix policy: TF_PREFILL_MIN prompt tokens at least (1024), in TF_PREFILL_CHUNK pieces (512, whole page rows).
pub fn policy() !ps.Policy {
    var p: ps.Policy = .{ .enabled = true };
    if (std.c.getenv("TF_PREFILL_MIN")) |v| p.min_prefix = std.fmt.parseInt(u64, std.mem.span(v), 10) catch return error.BadPrefillMin;
    if (std.c.getenv("TF_PREFILL_CHUNK")) |v| p.chunk = std.fmt.parseInt(u64, std.mem.span(v), 10) catch return error.BadPrefillChunk;
    if (p.chunk == 0 or p.chunk % block != 0) return error.BadPrefillChunk;
    return p;
}

/// A served link: the connect daemon's mailbox, its client, the HTTP trigger and the pull, as long as the server runs.
pub const Link = struct {
    box: fabric.mailbox.Mailbox,
    client: fabric.mailbox.Client,
    http: trigger.Http,
    pull: Pull,

    /// `model` names the checkpoint both ends load (the manifest's model must equal it).
    pub fn start(gpa: std.mem.Allocator, io: std.Io, runner: *const q.decode_round.Runner, f: Flags, model: []const u8) !*Link {
        const l = try gpa.create(Link);
        errdefer gpa.destroy(l);
        const rules = try policy();
        l.box = try fabric.mailbox.Mailbox.openConnect(f.link.?);
        errdefer l.box.close();
        l.client = try fabric.mailbox.Client.init(&l.box, fabric.words.native, 30 * std.time.ns_per_s);
        const base = std.mem.trimEnd(u8, f.url.?, "/");
        l.http = .{ .gpa = gpa, .io = io, .url = try std.fmt.allocPrint(gpa, "{s}/v1/completions", .{base}), .model = "" };
        l.pull = .{ .gpa = gpa, .io = io, .runner = runner, .remote = .{ .gpa = gpa, .policy = rules, .client = &l.client, .trigger = l.http.trigger(), .model = model, .protocol = fabric.wire.recurrent_version } };
        return l;
    }

    pub fn stop(l: *Link, gpa: std.mem.Allocator) void {
        if (l.pull.pulls > 0) std.log.info("remote prefill: {d} prefixes pulled, {d:.1} ms each on average", .{ l.pull.pulls, @as(f64, @floatFromInt(l.pull.ns)) / @as(f64, @floatFromInt(l.pull.pulls)) / 1e6 });
        gpa.free(l.http.url);
        l.box.close();
        gpa.destroy(l);
    }
};

test "remote prefill refuses half its flags, other models and a drafter, by name" {
    try std.testing.expectEqual(@as(?[]const u8, null), refusal(.{}, false, true));
    try std.testing.expect(refusal(.{ .url = "http://gb10:8000" }, true, false) != null);
    try std.testing.expect(refusal(.{ .url = "http://gb10:8000", .link = "tf2b" }, false, false) != null);
    try std.testing.expect(refusal(.{ .url = "http://gb10:8000", .link = "tf2b" }, true, true) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), refusal(.{ .url = "http://gb10:8000", .link = "tf2b" }, true, false));
}
