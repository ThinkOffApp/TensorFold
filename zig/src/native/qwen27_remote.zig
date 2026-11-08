//! #1594 step 2b on the Mac: a prompt prefix the GB10 prefilled, pulled over an MKVH link into a blank Qwen27 state.
const std = @import("std");
const tf = @import("tensorfold");
const api = @import("engine_api");
const q = tf.qwen27;
const fabric = tf.fabric;
const ps = fabric.prefill_source;
const hs = fabric.hybrid_state;
const hx = fabric.hybrid_export;
const Filled = api.LaneHost.Remote.Filled;
const Flags = api.LaneHost.Remote.Flags;
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
    running: std.atomic.Value(u32) = .init(0), // the lane host's fill threads under way
    closing: std.atomic.Value(bool) = .init(false), // the server stops: waiting fills give up

    pub fn source(p: *Pull) api.LaneHost.Remote.Source {
        return .{ .ptr = p, .wants = wants, .fill = fill, .drop = drop, .running = &p.running };
    }

    /// A prefix of `prompt` beyond `cached` on a page-row boundary, filled remotely and landed whole.
    pub fn pull(p: *Pull, prompt: []const u32, cached: u64) !?Filled {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.closing.load(.acquire)) return null;
        const src = p.remote.source();
        const offer = src.offer(prompt, cached) orelse return null;
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

    fn wants(ptr: *anyopaque, len: u64, cached: u64) bool {
        const p: *Pull = @ptrCast(@alignCast(ptr));
        return !p.closing.load(.acquire) and !p.remote.client.poisoned and p.remote.policy.upto(len, cached) != null;
    }

    fn fill(ptr: *anyopaque, prompt: []const u32, cached: u64) anyerror!?Filled {
        const p: *Pull = @ptrCast(@alignCast(ptr));
        return p.pull(prompt, cached);
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

    /// After the lane host stopped: fills still under way end first (one mid-pull finishes it).
    pub fn stop(l: *Link, gpa: std.mem.Allocator) void {
        l.pull.closing.store(true, .release);
        while (l.pull.running.load(.acquire) > 0) std.Io.sleep(l.pull.io, .fromMilliseconds(1), .awake) catch {};
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
