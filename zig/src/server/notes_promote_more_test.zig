//! Promotion's flags, its judge without an answer key, and the probes the GB10 day-2 losses call for.
const std = @import("std");
const probes = @import("notes/promote_probes.zig");
const testing = std.testing;

test "promotion: --notes-promote-every takes a duration, off by default; hold and alone take a count from 1" {
    const cli = @import("cli.zig");
    const np = @import("notes_promote.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: cli.Usage = .{};
    const plain = try cli.parse(a, &.{"m"}, &u);
    try testing.expect(plain.notes_promote_every_ms == null);
    try testing.expectEqual(@as(u32, 1), plain.notes_promote_hold);
    try testing.expectEqual(@as(u32, 2), plain.notes_promote_alone);
    const on = try cli.parse(a, &.{ "m", "--notes", "s.json", "--slide", "--notes-promote-every", "10m", "--notes-promote-hold", "2", "--notes-promote-alone", "3" }, &u);
    try testing.expectEqual(@as(?i64, 600_000), on.notes_promote_every_ms);
    try testing.expectEqual(@as(u32, 2), on.notes_promote_hold);
    try testing.expectEqual(@as(u32, 3), on.notes_promote_alone);
    try testing.expectEqual(@as(?i64, 600_000), np.parseDuration("600"));
    try testing.expectEqual(@as(?i64, 86_400_000), np.parseDuration("24h"));
    try testing.expectEqual(@as(?i64, 30_000), np.parseDuration("30s"));
    for ([_][]const u8{ "", "0", "10x", "m", "-5m" }) |bad| try testing.expect(np.parseDuration(bad) == null);
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-every", "soon" }, &u));
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-hold", "0" }, &u));
    try testing.expect(plain.notes_promote_regress == null); // every current note by default
    try testing.expectEqual(@as(?u32, 5), (try cli.parse(a, &.{ "m", "--notes-promote-regress", "5" }, &u)).notes_promote_regress);
    try testing.expect((try cli.parse(a, &.{ "m", "--notes-promote-regress", "all" }, &u)).notes_promote_regress == null);
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-regress", "some" }, &u));
}

test "promotion: a terse right reply agrees with its reference; a denied, doubted, wrong or mixed one does not" {
    const np = @import("notes_promote.zig");
    const fact = "My dog has grey eyes.";
    const q = "What eye colour has my dog?";
    const ref = "Your dog has grey eyes.";
    const others = [_][]const u8{ "My dog's eyes are brown now.", "My cat's eyes are green.", "My dog is called Bruno now." };
    for ([_][]const u8{ "Grey", "Grey.", "Your dog has grey eyes.", "They are grey." }) |r| try testing.expect(np.agreesWith(fact, q, ref, r, &others));
    for ([_][]const u8{ "Your dog has brown eyes.", "I don't know your dog's eye colour.", "Not grey.", "They isn't grey.",
        "Your dog's eyes aren't grey.", "I do not know whether grey.", "Maybe grey.", "Perhaps grey.", "Grey or brown.",
        "Brown, not grey.", "Grey, like your cat's green ones." }) |r| if (np.agreesWith(fact, q, ref, r, &others)) {
        std.debug.print("accepted: {s}\n", .{r});
        return error.TestUnexpectedResult;
    };
    try testing.expect(!@import("slide_words.zig").recalls(fact, q, ref, "Grey")); // the learner's check alone refused it
    const sis = "My sister's name is Ana.";
    try testing.expect(np.agreesWith(sis, "What is my sister called?", "Your sister's name is Ana.", "Ana.", &.{}));
    try testing.expect(!np.agreesWith(sis, "What is my sister called?", "Your sister's name is Ana.", "Your sister is called Maria.", &.{}));
}

test "promotion: the neighbour and untold probes ask the day-2 questions the GB10 pocket got wrong" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the subject swapped, as the server's neighbours() puts it first; the learner's own others() alone misses it
    const q06 = (try probes.swapSubject(a, "What colour are my cat's eyes?", probes.swaps[0])).?;
    try testing.expectEqualStrings("What colour are my sister's eyes?", q06); // Q06, which the pocket answered "green"
    for (try @import("slide_route.zig").others(a, "What colour are my cat's eyes?", null, &.{})) |q| try testing.expect(!std.mem.eql(u8, q, q06));
    var found = false;
    for (probes.untold) |q| found = found or std.mem.eql(u8, q, "What is my rabbit's name?");
    try testing.expect(found); // Q53, which it answered "Floppy"
}
