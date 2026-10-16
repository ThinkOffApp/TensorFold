//! The suffix-array index (--notes-index sa): LLWZ Python's answers, and its n-grams and notes equal the postings'.
const std = @import("std");
const server = @import("root.zig");
const notes_route = @import("notes_route.zig");
const index = @import("notes/index.zig");
const sa = @import("notes/sa.zig");
const model_mod = @import("notes/model.zig");
const notes_test = @import("notes_test.zig");
const Bytes = notes_test.Bytes;
const testing = std.testing;
const Allocator = std.mem.Allocator;

fn openSa(text: server.model_text.Text, bytes: []const u8) !*notes_route.Store {
    var why: []const u8 = "";
    return notes_route.Store.loadIndexed(testing.allocator, testing.io, bytes, text, .sa, &why);
}

test "the suffix-array index gives LLWZ Python's ids, tokens, candidates and block for every fixture case" {
    var text: Bytes = .{};
    const store = try openSa(text.text(), notes_test.snapshot);
    defer store.deinit();
    try testing.expect(store.current.idx.base != null);
    var answered: usize = 0;
    try testing.expectEqual(@as(usize, 0), try notes_test.differing(store, text.text(), &answered));
    try testing.expect(answered >= 60);
}

test "negative control: the suffix-array index with the hop off answers otherwise than Python" {
    var text: Bytes = .{};
    const broken = try std.mem.replaceOwned(u8, testing.allocator, notes_test.snapshot, "\"hop\":\"subject\"", "\"hop\":\"none\"");
    defer testing.allocator.free(broken);
    const store = try openSa(text.text(), broken);
    defer store.deinit();
    var answered: usize = 0;
    try testing.expect(try notes_test.differing(store, text.text(), &answered) > 0);
}

/// One view's notes holding `g` by the suffix array (each once, by place), against the postings' list.
fn notesOf(a: Allocator, b: *const sa.Base, arr: sa.Packed, g: index.Gram, punct: bool) ![]u32 {
    var keys: [index.max_n]u32 = undefined;
    var len: usize = 0;
    while (len < index.max_n) : (len += 1) {
        keys[len] = @truncate(g >> @intCast(32 * len));
        if (keys[len] == index.none_key) break;
    }
    var out: std.ArrayList(u32) = .empty;
    var buf: [index.max_n]u32 = undefined;
    const pat = b.codes(keys[0..len], &buf) orelse return out.items;
    if (len == 1 and !punct and !b.wordyCode(pat[0])) return out.items;
    const r = b.range(arr, pat);
    for (r[0]..r[1]) |k| {
        const p = b.placeOf(arr.get(k));
        if (std.mem.indexOfScalar(u32, out.items, p) == null) try out.append(a, p);
    }
    std.sort.pdq(u32, out.items, {}, std.sort.asc(u32));
    return out.items;
}

/// Every n-gram of the postings index: the suffix array's notes in each view are its postings exactly.
fn sameAsPostings(a: Allocator, post: *const index.Index, sx: *const index.Index) !usize {
    const b = sx.base.?;
    var bad: usize = 0;
    var it = post.grams.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr.*;
        const views = [2][]const u32{ post.post[p.cur_off..][0..p.cur_len], post.post[p.hist_off..][0..p.hist_len] };
        for (views, [2]sa.Packed{ b.sa_cur, b.sa_hist }) |want, arr| {
            const sorted = try a.dupe(u32, want);
            std.sort.pdq(u32, sorted, {}, std.sort.asc(u32));
            if (!std.mem.eql(u32, sorted, try notesOf(a, b, arr, kv.key_ptr.*, post.settings.punct))) bad += 1;
        }
    }
    return bad;
}

test "every n-gram's notes by the suffix array are its postings, view by view, and the distinct n-grams the snapshot's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try model_mod.parse(testing.allocator, notes_test.snapshot);
    defer m.deinit();
    const post = try index.Index.build(testing.allocator, m);
    defer post.deinit();
    const sx = try index.Index.buildKind(testing.allocator, m, .sa);
    defer sx.deinit();
    try testing.expect(post.grams.count() > 100);
    try testing.expectEqual(@as(usize, 0), try sameAsPostings(a, post, sx));
    const b = sx.base.?;
    const Keep = struct {
        fn wordy(idx: *const index.Index, key: u32) bool {
            for (idx.vkey, 0..) |k, t| if (k == key) return idx.vwordy[t];
            return false;
        }
    };
    try testing.expectEqual(@as(usize, m.grams_current), sa.distinctGrams(b, b.sa_cur, 1, 3, sx, Keep.wordy));
    try testing.expectEqual(@as(usize, m.grams_history), sa.distinctGrams(b, b.sa_hist, 1, 3, sx, Keep.wordy));
    // negative control: the 1-gram rule off (punctuation alone counted) gives more n-grams than the snapshot's
    const All = struct {
        fn any(_: *const index.Index, _: u32) bool {
            return true;
        }
    };
    try testing.expect(sa.distinctGrams(b, b.sa_cur, 1, 3, sx, All.any) > m.grams_current);
}

test "a note holding an n-gram twice counts once in its document frequency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try model_mod.parse(testing.allocator, notes_test.snapshot);
    defer m.deinit();
    const post = try index.Index.build(testing.allocator, m);
    defer post.deinit();
    const sx = try index.Index.buildKind(testing.allocator, m, .sa);
    defer sx.deinit();
    const b = sx.base.?;
    // the n-grams some current note holds more than once: their ranges are longer than their notes
    var twice: usize = 0;
    var it = post.grams.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr.*;
        if (p.cur_len == 0) continue;
        var keys: [index.max_n]u32 = undefined;
        var len: usize = 0;
        while (len < index.max_n) : (len += 1) {
            keys[len] = @truncate(kv.key_ptr.* >> @intCast(32 * len));
            if (keys[len] == index.none_key) break;
        }
        var buf: [index.max_n]u32 = undefined;
        const r = b.range(b.sa_cur, b.codes(keys[0..len], &buf).?);
        if (r[1] - r[0] > p.cur_len) {
            twice += 1;
            try testing.expectEqual(@as(usize, p.cur_len), (try notesOf(a, b, b.sa_cur, kv.key_ptr.*, false)).len);
        }
    }
    try testing.expect(twice > 10);
    // and the lookup counts notes: the fixture's answers above hold with these n-grams in the questions
    var text: Bytes = .{};
    const store = try openSa(text.text(), notes_test.snapshot);
    defer store.deinit();
    const got = try store.retrieve(a, text.text(), try text.text().encode(a, "My dog Luna and my cat: my my my.", false), false, 512, &.{});
    const want = blk: {
        const ps = try notes_route.Store.load(testing.allocator, testing.io, notes_test.snapshot, text.text(), @constCast(&@as([]const u8, "")));
        defer ps.deinit();
        const f = try ps.retrieve(a, text.text(), try text.text().encode(a, "My dog Luna and my cat: my my my.", false), false, 512, &.{});
        break :blk f;
    };
    try testing.expectEqualSlices(u32, want.ids, got.ids);
    try testing.expectEqualStrings(want.block, got.block);
}

test "a vocabulary the suffix array cannot match as the postings do is refused" {
    var text: Bytes = .{};
    // byte 'a' made a punctuation id of the same key as 'A': one key's ids disagree on being a word
    const s = notes_test.snapshot;
    const at = std.mem.indexOf(u8, s, "\"wordy\":\"").? + "\"wordy\":\"".len;
    const bad = try testing.allocator.dupe(u8, s);
    defer testing.allocator.free(bad);
    try testing.expect(bad[at + 'a'] == '1');
    bad[at + 'a'] = '0';
    try testing.expectError(error.Unsupported, openSa(text.text(), bad));
    // the postings index takes it
    var why: []const u8 = "";
    const ok = try notes_route.Store.load(testing.allocator, testing.io, bad, text.text(), &why);
    ok.deinit();
}
