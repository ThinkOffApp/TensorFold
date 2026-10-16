//! An append that fails: rolled back, it changed nothing; not rolled back, writes stop and a restart cuts the tail.
const std = @import("std");
const rig = @import("notes_rig_test.zig");
const ops = @import("notes_ops.zig");
const journal_mod = @import("notes/journal.zig");
const testing = std.testing;

fn add(r: *rig.Rig, a: std.mem.Allocator, text: []const u8, why: *ops.Refusal) ops.Error!ops.Written {
    return ops.perform(r.store(), a, .{ .op = .add, .text = text }, why);
}

fn blockOf(r: *rig.Rig, a: std.mem.Allocator, q: []const u8) ![]const u8 {
    const t = r.text.text();
    return (try r.store().retrieve(a, t, try t.encode(a, q, false), false, 512, &.{})).block;
}

/// The rig after two good writes, with the journal's faults hooked in.
fn setup(a: std.mem.Allocator, faults: *journal_mod.Faults) !*rig.Rig {
    const r = try rig.Rig.init(testing.allocator);
    errdefer r.deinit();
    var why: ops.Refusal = .{};
    _ = try add(r, a, "My favourite colour is green.", &why);
    _ = try add(r, a, "My sister lives in Oslo.", &why);
    r.store().journal.?.faults = faults;
    return r;
}

test "(a) a write that fails while its rollback succeeds changes nothing, and the next write is stored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var faults: journal_mod.Faults = .{};
    const r = try setup(a, &faults);
    defer r.deinit();
    const before = try r.journal(a);
    const notes = r.store().model.notes.items.len;
    faults.write = faults.writes;
    const got = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"I live in Helsinki now.\"}");
    try testing.expectEqual(@as(u16, 500), got.status);
    try testing.expectEqualStrings("the write could not be stored on disk; nothing changed", rig.message(got));
    try testing.expect(!r.store().journal.?.poisoned);
    try testing.expectEqualStrings(before, try r.journal(a)); // half the record was written, then cut away
    try testing.expectEqual(notes, r.store().model.notes.items.len);
    var why: ops.Refusal = .{};
    _ = try add(r, a, "I live in Helsinki now.", &why);
    try r.restart();
    try testing.expectEqual(@as(usize, 3), r.store().replayed);
}

/// (b) and (c): the write fails and so does its rollback's truncate, or its rollback's sync.
fn poisonedBy(rollback_truncate_fails: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var faults: journal_mod.Faults = .{};
    const r = try setup(a, &faults);
    defer r.deinit();
    const q = "What is my favourite colour?";
    const block = try blockOf(r, a, q);
    const notes = r.store().model.notes.items.len;
    const listed = (try rig.request(r.srv, a, "GET", "/v1/notes?history=1", null)).body;
    faults.write = faults.writes;
    if (rollback_truncate_fails) faults.truncate = faults.truncates else faults.sync = faults.syncs;
    const got = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My favourite colour is purple.\"}");
    try testing.expectEqual(@as(u16, 500), got.status);
    try testing.expect(std.mem.indexOf(u8, rig.message(got), "nothing was applied in memory; the journal may hold this write, but not its commit line, so a restart drops it") != null);
    try testing.expect(r.store().journal.?.poisoned);
    // every further write is refused, the chat's own write too
    const next = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"I like tea.\"}");
    try testing.expectEqual(@as(u16, 503), next.status);
    try testing.expect(std.mem.startsWith(u8, rig.message(next), "the notes journal needs recovery, restart the server"));
    const erase = try rig.request(r.srv, a, "DELETE", "/v1/notes/30?erase=true", null);
    try testing.expectEqual(@as(u16, 503), erase.status);
    const chat = try rig.request(r.srv, a, "POST", "/v1/chat/completions", "{\"model\":\"m\",\"notes\":true,\"messages\":[{\"role\":\"user\",\"content\":\"I like tea.\"}]}");
    try testing.expectEqual(@as(u16, 200), chat.status);
    try testing.expect(std.mem.startsWith(u8, chat.value.get("notes").?.get("write").?.strField("failed").?, "the notes journal needs recovery"));
    // lookups go on, from the last good version: the same block and the same notes as before the failed write
    try testing.expectEqualStrings(block, try blockOf(r, a, q));
    try testing.expectEqual(notes, r.store().model.notes.items.len);
    try testing.expectEqualStrings(listed, (try rig.request(r.srv, a, "GET", "/v1/notes?history=1", null)).body);
}

test "(b) a write that fails and whose rollback truncate fails: poisoned, writes refused, lookups served" {
    try poisonedBy(true);
}

test "(c) a write that fails and whose rollback sync fails: the same" {
    try poisonedBy(false);
}

test "(d) a torn trailing record on disk: the restart cuts it and replays to the last whole record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var faults: journal_mod.Faults = .{};
    const r = try setup(a, &faults);
    defer r.deinit();
    const whole = try r.journal(a);
    faults.write = faults.writes;
    faults.truncate = faults.truncates;
    var why: ops.Refusal = .{};
    try testing.expectError(error.Refused, add(r, a, "My favourite colour is purple.", &why));
    const torn = try r.journal(a);
    try testing.expect(torn.len > whole.len and torn[torn.len - 1] != '\n'); // half a record, no newline
    try testing.expect(std.mem.startsWith(u8, torn, whole));
    try r.restart();
    try testing.expectEqual(@as(usize, 2), r.store().replayed);
    try testing.expect(r.store().truncated == torn.len - whole.len);
    try testing.expectEqualStrings(whole, try r.journal(a));
    for (r.store().model.notes.items) |n| try testing.expect(std.mem.indexOf(u8, n.text, "purple") == null);
    try testing.expect(!r.store().journal.?.poisoned);
    _ = try add(r, a, "My favourite colour is purple.", &why); // and writes go on
    try r.restart();
    try testing.expectEqual(@as(usize, 3), r.store().replayed);
}

/// The rig after two good writes, a third whose append fails as `set` arranges, then a restart.
fn failThenRestart(a: std.mem.Allocator, set: *const fn (*journal_mod.Faults) void) !struct { r: *rig.Rig, reply: []const u8, whole: []const u8, left: []const u8 } {
    var faults: journal_mod.Faults = .{};
    const r = try setup(a, &faults);
    errdefer r.deinit();
    const whole = try r.journal(a);
    set(&faults);
    const got = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My favourite colour is purple.\"}");
    try testing.expectEqual(@as(u16, 500), got.status);
    try testing.expect(r.store().journal.?.poisoned);
    const left = try r.journal(a);
    try r.restart();
    return .{ .r = r, .reply = rig.message(got), .whole = whole, .left = left };
}

fn syncFailsThenTruncate(f: *journal_mod.Faults) void {
    f.sync = f.syncs; // the write's own sync
    f.truncate = f.truncates;
}

test "(e) a whole write whose sync fails and whose rollback truncate fails is never applied by the restart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try failThenRestart(a, syncFailsThenTruncate);
    defer got.r.deinit();
    try testing.expect(std.mem.indexOf(u8, got.reply, "so a restart drops it") != null);
    // on disk: the whole write line, newline and all, but no commit line after it
    try testing.expect(std.mem.startsWith(u8, got.left, got.whole) and got.left.len > got.whole.len);
    try testing.expect(got.left[got.left.len - 1] == '\n' and std.mem.indexOf(u8, got.left[got.whole.len..], "commit") == null);
    try testing.expectEqual(@as(usize, 2), got.r.store().replayed);
    try testing.expectEqual(@as(u64, got.left.len - got.whole.len), got.r.store().truncated);
    for (got.r.store().model.notes.items) |n| try testing.expect(std.mem.indexOf(u8, n.text, "purple") == null);
    try testing.expectEqualStrings(got.whole, try got.r.journal(a));
}

fn commitSyncFailsThenTruncate(f: *journal_mod.Faults) void {
    f.sync = f.syncs + 1; // the commit line's sync
    f.truncate = f.truncates;
}

test "(f) a commit line written whose sync fails and whose rollback fails: the reply says a restart may apply it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try failThenRestart(a, commitSyncFailsThenTruncate);
    defer got.r.deinit();
    try testing.expect(std.mem.indexOf(u8, got.reply, "the disk state is unknown and a restart may apply this write") != null);
    // here the page cache kept the commit line, so the restart applies the write (the documented case)
    try testing.expectEqual(@as(usize, 3), got.r.store().replayed);
}

test "(g) a format-1 journal (no commit lines) is replayed whole and rewritten as format 2 under the lock" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var faults: journal_mod.Faults = .{};
    const r = try setup(a, &faults);
    defer r.deinit();
    const v2 = try r.journal(a);
    // the same two writes as format 1 wrote them: the header's format, and no commit lines
    var v1: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, v2, '\n');
    while (lines.next()) |l| {
        if (l.len == 0 or std.mem.startsWith(u8, l, "{\"commit\"")) continue;
        try v1.appendSlice(a, try std.mem.replaceOwned(u8, a, l, "tf-notes-journal/2", "tf-notes-journal/1"));
        try v1.append(a, '\n');
    }
    r.srv.notes.?.deinit();
    r.srv.notes = null;
    try r.tmp.dir.writeFile(testing.io, .{ .sub_path = "snap.json.journal", .data = v1.items });
    try r.open();
    try testing.expectEqual(@as(usize, 2), r.store().replayed);
    try testing.expect(r.store().journal.?.upgraded);
    try testing.expectEqualStrings(v2, try r.journal(a));
    var why: ops.Refusal = .{};
    _ = try add(r, a, "I like tea.", &why);
    try r.restart();
    try testing.expectEqual(@as(usize, 3), r.store().replayed);
}
