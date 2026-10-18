//! Store.forgetSpan: kept states and learned states on disk that hold an erased note's tokens go; the rest stay.
//! Each test first shows the planted copy is there (the check can fail), then that the forget took it and only it.
const std = @import("std");
const pc = @import("prompt_cache.zig");
const imprint = @import("prompt_imprint.zig");
const rmTree = @import("prompt_imprint_test.zig").rmTree;
const Fake = @import("prompt_cache_fake.zig").Fake;
const fresh = @import("prompt_cache_test.zig").fresh;
const Store = pc.Store;
const testing = std.testing;

const note = [_]u32{ 50, 51, 52, 53 }; // the erased note's tokens
const system = [_]u32{ 1, 2, 3 };
const with_note = system ++ note ++ [_]u32{ 9, 9, 4 }; // a block holding the note after the client's system prompt
const without = system ++ [_]u32{ 60, 61, 62, 63 } ++ [_]u32{ 9, 9, 4 }; // an unrelated block

/// Whether any kept state's tokens or last prompt still hold `span`.
fn holds(s: *const Store, span: []const u32) bool {
    for (s.entries.items) |e| if (std.mem.indexOf(u32, e.tokens, span) != null or std.mem.indexOf(u32, e.last, span) != null) return true;
    return false;
}

fn keptAt(s: *const Store, prompt: []const u32, at: u32) bool {
    for (s.entries.items) |e| if (e.at == at and std.mem.eql(u32, e.tokens, prompt[0..e.tokens.len])) return true;
    return false;
}

test "forgetSpan drops the kept state holding the note, keeps the state before it and an unrelated conversation's" {
    const gpa = testing.allocator;
    var f: Fake = .{ .gpa = gpa };
    var s = Store.init(gpa, f.snapshots(), .{ .min_gap = 1, .min_prompt = 0 }, 1 << 20);
    defer s.deinit();
    // the note's conversation keeps a state before its block (3) and one past it (9); the other keeps one past its own (9)
    _ = f.pass(&s, &with_note, .{ .marks = &.{ 3, 9 } });
    _ = f.pass(&s, &without, .{ .marks = &.{9} });
    try testing.expectEqual(@as(usize, 3), s.entries.items.len);
    try testing.expect(holds(&s, &note)); // the planted copy is there: the checks below can fail
    try testing.expectEqual(@as(usize, 9), s.find(&with_note, &.{}, &.{}).?.at);
    const live = f.live;

    const out = s.forgetSpan(&note, &.{});
    try testing.expectEqual(@as(u32, 1), out.states); // the state past the block
    try testing.expectEqual(@as(u32, 1), out.scrubbed); // the state before it: its last prompt held the note
    try testing.expect(out.complete());
    try testing.expect(!holds(&s, &note));
    try testing.expectEqual(live - 1, f.live); // dropped through the family: its storage freed
    try testing.expectEqual(@as(usize, 2), s.entries.items.len);
    // the note's conversation resumes at most at its block's start; the unrelated one where it did
    try testing.expectEqual(@as(usize, 3), s.find(&with_note, &.{}, &.{}).?.at);
    try testing.expect(keptAt(&s, &without, 9));
    try testing.expectEqual(@as(usize, 9), s.find(&without, &.{}, &.{}).?.at);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const next = without ++ [_]u32{ 5, 5 };
    const plan = try s.begin(arena.allocator(), &next, @intCast(next.len - 1), &.{}, &.{}, null, &.{});
    try testing.expectEqual(@as(u32, 9), plan.from);
    try testing.expectEqual(fresh(&next), f.pass(&s, &next, plan)); // what it resumed is still right
    // a second forget finds nothing more
    try testing.expectEqual(pc.Forgotten{}, s.forgetSpan(&note, &.{}));
}

test "forgetSpan leaves a state a prompt pass is restoring, counted, and takes it on the next call; an empty span takes nothing" {
    const gpa = testing.allocator;
    var f: Fake = .{ .gpa = gpa };
    var s = Store.init(gpa, f.snapshots(), .{ .min_gap = 1, .min_prompt = 0 }, 1 << 20);
    defer s.deinit();
    _ = f.pass(&s, &with_note, .{ .marks = &.{9} });
    try testing.expectEqual(pc.Forgotten{}, s.forgetSpan(&.{}, &.{}));
    try testing.expect(holds(&s, &note));
    const e = s.entries.items[0];
    const out = s.forgetSpan(&note, &.{e});
    try testing.expectEqual(@as(u32, 1), out.held);
    try testing.expect(!out.complete());
    try testing.expect(holds(&s, &note));
    try testing.expectEqual(@as(u32, 1), s.forgetSpan(&note, &.{}).states);
    try testing.expect(!holds(&s, &note));
}

/// Whether the file at `dir`/`name` holds `span`'s bytes.
fn fileHolds(dir: []const u8, name: []const u8, span: []const u32) !bool {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var bytes: [1 << 16]u8 = undefined;
    var n: usize = 0;
    while (n < bytes.len) {
        const got = std.c.read(fd, bytes[n..].ptr, bytes.len - n);
        if (got <= 0) break;
        n += @intCast(got);
    }
    return std.mem.indexOf(u8, bytes[0..n], std.mem.sliceAsBytes(span)) != null;
}

fn exists(dir: []const u8, key: u64) bool {
    var buf: [512]u8 = undefined;
    const path = Fake.file(&buf, dir, key) catch return false;
    return std.c.access(path, std.c.F_OK) == 0;
}

test "forgetSpan removes learned states on disk that hold the note, also ones an earlier server learned, and keeps the rest" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/tf-learn-forget-{d}", .{std.c.getpid()});
    defer rmTree(root);
    const rules: pc.Rules = .{ .lookahead = 1, .min_prompt = 0, .min_gap = 1 };
    const tainted = [_]u32{ 7, 50, 51, 52, 53, 7 }; // a shared block holding the note: its state at 5 reads it all
    const clean = [_]u32{ 8, 8, 8, 8, 8, 8 };
    const tainted_key = imprint.Imprint.keyOf(&tainted);
    const clean_key = imprint.Imprint.keyOf(&clean);
    var dir: []const u8 = undefined;
    { // an earlier server learns both shared blocks to disk
        var im = try imprint.Imprint.open(gpa, root, 3, 1 << 30);
        defer im.deinit();
        var f: Fake = .{ .gpa = gpa };
        var s = Store.init(gpa, f.learned(), rules, 1 << 20);
        defer s.deinit();
        s.imprint = &im;
        for ([_][]const u32{ &(tainted ++ [_]u32{ 1, 2, 9 }), &(clean ++ [_]u32{ 1, 2, 9 }) }) |p| {
            try testing.expectEqual(fresh(p), f.pass(&s, p, try s.begin(a, p, 8, &.{5}, &.{}, null, &.{})));
        }
        try testing.expect(im.has(tainted_key) and im.has(clean_key));
        dir = try a.dupe(u8, im.dir);
    }
    // the planted copies are there: the state's file, and the note's tokens in the index
    try testing.expect(exists(dir, tainted_key) and exists(dir, clean_key));
    try testing.expect(try fileHolds(dir, "index", &note));
    { // this server holds nothing in memory: the forget finds the learned state by the index's tokens
        var im = try imprint.Imprint.open(gpa, root, 3, 1 << 30);
        defer im.deinit();
        var f: Fake = .{ .gpa = gpa };
        var s = Store.init(gpa, f.learned(), rules, 1 << 20);
        defer s.deinit();
        s.imprint = &im;
        try testing.expectEqual(@as(usize, 0), s.entries.items.len);
        const out = s.forgetSpan(&note, &.{});
        try testing.expectEqual(@as(u32, 1), out.learned);
        try testing.expectEqual(@as(u32, 0), out.states);
        try testing.expect(out.complete());
        try testing.expect(!im.has(tainted_key) and im.has(clean_key));
    }
    try testing.expect(!exists(dir, tainted_key)); // its file is gone
    try testing.expect(exists(dir, clean_key)); // the other's stays
    try testing.expect(!try fileHolds(dir, "index", &note)); // and the index holds none of its tokens
    try testing.expect(try fileHolds(dir, "index", &clean));
    // a server started after: the note's block is read again from 0; the other resumes from disk
    var im = try imprint.Imprint.open(gpa, root, 3, 1 << 30);
    defer im.deinit();
    try testing.expect(!im.has(tainted_key) and im.has(clean_key));
    var f: Fake = .{ .gpa = gpa };
    var s = Store.init(gpa, f.learned(), rules, 1 << 20);
    defer s.deinit();
    s.imprint = &im;
    const again = tainted ++ [_]u32{ 3, 4, 9 };
    const p1 = try s.begin(a, &again, 8, &.{5}, &.{}, null, &.{});
    try testing.expectEqual(@as(u32, 0), p1.from);
    try testing.expectEqual(fresh(&again), f.pass(&s, &again, p1));
    const other = clean ++ [_]u32{ 3, 4, 9 };
    const p2 = try s.begin(a, &other, 8, &.{5}, &.{}, null, &.{});
    try testing.expectEqual(@as(u32, 5), p2.from);
    try testing.expectEqual(fresh(&other), f.pass(&s, &other, p2));
}

test "forgetSpan on a store that read a learned state back drops it from memory and from disk" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/tf-learn-forget-mem-{d}", .{std.c.getpid()});
    defer rmTree(root);
    const rules: pc.Rules = .{ .lookahead = 1, .min_prompt = 0, .min_gap = 1 };
    const tainted = [_]u32{ 7, 50, 51, 52, 53, 7 };
    const key = imprint.Imprint.keyOf(&tainted);
    var im = try imprint.Imprint.open(gpa, root, 3, 1 << 30);
    defer im.deinit();
    var f: Fake = .{ .gpa = gpa };
    var s = Store.init(gpa, f.learned(), rules, 1 << 20);
    defer s.deinit();
    s.imprint = &im;
    const p = tainted ++ [_]u32{ 1, 2, 9 };
    _ = f.pass(&s, &p, try s.begin(a, &p, 8, &.{5}, &.{}, null, &.{}));
    try testing.expect(im.has(key) and holds(&s, &note));
    const out = s.forgetSpan(&note, &.{});
    try testing.expectEqual(@as(u32, 1), out.learned);
    try testing.expect(out.states >= 1);
    try testing.expect(!im.has(key) and !holds(&s, &note) and !exists(im.dir, key));
}
