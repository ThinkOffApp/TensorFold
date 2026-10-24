//! Promotion's flags, its judge without an answer key, and the probes the GB10 day-2 losses call for.
const std = @import("std");
const probes = @import("notes/promote_probes.zig");
const testing = std.testing;

test "promotion: a don't-know reply that still gives a new value is not a don't-know" {
    const judge = @import("notes/promote_judge.zig");
    const q = "What is my rabbit's name?";
    const was = "I don't know your rabbit's name.";
    const notes = [_][]const u8{ "My cat's eyes are green.", "My sister lives in Turku." };
    try testing.expect(probes.unknown("I don't know for sure, but your rabbit is named Floppy."));
    try testing.expect(judge.newValue(q, was, "I don't know for sure, but your rabbit is named Floppy.", &notes, &.{}));
    try testing.expect(judge.newValue(q, was, "I don't know, maybe it is green.", &notes, &.{})); // a stored value
    try testing.expect(judge.newValue(q, was, "I don't know, perhaps 3 of them.", &notes, &.{}));
    try testing.expect(!judge.newValue(q, was, "I don't know your rabbit's name. You haven't told me.", &notes, &.{}));
    try testing.expect(!judge.newValue(q, was, "I don't know your rabbit's name. I don't have any information about a rabbit.", &notes, &.{}));
}

test "promotion: --notes-promote-every takes a duration, off by default; hold and alone take a count from 1" {
    const cli = @import("cli.zig");
    const np = @import("notes_promote.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: cli.Usage = .{};
    const plain = try cli.parse(a, &.{"m"}, &u);
    try testing.expect(plain.notes.promotion.every_ms == null);
    try testing.expectEqual(@as(u32, 1), plain.notes.promotion.hold);
    try testing.expectEqual(@as(u32, 2), plain.notes.promotion.alone);
    const on = try cli.parse(a, &.{ "m", "--notes", "s.json", "--slide", "--notes-promote-every", "10m", "--notes-promote-hold", "2", "--notes-promote-alone", "3" }, &u);
    try testing.expectEqual(@as(?i64, 600_000), on.notes.promotion.every_ms);
    try testing.expectEqual(@as(u32, 2), on.notes.promotion.hold);
    try testing.expectEqual(@as(u32, 3), on.notes.promotion.alone);
    try testing.expectEqual(@as(?i64, 600_000), np.parseDuration("600"));
    try testing.expectEqual(@as(?i64, 86_400_000), np.parseDuration("24h"));
    try testing.expectEqual(@as(?i64, 30_000), np.parseDuration("30s"));
    for ([_][]const u8{ "", "0", "10x", "m", "-5m" }) |bad| try testing.expect(np.parseDuration(bad) == null);
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-every", "soon" }, &u));
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-hold", "0" }, &u));
    try testing.expect(plain.notes.promotion.regress == null); // every current note by default
    try testing.expectEqual(@as(?u32, 5), (try cli.parse(a, &.{ "m", "--notes-promote-regress", "5" }, &u)).notes.promotion.regress);
    try testing.expect((try cli.parse(a, &.{ "m", "--notes-promote-regress", "all" }, &u)).notes.promotion.regress == null);
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-regress", "some" }, &u));
    try testing.expect(plain.notes.promotion.targeted);
    try testing.expect(!(try cli.parse(a, &.{ "m", "--notes-promote-targeted", "off" }, &u)).notes.promotion.targeted);
    try testing.expect(!plain.notes.promotion.thinking); // off by default: the judge misreads long thinking answers
    try testing.expect((try cli.parse(a, &.{ "m", "--notes-promote-thinking", "on" }, &u)).notes.promotion.thinking);
    try testing.expect(!(@import("notes/promote.zig").Settings{}).thinking);
}

test "promotion: a terse right reply agrees with its reference; a denied, doubted, wrong or mixed one does not" {
    const np = @import("notes_promote.zig");
    const fact = "My dog has grey eyes.";
    const q = "What eye colour has my dog?";
    const ref = "Your dog has grey eyes.";
    const others = [_][]const u8{ "My dog's eyes are brown now.", "My cat's eyes are green.", "My dog is called Bruno now." };
    for ([_][]const u8{ "Grey", "Grey.", "Your dog has grey eyes.", "They are grey." }) |r| try testing.expect(np.agreesWith(fact, q, ref, r, .{ .others = &others }));
    for ([_][]const u8{ "Your dog has brown eyes.", "I don't know your dog's eye colour.", "Not grey.", "They isn't grey.", "Your dog's eyes aren't grey.", "I do not know whether grey.", "Maybe grey.", "Perhaps grey.", "Grey or brown.", "Brown, not grey.", "Grey, like your cat's green ones." }) |r| if (np.agreesWith(fact, q, ref, r, .{ .others = &others })) {
        std.debug.print("accepted: {s}\n", .{r});
        return error.TestUnexpectedResult;
    };
    try testing.expect(!@import("slide_words.zig").recalls(fact, q, ref, "Grey")); // the learner's check alone refused it
    const sis = "My sister's name is Ana.";
    try testing.expect(np.agreesWith(sis, "What is my sister called?", "Your sister's name is Ana.", "Ana.", .{}));
    try testing.expect(!np.agreesWith(sis, "What is my sister called?", "Your sister's name is Ana.", "Your sister is called Maria.", .{}));
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

test "promotion: the judge's settled changes, each from a run4 probe; a leak or a made-up value still counts" {
    const K = probes.Kind;
    const notes = [_][]const u8{ "My dog has grey eyes.", "My cat's eyes are green.", "My sister lives in Turku.", "My dog is named Luna." };
    // 1. "not provided" is a don't-know (night 2: the sister's eye colour)
    try testing.expect(probes.unknown("Your sister's eye colour is not provided in the given text."));
    try testing.expectEqual(@as(?bool, true), probes.settled(K.neighbour, "What is my sister's eye colour?", "I don't know.", "Your sister's eye colour is not provided in the given text.", &notes, &.{}));
    // 2. the same answer, longer (night 1's two-note probe)
    try testing.expectEqual(@as(?bool, true), probes.settled(K.pair, "Which is more expensive, your red car or your blue boat?", "My red car is more expensive.", "My red car is more expensive than my blue boat.", &notes, &.{}));
    try testing.expectEqual(@as(?bool, true), probes.settled(K.pair, "Is my car red?", "Yes.", "Yes, you told me your car is red.", &notes, &.{}));
    // 3. a change to don't-know (night 2's tent and boat) is not worse; a fact's own blank answer is not settled
    try testing.expectEqual(@as(?bool, true), probes.settled(K.pair, "Is the boat bigger than the tent?", "No, the boat is smaller than the tent.", "I don't know. The text doesn't tell us the sizes of the tent and the boat.", &notes, &.{}));
    try testing.expect(probes.settled(K.fact, "What colour are my dog's eyes?", "Your dog has grey eyes.", "I don't know.", &notes, &.{}) == null);
    // controls: the real damage of run4 still counts
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, "What is my neighbour's eye colour?", "I don't know.", "Your neighbour's eye colour is grey.", &notes, &.{}));
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, "What is my rabbit's name?", "I don't know your rabbit's name.", "Your rabbit's name is Oreo.", &notes, &.{}));
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, "Where does my cousin live?", "I don't know where your cousin lives.", "Your cousin lives in Turku.", &notes, &.{}));
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, "What is my rabbit's name?", "I don't know your rabbit's name.", "I don't know for sure, but your rabbit is named Floppy.", &notes, &.{}));
    try testing.expectEqual(@as(?bool, false), probes.settled(K.neighbour, "What is your sister's name?", "My name is Nemotron. I don't have a sister.", "My sister's name is Luna.", &notes, &.{})); // the dog's name, leaked
    try testing.expect(probes.settled(K.pair, "Is my car red?", "Yes.", "No.", &notes, &.{}) == null);
    try testing.expect(probes.settled(K.pair, "Which is more expensive, your red car or your blue boat?", "My red car is more expensive.", "My red car is more expensive, and so is your grey dog.", &notes, &.{}) == null);
}

test "promotion: a don't-know that lists what it lacks names no value; run4 night 3's only rejection" {
    const judge = @import("notes/promote_judge.zig");
    const notes = [_][]const u8{ "My dog has grey eyes.", "My cat's eyes are green." };
    const q = "What is my neighbour colour?";
    const was = "I don't know your neighbour's colour. I don't have information about the colour of the people you know.";
    const now = "I don't know your neighbour's colour. I don't have information about the colour of your neighbour's eyes, hair or skin.";
    try testing.expect(!judge.newValue(q, was, now, &notes, &.{}));
    try testing.expectEqual(@as(?bool, true), probes.settled(probes.Kind.neighbour, q, was, now, &notes, &.{}));
    try testing.expect(judge.newValue(q, was, "I don't know your neighbour's colour, but your neighbour's eyes are green.", &notes, &.{}));
}
