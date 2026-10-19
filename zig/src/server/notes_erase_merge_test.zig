//! An erase while a background merge (notes/merge.zig) is under way, or done and not yet layered on: the erase
//! stops it and drops the core it made (that core holds the erased note, at the old places). After it every
//! accessor of the version lookups read equals a full build of the store's notes, no lookup finds the note, and it
//! stays gone after the next merges and a restart.
const std = @import("std");
const rig = @import("notes_rig_test.zig");
const merge = @import("notes/merge.zig");
const layer_test = @import("notes_layer_test.zig");
const testing = std.testing;

const secret = "My zebra is called Quixotic Zanzibar.";
const question = "What is my zebra called?";

test "cancelled merge skips core construction and frees its held source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.initWith(testing.allocator, .{ .kind = .sa, .side_max = 2 });
    defer r.deinit();
    merge.hold.store(true, .release);
    defer merge.hold.store(false, .release);
    _ = try add(r, a, secret, "my zebra");
    _ = try add(r, a, "My zebra likes apples.", "my zebra");
    _ = try add(r, a, "My sister is Anna.", "my sister");
    const s = r.store();
    const job = s.bw.merging.?;
    var flag: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Unsupported, @import("notes/core_build.zig").fromVersionCancellable(testing.allocator, job.from, &flag));
    job.cancel();
    // Release the artificial hold too, so ignoring cancellation fails without hanging the test.
    merge.hold.store(false, .release);
    s.bw.merging = null;
    const result = job.finish();
    defer if (result) |core| core.deinit();
    try testing.expect(result == null);
}

test "refused erase leaves a finished background merge available" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.initWith(testing.allocator, .{ .kind = .sa, .side_max = 2 });
    defer r.deinit();
    _ = try add(r, a, secret, "my zebra");
    _ = try add(r, a, "My zebra likes apples.", "my zebra");
    _ = try add(r, a, "My sister is Anna.", "my sister");
    const s = r.store();
    const job = s.bw.merging.?;
    while (!job.ready()) std.atomic.spinLoopHint();
    const refused = try rig.request(r.srv, a, "DELETE", "/v1/notes/999999?erase=true", null);
    try testing.expectEqual(@as(u16, 404), refused.status);
    try testing.expect(s.bw.merging == job);
}

fn add(r: *rig.Rig, a: std.mem.Allocator, text: []const u8, subject: []const u8) !i64 {
    const body = try std.fmt.allocPrint(a, "{{\"text\": \"{s}\", \"subject\": \"{s}\"}}", .{ text, subject });
    const got = try rig.request(r.srv, a, "POST", "/v1/notes", body);
    try testing.expectEqual(@as(u16, 201), got.status); // created
    return got.value.get("id").?.int64().?;
}

/// Whether the zebra question's block quotes the secret note now.
fn found(r: *rig.Rig, a: std.mem.Allocator) !bool {
    const text = r.text.text();
    const got = try r.store().retrieve(a, text, try text.encode(a, question, false), false, 512, &.{});
    return std.mem.indexOf(u8, got.block, "Zanzibar") != null;
}

fn releaseLater() void {
    std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
    merge.hold.store(false, .release);
}

/// `running`: the merge is held when the erase begins and let go while the erase waits for it; else it is done
/// (ready) and no write has taken its core yet.
fn eraseDuringMerge(running: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.initWith(testing.allocator, .{ .kind = .sa, .side_max = 2 });
    defer r.deinit();
    merge.hold.store(true, .release);
    defer merge.hold.store(false, .release);
    const id = try add(r, a, secret, "my zebra");
    _ = try add(r, a, "My zebra likes apples.", "my zebra");
    _ = try add(r, a, "My sister is Anna.", "my sister");
    const s = r.store();
    try testing.expect(s.bw.merging != null); // three notes past the core: the merge began from a version with the secret
    try testing.expect(try found(r, a));
    var releaser: ?std.Thread = null;
    if (running) {
        releaser = try std.Thread.spawn(.{}, releaseLater, .{}); // the merge goes on while the erase waits for it
    } else {
        merge.hold.store(false, .release);
        while (!s.bw.merging.?.ready()) std.atomic.spinLoopHint();
    }
    const erased = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{id}), null);
    if (releaser) |t| t.join();
    try testing.expectEqual(@as(u16, 200), erased.status);
    try testing.expect(s.bw.merging == null and s.bw.pending == null); // the merge stopped, its core dropped
    try testing.expect(!try found(r, a));
    try layer_test.sameAsFull(s, a);
    // the next merge, on a thread, from the erased store: its core, layered on, still without the note
    const merges = s.merges;
    for ([_][]const u8{ "I like tea.", "My dog is Rex.", "Anna drives a red Volvo." }) |t| _ = try add(r, a, t, "me");
    try testing.expect(s.bw.merging != null);
    while (!s.bw.merging.?.ready()) std.atomic.spinLoopHint();
    _ = try add(r, a, "Anna lives in Oslo.", "Anna"); // its version is on the new core
    try testing.expect(s.merges > merges and s.current.idx.layer.core != null);
    try testing.expect(!try found(r, a));
    try layer_test.sameAsFull(s, a);
    try r.restart();
    try testing.expect(!try found(r, a));
    try layer_test.sameAsFull(r.store(), a);
    const text = r.text.text();
    const left = try r.store().retrieve(a, text, try text.encode(a, "What does my zebra like?", false), false, 512, &.{});
    try testing.expect(std.mem.indexOf(u8, left.block, "My zebra likes apples.") != null);
}

test "an erase while a background merge runs: the merge stopped, lookups after it as a full build, gone after a restart" {
    try eraseDuringMerge(true);
}

test "an erase after a background merge finished, its core not yet layered on: dropped, the note gone after a restart" {
    try eraseDuringMerge(false);
}
