//! Promotion erasure keeps neuron addresses for retry while removing the text and its derived copies.
const std = @import("std");
const p = @import("promote.zig");
const Allocator = std.mem.Allocator;

pub const Scrubbed = struct {
    neurons: []const p.Neuron,
    pairs_reset: []const []const u8,

    pub fn deinit(s: Scrubbed, a: Allocator) void {
        a.free(s.neurons);
        for (s.pairs_reset) |key| a.free(key);
        a.free(s.pairs_reset);
    }
};

fn includes(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn affected(pair: p.Pair, keys: []const []const u8) bool {
    if (pair.keys.len == 0) return keys.len > 0;
    for (pair.keys) |key| if (includes(keys, key)) return true;
    return false;
}

/// Allocate the retry and disclosure lists before changing state; an unfinished night must settle first.
pub fn start(s: *p.State, a: Allocator, keys: []const []const u8) !Scrubbed {
    if (s.open != null) return error.NightOpen;
    var neurons: std.ArrayList(p.Neuron) = .empty;
    errdefer neurons.deinit(a);
    var pairs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (pairs.items) |key| a.free(key);
        pairs.deinit(a);
    }
    for (s.facts.items) |f| {
        if (includes(keys, f.key)) try neurons.appendSlice(a, f.neurons);
        const reset = if (f.pair) |pair| affected(pair, keys) else false;
        if (reset or (f.pair_reset_by.len > 0 and includes(keys, f.pair_reset_by))) {
            const key = try a.dupe(u8, f.key);
            errdefer a.free(key);
            try pairs.append(a, key);
        }
    }
    const addresses = try neurons.toOwnedSlice(a);
    errdefer a.free(addresses);
    const reset_keys = try pairs.toOwnedSlice(a);
    errdefer {
        for (reset_keys) |key| a.free(key);
        a.free(reset_keys);
    }
    const reset_by = if (keys.len > 0) try s.alloc().dupe(u8, keys[0]) else "";
    for (s.facts.items) |*f| {
        if (f.pair) |pair| {
            if (affected(pair, keys)) f.pair_reset_by = reset_by;
        }
        if (includes(keys, f.key)) {
            f.text = "";
            f.status = .freed;
            f.erased = true;
            f.alone = 0;
            f.retrieved = false;
            f.probes = &.{};
            f.ask = null;
            f.neighbours = &.{};
            f.pair = null;
            f.why = "erased on request";
        } else if (f.pair) |pair| if (affected(pair, keys)) {
            f.pair = null;
        };
    }
    if (keys.len > 0) for (s.nights.items) |*night| {
        night.worse_list = "";
    };
    return .{ .neurons = addresses, .pairs_reset = reset_keys };
}

/// Call only after the engine's retirement and save succeed; other facts keep their exact neurons.
pub fn finished(s: *p.State, keys: []const []const u8) !void {
    var retained: std.ArrayList(p.Neuron) = .empty;
    for (s.pocket) |n| {
        const retired = for (s.facts.items) |f| {
            if (includes(keys, f.key) and p.has(f.neurons, n)) break true;
        } else false;
        if (!retired) try retained.append(s.alloc(), n);
    }
    s.pocket = retained.items;
    for (s.facts.items) |*f| if (includes(keys, f.key)) {
        f.neurons = &.{};
    };
}

test "promotion erase scrubs every status and legacy partner copy before retiring only its own neurons" {
    const t = std.testing;
    const codec = @import("promote_json.zig");
    const secret = "My locker code is 7419.";
    const mine: p.Neuron = .{ .layer = 3, .neuron = 1, .key = .reply };
    const other: p.Neuron = .{ .layer = 3, .neuron = 9, .key = .reply };
    for (std.enums.values(p.Status)) |status| {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var s = p.State.init(t.allocator, .{});
        defer s.deinit();
        const pair: p.Pair = .{ .q = secret, .ref = secret, .text = secret };
        try s.facts.append(s.alloc(), .{
            .key = "w1",
            .text = secret,
            .status = status,
            .neurons = &.{mine},
            .pair = pair,
            .ask = .{ .q = secret, .ref = secret },
            .probes = &.{.{ .q = secret, .ref = secret }},
            .neighbours = &.{secret},
            .why = secret,
        });
        try s.facts.append(s.alloc(), .{
            .key = "w2",
            .text = "My umbrella is blue.",
            .status = .in_weights,
            .neurons = &.{other},
            .pair = pair,
        });
        try s.nights.append(s.alloc(), .{ .worse_list = secret });
        s.pocket = &.{ mine, other };
        const result = try start(&s, a, &.{"w1"});
        try t.expectEqualSlices(p.Neuron, &.{mine}, result.neurons);
        try t.expect(includes(result.pairs_reset, "w2"));
        const bytes = try codec.encode(&s, a);
        try t.expect(std.mem.indexOf(u8, bytes, "7419") == null);
        var loaded = try codec.decode(t.allocator, bytes, .{});
        defer loaded.deinit();
        try t.expect(loaded.find("w1").?.erased);
        try t.expectEqualSlices(p.Neuron, &.{mine}, loaded.find("w1").?.neurons);
        try finished(&loaded, &.{"w1"});
        try t.expectEqualSlices(p.Neuron, &.{other}, loaded.pocket);
        try t.expectEqualSlices(p.Neuron, &.{other}, loaded.find("w2").?.neurons);
        try t.expectEqualStrings("My umbrella is blue.", loaded.find("w2").?.text);
        const retry = try start(&loaded, a, &.{"w1"});
        try t.expectEqual(@as(usize, 0), retry.neurons.len);
        try t.expect(includes(retry.pairs_reset, "w2"));
    }
}

test "promotion erase uses pair provenance and preserves an unrelated pair through JSON" {
    const t = std.testing;
    const codec = @import("promote_json.zig");
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = p.State.init(t.allocator, .{});
    defer s.deinit();
    for ([_][]const u8{ "w2", "w4" }, 0..) |key, i| try s.facts.append(s.alloc(), .{
        .key = key,
        .text = "unrelated fact",
        .pair = .{
            .q = "pair question",
            .ref = "pair answer",
            .text = "pair text",
            .keys = if (i == 0) &.{ "w1", "w2" } else &.{ "w3", "w4" },
        },
    });
    var loaded = try codec.decode(t.allocator, try codec.encode(&s, a), .{});
    defer loaded.deinit();
    const result = try start(&loaded, a, &.{"w1"});
    try t.expectEqual(@as(usize, 1), result.pairs_reset.len);
    try t.expectEqualStrings("w2", result.pairs_reset[0]);
    try t.expect(loaded.find("w2").?.pair == null);
    try t.expect(loaded.find("w4").?.pair != null);
}

test "promotion erase waits for an open night and stages allocations before changing facts" {
    const t = std.testing;
    var s = p.State.init(t.allocator, .{});
    defer s.deinit();
    try s.facts.append(s.alloc(), .{ .key = "w1", .text = "private", .neurons = &.{.{ .layer = 1, .neuron = 2, .key = .reply }} });
    s.open = .{ .night = 1, .teaching = "private" };
    try t.expectError(error.NightOpen, start(&s, t.allocator, &.{"w1"}));
    s.open = null;
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, start(&s, failing.allocator(), &.{"w1"}));
    try t.expectEqualStrings("private", s.find("w1").?.text);
    try t.expect(!s.find("w1").?.erased);
}

test "promotion erase disclosure owns its keys independently of the state being compacted" {
    const t = std.testing;
    var s = p.State.init(t.allocator, .{});
    defer s.deinit();
    const key = try s.alloc().dupe(u8, "w2");
    try s.facts.append(s.alloc(), .{
        .key = key,
        .text = "control",
        .pair = .{ .q = "pair", .ref = "pair", .text = "pair" },
    });
    const result = try start(&s, t.allocator, &.{"w1"});
    defer result.deinit(t.allocator);
    key[1] = '9';
    try t.expectEqualStrings("w2", result.pairs_reset[0]);
}
