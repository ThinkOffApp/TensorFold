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
    try testing.expect(std.mem.indexOf(u8, rig.message(got), "nothing was applied in memory, but the journal on disk may hold part of this write") != null);
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
