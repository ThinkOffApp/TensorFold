//! Differential: after every step of random writes, take-backs, erases, merges and restarts, every fixture question
//! answers on the store's version (a core plus a delta, merged on a thread or in the write) exactly as on a full
//! build of the same notes by the old path (every note copied, the tie rank by a global sort, aliases from nothing).
//! Versions held across a step answer as the oracle did before it.
const std = @import("std");
const rig = @import("notes_rig_test.zig");
const ops = @import("notes_ops.zig");
const index = @import("notes/index.zig");
const lookup = @import("notes/lookup.zig");
const alias = @import("notes/alias.zig");
const layer = @import("notes/layer.zig");
const json = @import("json.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const cases_json = @embedFile("notes/testdata/l6_bytes_cases.json");

const Q = struct { ids: []const u32, past: bool, cap: u32, exclude: []const u32 };

fn questions(a: Allocator, r: *rig.Rig) ![]Q {
    const s = r.store();
    const cases = (try json.parse(a, cases_json)).ok;
    var out: std.ArrayList(Q) = .empty;
    for (cases.array) |c| {
        var ex: std.ArrayList(u32) = .empty;
        for (c.get("exclude").?.array) |x| try ex.append(a, @intCast(x.int64().?));
        const cap: u32 = if (c.field("cap")) |x| @intCast(x.int64().?) else s.settings().cap;
        try out.append(a, .{ .ids = try s.text.encode(a, c.strField("question").?, false), .past = c.get("past_read").?.bool, .cap = cap, .exclude = ex.items });
    }
    // questions about what the writes below add: their subjects, names and the aliases they make
    for ([_][]const u8{ "What colour is my item 3?", "Who drives a Volvo?", "Where does Nora live?", "What is my cousin's name?", "Tell me about Ana.", "What does Otto Berg play?" }) |q| {
        for ([_]bool{ false, true }) |p| try out.append(a, .{ .ids = try s.text.encode(a, q, false), .past = p, .cap = 512, .exclude = &.{} });
    }
    return out.items;
}

/// One digest per question and lookup kind (subjects resolved or not): the chosen notes' ids, the block, its count.
fn answers(a: Allocator, idx: *const index.Index, qs: []const Q) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    for ([_]bool{ false, true }) |resolve| {
        var view = idx.*;
        view.settings.resolve_subjects = resolve;
        var sc = try lookup.Scratch.init(testing.allocator, &view);
        defer sc.deinit();
        for (qs) |q| {
            const got = try lookup.lookup(&view, &sc, q.ids, q.past, q.cap, q.exclude, .{});
            const shown = try lookup.render(&view, &sc, got.chosen);
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&got.tokens));
            h.update(std.mem.asBytes(&got.candidates));
            h.update(std.mem.sliceAsBytes(shown.ids));
            h.update(shown.block);
            try out.append(a, h.final());
        }
    }
    return out.items;
}

/// The alias tables of `got` (read through its accessors: a layered version's overrides, then its core's)
/// against `want`'s: every key either names, in both, the same entity and candidates, or names nothing in both.
fn aliasDiff(got: *const index.Index, want: *const index.Index) usize {
    var bad: usize = @intFromBool(got.aliasMax() < want.alias_max);
    var it = want.aliases.iterator();
    while (it.next()) |kv| bad += @intFromBool(got.aliasOf(kv.key_ptr.*) != kv.value_ptr.*);
    var ie = want.alias_entities.iterator();
    while (ie.next()) |kv| {
        const g = got.aliasCandidates(kv.key_ptr.*) orelse {
            bad += 1;
            continue;
        };
        bad += @intFromBool(!std.mem.eql(u32, g, kv.value_ptr.items));
    }
    // and nothing more: every key got's tables hold names nothing that want's do not
    for ([2]?*const index.Index{ got, got.layer.core }) |x| if (x) |t| {
        var kt = t.aliases.keyIterator();
        while (kt.next()) |k| {
            if (got.aliasOf(k.*) != null and want.aliases.get(k.*) == null) bad += 1;
            if (got.aliasCandidates(k.*) != null and want.alias_entities.get(k.*) == null) bad += 1;
        }
        var ke = t.alias_entities.keyIterator();
        while (ke.next()) |k| if (got.aliasCandidates(k.*) != null and want.alias_entities.get(k.*) == null) {
            bad += 1;
        };
    };
    return bad;
}

/// The old path's answers on the store's notes now (and its alias tables against the current version's, in `bad`).
fn oracleChecked(a: Allocator, r: *rig.Rig, qs: []const Q, bad: *usize) ![]u64 {
    const s = r.store();
    index.rank_by_note_allowed = false;
    defer index.rank_by_note_allowed = true;
    const full = try index.Index.buildKind(testing.allocator, s.model, .sa);
    defer full.deinit();
    try alias.populate(full, s.model, s.text);
    const v = s.acquire();
    defer s.release(v);
    bad.* += aliasDiff(v.idx, full);
    // Check immutable take-back metadata through both full and layered paths
    // after every write, erase, background merge and restart.
    for (s.model.notes.items) |n| {
        const want = n.kind == .tombstone and !n.multi;
        const got_place = v.idx.placeOfId(n.id).?;
        const full_place = full.placeOfId(n.id).?;
        bad.* += @intFromBool(v.idx.singleTakebackAt(got_place) != want);
        bad.* += @intFromBool(full.singleTakebackAt(full_place) != want);
    }
    return answers(a, full, qs);
}

/// The old path's answers on the store's notes now.
fn oracle(a: Allocator, r: *rig.Rig, qs: []const Q) ![]u64 {
    const s = r.store();
    index.rank_by_note_allowed = false;
    defer index.rank_by_note_allowed = true;
    const full = try index.Index.buildKind(testing.allocator, s.model, .sa);
    defer full.deinit();
    try testing.expect(!full.rank_by_note);
    try alias.populate(full, s.model, s.text);
    return answers(a, full, qs);
}

fn countDiff(x: []const u64, y: []const u64) usize {
    var bad: usize = @intFromBool(x.len != y.len);
    for (x[0..@min(x.len, y.len)], y[0..@min(x.len, y.len)]) |p, q| bad += @intFromBool(p != q);
    return bad;
}

/// A step's reply: a refusal (a take-back of a take-back, a change nothing allows) is a step that changed nothing.
fn took(r: anytype) !void {
    _ = r catch |e| switch (e) {
        error.Refused => return,
        else => return e,
    };
}

const names = [_][]const u8{ "Ana", "Bruno", "Milo", "Otto", "Nora", "Anna", "Otto Berg" };

/// A random step on the store (`pick` below 80: a write; 80 to 87 an erase; 88 to 94 a merge; else a restart).
fn step(r: *rig.Rig, a: Allocator, rnd: std.Random, k: usize, pick: u32) !void {
    const s = r.store();
    var why: ops.Refusal = .{};
    const m = s.model;
    const written = m.notes.items.len - m.base_notes;
    if (pick < 40) {
        const name = names[rnd.uintLessThan(usize, names.len)];
        const t: ops.Ask = switch (rnd.uintLessThan(u8, 6)) {
            0 => .{ .op = .add, .text = try std.fmt.allocPrint(a, "My item {d} is red.", .{k % 7}), .subject = try std.fmt.allocPrint(a, "my item {d}", .{k % 7}) },
            1 => .{ .op = .add, .text = try std.fmt.allocPrint(a, "My cousin's name is {s}.", .{name}) },
            2 => .{ .op = .add, .text = try std.fmt.allocPrint(a, "{s} drives a red Volvo.", .{name}), .subject = name },
            3 => .{ .op = .add, .text = try std.fmt.allocPrint(a, "{s} lives in Oslo.", .{name}), .subject = name },
            4 => .{ .op = .add, .text = "Otto Berg plays the cello.", .subject = "Otto Berg" },
            else => .{ .op = .add, .text = try std.fmt.allocPrint(a, "My neighbour {d} is {s}.", .{ k % 5, name }) },
        };
        try took(ops.perform(s, a, t, &why));
    } else if (pick < 65) { // a change of a current note, a snapshot's or a written one
        var tries: usize = 0;
        while (tries < 20) : (tries += 1) {
            const n = m.notes.items[rnd.uintLessThan(usize, m.notes.items.len)];
            if (n.state != .current or n.kind != .fact) continue;
            if (tries < 10 and !std.mem.eql(u8, m.attributes.items[n.attribute], "name")) continue; // name facts first
            const name = names[k % names.len];
            // a name fact's change names its subject again: an alias moves (or turns ambiguous)
            const text = if (std.mem.eql(u8, m.attributes.items[n.attribute], "name"))
                try std.fmt.allocPrint(a, "{s}'s name is {s}.", .{ m.entities.items[n.entity], name })
            else
                try std.fmt.allocPrint(a, "My favourite colour is {s} now.", .{name});
            if (text[0] >= 'a' and text[0] <= 'z') text[0] -= 32;
            try took(ops.perform(s, a, .{ .op = .change, .text = text, .target = n.id }, &why));
            break;
        }
    } else if (pick < 80) {
        var tries: usize = 0;
        while (tries < 20) : (tries += 1) {
            const n = m.notes.items[rnd.uintLessThan(usize, m.notes.items.len)];
            if (n.state != .current) continue;
            try took(ops.perform(s, a, .{ .op = .take_back, .text = "I take that back.", .target = n.id }, &why));
            break;
        }
    } else if (pick < 88) {
        if (written > 0) {
            const n = m.notes.items[m.base_notes + rnd.uintLessThan(usize, written)];
            try took(ops.erase(s, a, n.id, &why));
        }
    } else if (pick < 95) {
        try s.merge();
    } else {
        try r.restart();
    }
}

fn run(k: rig.Kind, seed: u64, steps: usize) !usize {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.initWith(testing.allocator, k);
    defer r.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const qs = try questions(a, r);
    var bad: usize = 0;
    var before = try oracle(a, r, qs);
    for (0..steps) |i| {
        const pick = prng.random().uintLessThan(u32, 100);
        var held_bad: usize = 0;
        if (pick >= 80 and pick < 88 or pick >= 95) { // an erase waits for every reader; a restart drops them all
            try step(r, a, prng.random(), i, pick);
        } else {
            const held = r.store().acquire(); // a reader across the step
            step(r, a, prng.random(), i, pick) catch |e| {
                r.store().release(held);
                return e;
            };
            if (r.store().current != held) held_bad = countDiff(try answers(a, held.idx, qs), before);
            r.store().release(held);
        }
        const v = r.store().acquire();
        const got = try answers(a, v.idx, qs);
        r.store().release(v);
        const want = try oracleChecked(a, r, qs, &bad);
        bad += countDiff(got, want) + held_bad;
        before = want;
    }
    return bad;
}

test "differential: every lookup on a layered version equals the full rebuild's, random writes, erases, merges" {
    const kinds = [_]rig.Kind{
        .{ .kind = .sa, .side_max = 2 }, // merges on a thread
        .{ .kind = .sa, .side_max = 2, .background = false }, // merges in the write
        .{ .kind = .sa, .side_max = 0 }, // a merge after every write
        .{ .kind = .sa, .side_max = 64 }, // a long delta: no merge for most of the run
    };
    for (kinds, 0..) |k, i| for (0..3) |seed| {
        const bad = try run(k, 1000 * i + seed, 40);
        if (bad != 0) std.debug.print("kind {d} seed {d}: {d} answers differ\n", .{ i, seed, bad });
        try testing.expectEqual(@as(usize, 0), bad);
    };
}

test "negative control: a delta that skips its group additions differs from the full rebuild" {
    layer.plant_skip_side_cur = true;
    defer layer.plant_skip_side_cur = false;
    var bad: usize = 0;
    for (0..3) |seed| bad += try run(.{ .kind = .sa, .side_max = 64 }, 77 + seed, 30);
    try testing.expect(bad > 0);
}

test "negative control: a stale alias table differs from the full rebuild" {
    alias.plant_stale = true;
    defer alias.plant_stale = false;
    var bad: usize = 0;
    for (0..3) |seed| bad += try run(.{ .kind = .sa, .side_max = 64 }, 91 + seed, 30);
    try testing.expect(bad > 0);
}
