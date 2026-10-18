//! A version layered on a core reads as the full build of the same notes, accessor by accessor, after every write.
const std = @import("std");
const rig = @import("notes_rig_test.zig");
const ops = @import("notes_ops.zig");
const index = @import("notes/index.zig");
const merge = @import("notes/merge.zig");
const testing = std.testing;
const Index = index.Index;
const layer = @import("notes/layer.zig");
const model = @import("notes/model.zig");

fn oneWriteVersionBytes(n: usize) !usize {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try rig.Rig.initKind(testing.allocator, .sa, 1024);
    defer r.deinit();
    var m = r.store().model.*;
    const notes = try arena.allocator().alloc(model.Note, n + 1);
    for (notes, 0..) |*note, k| {
        note.* = m.notes.items[1];
        note.id = @intCast(k + 1);
        note.told = @intCast(k + 1);
        note.state = .current;
    }
    m.notes = .fromOwnedSlice(notes[0..n]);
    const core = try Index.buildKind(testing.allocator, &m, .sa);
    defer core.deinit();
    m.notes = .fromOwnedSlice(notes);
    const version = (try layer.build(testing.allocator, &m, core, &.{})).?;
    defer version.deinit();
    try testing.expectEqual(@as(usize, n + 1), version.notes());
    try testing.expectEqual(index.State.current, version.stateAt(@intCast(n)));
    return version.arena.bytes();
}

test "one-write version allocation stays within its budget when the unchanged core grows" {
    const small = try oneWriteVersionBytes(128);
    const large = try oneWriteVersionBytes(8192);
    try testing.expect(large <= small + 1024);
}

fn list(a: std.mem.Allocator, it0: index.Iter) ![]u32 {
    var it = it0;
    var out: std.ArrayList(u32) = .empty;
    while (it.next()) |p| try out.append(a, p);
    return out.items;
}

/// Every accessor of `got` (layered) against `want` (a full build of the same model); the differences counted.
fn differences(a: std.mem.Allocator, got: *const Index, want: *const Index, m: anytype) !usize {
    var bad: usize = 0;
    const n: u32 = @intCast(want.notes());
    if (got.notes() != want.notes() or got.n_cur != want.n_cur or got.n_hist != want.n_hist) bad += 1;
    if (got.min_line > want.min_line) bad += 1; // a lower bound is enough for pack()'s early stop
    for (0..n) |k| {
        const p: u32 = @intCast(k);
        bad += @intFromBool(got.idAt(p) != want.idAt(p));
        bad += @intFromBool(got.stateAt(p) != want.stateAt(p));
        bad += @intFromBool(got.toldAt(p) != want.toldAt(p));
        bad += @intFromBool(got.rankAt(p) != want.rankAt(p));
        bad += @intFromBool(got.entityAt(p) != want.entityAt(p));
        bad += @intFromBool(got.pairAt(p) != want.pairAt(p));
        bad += @intFromBool(got.valueEntityAt(p) != want.valueEntityAt(p));
        bad += @intFromBool(got.costAt(p) != want.costAt(p));
        bad += @intFromBool(!std.mem.eql(u8, got.lineAt(p), want.lineAt(p)));
        bad += @intFromBool(got.placeOfId(want.idAt(p)) != p);
    }
    bad += @intFromBool(got.placeOfId(want.idAt(n - 1) + 1) != null);
    for (0..m.entities.items.len) |k| {
        const e: u32 = @intCast(k);
        bad += @intFromBool(!std.mem.eql(u32, try list(a, got.entCur(e)), try list(a, want.entCur(e))));
        bad += @intFromBool(!std.mem.eql(u32, try list(a, got.entKeys(e)), try list(a, want.entKeys(e))));
    }
    for (0..m.pairs.items.len) |k| bad += @intFromBool(!std.mem.eql(u32, try list(a, got.pairNotes(@intCast(k))), try list(a, want.pairNotes(@intCast(k)))));
    for (m.phrases.items) |ph| {
        if (ph.keys.len == 1) bad += @intFromBool(got.nameOf(ph.keys[0]) != want.nameOf(ph.keys[0]));
        if (ph.keys.len >= 2 and ph.keys.len <= index.max_phrase) bad += @intFromBool(got.phraseOf(index.packPhrase(ph.keys)) != want.phraseOf(index.packPhrase(ph.keys)));
    }
    bad += @intFromBool(got.phraseMax() != want.phraseMax() or (got.phraseCount() == 0) != (want.phraseCount() == 0));
    return bad;
}

fn write(r: *rig.Rig, a: std.mem.Allocator, ask: ops.Ask) !void {
    var why: ops.Refusal = .{};
    _ = try ops.perform(r.store(), a, ask, &why);
}

test "a layered version equals the full build of its notes after every write: retired core notes, new names, ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.initKind(testing.allocator, .sa, 1024);
    defer r.deinit();
    const s = r.store();
    // written notes that name people who are no subject yet, then merged into the core
    try write(r, a, .{ .op = .add, .text = "My sister is Anna." });
    try write(r, a, .{ .op = .add, .text = "My neighbour is Otto Berg." });
    try s.merge();
    try testing.expect(s.current.idx.layer.core == null);
    const core_first = for (s.model.notes.items) |*n| { // the core's first current fact
        if (n.state == .current and n.kind == .fact) break n.id;
    } else unreachable;
    var layered: usize = 0;
    const steps = [_]ops.Ask{
        .{ .op = .add, .text = "Anna drives a red Volvo.", .subject = "Anna" }, // a name a core note holds
        .{ .op = .add, .text = "Otto Berg plays the cello.", .subject = "Otto Berg" }, // a two-key name
        .{ .op = .change, .text = "My favourite colour is blue now.", .target = core_first }, // a core note retired
        .{ .op = .add, .text = "My brother is Anna's friend." },
        .{ .op = .take_back, .text = "I take that back.", .target = 0 }, // the note just written (set below)
        .{ .op = .add, .text = "Anna lives in Oslo.", .subject = "Anna" },
    };
    for (steps) |st0| {
        var st = st0;
        if (st.op == .take_back) st.target = s.model.notes.items[s.model.notes.items.len - 1].id;
        try write(r, a, st);
        const v = s.acquire();
        defer s.release(v);
        const full = try Index.buildKind(testing.allocator, s.model, .sa);
        defer full.deinit();
        layered += @intFromBool(v.idx.layer.core != null);
        try testing.expectEqual(@as(usize, 0), try differences(a, v.idx, full, s.model));
    }
    try testing.expectEqual(steps.len, layered); // every version after the merge was a layered one
    try testing.expect(s.current.idx.layer.lazy_values); // core notes' named entities resolve by the new names
    try testing.expect(s.current.idx.layer.over.count() > 0); // and a core note retired
}

/// The current version against a full build of the store's notes.
fn sameAsFull(s: anytype, a: std.mem.Allocator) !void {
    const v = s.acquire();
    defer s.release(v);
    const full = try Index.buildKind(testing.allocator, s.model, .sa);
    defer full.deinit();
    try testing.expectEqual(@as(usize, 0), try differences(a, v.idx, full, s.model));
}

test "a merge on its own thread: writes and retirements during it, then a version on its core equal to a full build" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.initWith(testing.allocator, .{ .kind = .sa, .side_max = 2 });
    defer r.deinit();
    const s = r.store();
    merge.hold.store(true, .release);
    defer merge.hold.store(false, .release);
    for ([_][]const u8{ "My sister is Anna.", "I like tea.", "My dog is Rex." }) |t| try write(r, a, .{ .op = .add, .text = t });
    try testing.expect(s.bw.merging != null); // three notes past the core: the merge began, and waits
    const core_fact = for (s.model.notes.items) |*n| {
        if (n.state == .current and n.kind == .fact) break n.id;
    } else unreachable;
    // during the merge: a note of the frozen copy retired, a new name, a note past the copy
    try write(r, a, .{ .op = .change, .text = "My favourite colour is blue now.", .target = core_fact });
    try write(r, a, .{ .op = .add, .text = "Anna drives a red Volvo.", .subject = "Anna" });
    try sameAsFull(s, a);
    const merges = s.merges;
    merge.hold.store(false, .release);
    while (!s.bw.merging.?.ready()) std.atomic.spinLoopHint();
    try write(r, a, .{ .op = .add, .text = "Anna lives in Oslo.", .subject = "Anna" }); // its version is on the new core
    try testing.expectEqual(merges + 1, s.merges);
    try testing.expect(s.bw.pending == null and s.current.idx.layer.core != null);
    try testing.expectEqual(@as(usize, 3), s.current.idx.layer.core.?.notes() - 29); // the core: the copy's notes
    try sameAsFull(s, a);
}
