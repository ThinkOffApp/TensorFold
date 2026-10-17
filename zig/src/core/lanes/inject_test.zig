//! Injected context on the fake target: one extend pass reads it, and each reply token is the target's after it.
const std = @import("std");
const Config = @import("config.zig").Config;
const Engine = @import("engine.zig").Engine;
const sm = @import("stream.zig");
const fake = @import("fake.zig");
const SuffixLookup = @import("proposer.zig").SuffixLookup;
const Sampling = @import("sampling.zig").Sampling;
const Row = @import("logprob.zig").Row;

const gpa = std.testing.allocator;

fn model() !Config {
    var costs: [16]@import("config.zig").Cost = undefined;
    for (&costs, 1..) |*c, w| c.* = .{ .width = @intCast(w), .ms = 5.0 + 0.8 * @as(f64, @floatFromInt(w)) };
    return Config.init(gpa, .{ .exact_width = 16, .gpu_tokens = true, .mtp = true, .speculate = true, .speculate_early = false, .drafts = 4, .window_costs = &costs, .mtp_step_ms = 0.5, .hidden_rows = true, .batch_rows = 32, .max_streams = 8, .draft_streams = true }, 16, 15);
}

const Case = struct {
    prompt: []const u32,
    max_new: u32 = 40,
    sampling: ?Sampling = null,
    drafts: bool = true,
    logprobs: ?u8 = null,
    think_budget: u32 = 0,
    room: u32 = 0,
    after: usize = 3, // reply tokens before the context goes in
    context: []const u32 = &.{},
    stop: ?sm.StopCheck = null,
};

const none = std.math.maxInt(usize);

const Out = struct {
    emitted: []u32,
    rows: []Row,
    at: usize = none, // where the context went in
    reason: sm.Reason = .none,

    fn deinit(o: Out) void {
        gpa.free(o.emitted);
        gpa.free(o.rows);
    }
};

var passes: usize = 0; // the last run's extend passes

/// The cases admitted together and stepped to their ends, each taking its context once its reply holds `after` tokens.
fn run(cases: []const Case) ![]Out {
    var cfg = try model();
    defer cfg.deinit(gpa);
    var target: fake.Fake = .{ .gpa = gpa };
    defer target.deinit();
    var clock: fake.FixedClock = .{};
    var engine = Engine.init(gpa, &cfg, target.backend(), clock.clock());
    defer engine.deinit();
    const streams = try gpa.alloc(sm.Stream, cases.len);
    defer gpa.free(streams);
    const proposers = try gpa.alloc(SuffixLookup, cases.len);
    defer gpa.free(proposers);
    const at = try gpa.alloc(usize, cases.len);
    defer gpa.free(at);
    @memset(at, none);
    for (cases, streams, proposers) |c, *s, *p| {
        p.* = try SuffixLookup.init(gpa, .{ .min_match = 4 });
        s.* = try sm.Stream.init(gpa, .{ .id = "s", .prompt = c.prompt, .max_new = c.max_new, .eos = &.{96}, .sampling = c.sampling, .drafts = c.drafts, .proposer = p.proposer(), .stop_check = c.stop, .think_budget = c.think_budget, .think_close = &.{ 90, 91, 92 }, .think_end = 91, .logprobs = c.logprobs, .room = c.room });
    }
    defer for (streams, proposers) |*s, *p| {
        s.deinit(gpa);
        p.deinit();
    };
    for (streams) |*s| try engine.addStream(s);
    while (engine.activeCount() > 0) {
        for (cases, streams, at) |c, *s, *x| if (c.context.len > 0 and x.* == none and !s.finished and s.emitted().len >= c.after) {
            try engine.settle(s); // as the lane host does before it injects
            if (s.finished) continue;
            x.* = s.emitted().len;
            try engine.extend(s, c.context);
        };
        try engine.step();
    }
    passes = target.extend_count;
    const out = try gpa.alloc(Out, cases.len);
    for (out, streams, at) |*o, *s, x| o.* = .{ .emitted = try gpa.dupe(u32, s.emitted()), .rows = try gpa.dupe(Row, s.rows.items), .at = x, .reason = s.reason };
    return out;
}

fn free(runs: []Out) void {
    for (runs) |o| o.deinit();
    gpa.free(runs);
}

/// Each reply token is the target's draw after the prompt and every token before it, the context read where it went in.
fn expectRead(c: Case, o: Out) !void {
    try std.testing.expect(o.at != none);
    try std.testing.expectEqualSlices(u32, c.context, o.emitted[o.at..][0..c.context.len]);
    var history: std.ArrayList(u32) = .empty;
    defer history.deinit(gpa);
    try history.appendSlice(gpa, c.prompt);
    for (o.emitted, 0..) |t, i| {
        const own = i < o.at or i >= o.at + c.context.len;
        if (own) try std.testing.expectEqual(fake.next(history.items, c.sampling, history.items.len), t);
        if (own and c.logprobs != null) {
            const want = fake.rowAt(history.items, fake.next(history.items, c.sampling, history.items.len), c.logprobs.?).forToken(t);
            try std.testing.expectEqual(@as(u32, @bitCast(want.logprob)), @as(u32, @bitCast(o.rows[i].logprob)));
        }
        try history.append(gpa, t);
    }
    // the reply's own tokens stay max_new: the room held the context's rows
    if (o.reason == .length) try std.testing.expectEqual(@as(usize, c.max_new), o.emitted.len - c.context.len);
}

const p1 = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
const p2 = [_]u32{ 2, 7, 1, 8, 2, 8, 1, 8, 2, 8, 4, 5, 9 };
const extra = [_]u32{ 93, 17, 94, 33, 95, 61 };

test "a reply reads injected context in place, drafted, plain and sampled, and keeps its own max_new" {
    for ([_]?Sampling{ null, .{ .seed = 5, .temperature = 0.7, .top_k = 0, .top_p = 0.95 } }) |sampling| {
        for ([_]bool{ true, false }) |drafts| {
            const c: Case = .{ .prompt = &p1, .sampling = sampling, .drafts = drafts, .room = 8, .context = &extra };
            const out = try run(&.{c});
            defer free(out);
            try expectRead(c, out[0]);
        }
    }
}

test "context wider than a window goes in as one pass" {
    var wide: [40]u32 = undefined;
    for (&wide, 0..) |*t, i| t.* = @intCast(10 + i);
    const c: Case = .{ .prompt = &p2, .max_new = 30, .room = 40, .after = 3, .context = &wide };
    const out = try run(&.{c});
    defer free(out);
    try expectRead(c, out[0]);
    try std.testing.expectEqual(@as(usize, 1), passes);
}

test "logprob rows stay one a token, the injected rows never the target's" {
    const c: Case = .{ .prompt = &p1, .logprobs = 2, .room = 8, .context = &extra };
    const out = try run(&.{c});
    defer free(out);
    try expectRead(c, out[0]);
    try std.testing.expectEqual(out[0].emitted.len, out[0].rows.len);
    for (out[0].rows[out[0].at..][0..extra.len]) |r| try std.testing.expect(std.math.isNan(r.logprob));
}

test "with room held and nothing injected, the reply is the reply without room" {
    const held = try run(&.{.{ .prompt = &p1, .room = 16 }});
    defer free(held);
    const plain = try run(&.{.{ .prompt = &p1 }});
    defer free(plain);
    try std.testing.expectEqualSlices(u32, plain[0].emitted, held[0].emitted);
    try std.testing.expectEqual(plain[0].reason, held[0].reason);
}

test "a shared round's other stream commits what it commits alone while one stream takes context" {
    const sampled: Sampling = .{ .seed = 9, .temperature = 1.0, .top_k = 0, .top_p = 0.9 };
    const c: Case = .{ .prompt = &p1, .room = 8, .context = &extra };
    const together = try run(&.{ c, .{ .prompt = &p2, .sampling = sampled, .max_new = 30 } });
    defer free(together);
    const alone = try run(&.{.{ .prompt = &p2, .sampling = sampled, .max_new = 30 }});
    defer free(alone);
    try expectRead(c, together[0]);
    try std.testing.expectEqualSlices(u32, alone[0].emitted, together[1].emitted);
}

test "the thinking budget counts the reply's own tokens, not injected ones" {
    const plain = try run(&.{.{ .prompt = &p2, .think_budget = 9 }});
    defer free(plain);
    const read = try run(&.{.{ .prompt = &p2, .think_budget = 9, .room = 8, .after = 3, .context = &extra }});
    defer free(read);
    const cut = std.mem.indexOfScalar(u32, plain[0].emitted, 90).?;
    try std.testing.expectEqual(@as(usize, 8), cut);
    try std.testing.expect(read[0].at < cut);
    try std.testing.expectEqual(cut + extra.len, std.mem.indexOfScalar(u32, read[0].emitted, 90).?);
}

test "stop strings are read in the reply after the last injection, never across the context" {
    const Hook = struct {
        fn check(_: *anyopaque, emitted: []const u32) bool {
            return std.mem.indexOf(u32, emitted, extra[0..3]) != null;
        }
    };
    var ctx: u8 = 0;
    const c: Case = .{ .prompt = &p1, .room = 8, .context = &extra };
    const hooked = try run(&.{.{ .prompt = &p1, .room = 8, .context = &extra, .stop = .{ .ptr = &ctx, .check = Hook.check } }});
    defer free(hooked);
    const unhooked = try run(&.{c});
    defer free(unhooked);
    try expectRead(c, hooked[0]);
    try std.testing.expectEqualSlices(u32, unhooked[0].emitted, hooked[0].emitted);
    try std.testing.expectEqual(unhooked[0].reason, hooked[0].reason);
}
