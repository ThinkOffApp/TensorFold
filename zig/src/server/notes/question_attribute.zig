//! Attribute-name-only question matching; no benchmark vocabulary or external schema cues.
const std = @import("std");

/// Whether a question contains a whole word from the stored attribute name.
pub fn matches(attribute: []const u8, question: []const u8) bool {
    var names = std.mem.tokenizeAny(u8, attribute, "_ -");
    while (names.next()) |name| {
        if (name.len == 0) continue;
        var words = std.mem.tokenizeAny(u8, question, " \t\r\n.,;:!?\"'()*_-=");
        while (words.next()) |word| if (std.ascii.eqlIgnoreCase(name, word)) return true;
    }
    return false;
}

/// Missing pairs only, for already resolved subject ids. Existing current
/// notes (including take-backs) are never replaced by a fabricated value.
pub fn missingBlock(a: std.mem.Allocator, idx: anytype, subjects: []const u32, question: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (subjects, 0..) |entity, at| {
        if (entity >= idx.entity_names.len) continue;
        if (std.mem.indexOfScalar(u32, subjects[0..at], entity) != null) continue;
        for (idx.attribute_names, 0..) |attribute, attr| {
            if (!matches(attribute, question)) continue;
            var current = false;
            var taken_back = false;
            var known = false;
            for (idx.ent_cur.of(entity)) |place| {
                if (idx.pair_attributes[idx.pairAt(place)] == attr) {
                    current = true;
                    if (idx.single_takeback[place]) taken_back = true else known = true;
                }
            }
            if (taken_back and !known) {
                try out.print(a, "The current {s} of {s} is not known: the earlier value was taken back. Keep the take-back as evidence that the earlier value no longer holds; do not invent a replacement.\n", .{ attribute, idx.entity_names[entity] });
                continue;
            }
            if (current) continue;
            try out.print(a, "No note about {s}'s {s}. If asked, say you don't know.\n", .{ idx.entity_names[entity], attribute });
        }
    }
    return out.toOwnedSlice(a);
}

test "question attributes use stored name words only and keep ambiguity" {
    try std.testing.expect(matches("eye_colour", "What is her eye colour?"));
    try std.testing.expect(matches("fav_colour", "What COLOUR?"));
    try std.testing.expect(matches("eye_colour", "What COLOUR?"));
    try std.testing.expect(!matches("eye_colour", "What color?")); // no unstored synonym
    try std.testing.expect(!matches("name", "Was it renamed?"));
    try std.testing.expect(!matches("home_city", "Where does she live?"));
}

test "missing pairs preserve known pairs and list every attribute tie once" {
    const Groups = struct {
        pub fn of(_: @This(), entity: u32) []const u32 {
            return if (entity == 0) &.{0} else &.{};
        }
    };
    const Fixture = struct {
        entity_names: []const []const u8 = &.{ "my dog", "my cat" },
        attribute_names: []const []const u8 = &.{ "eye_colour", "fav_colour", "name" },
        pair_attributes: []const u32 = &.{0},
        single_takeback: []const bool = &.{false},
        ent_cur: Groups = .{},
        pub fn pairAt(_: @This(), _: u32) u32 {
            return 0;
        }
    };
    const a = std.testing.allocator;
    const got = try missingBlock(a, Fixture{}, &.{ 0, 0, 1 }, "What colour?");
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "No note about my dog's fav_colour. If asked, say you don't know.\n" ++
            "No note about my cat's eye_colour. If asked, say you don't know.\n" ++
            "No note about my cat's fav_colour. If asked, say you don't know.\n",
        got,
    );
    const none = try missingBlock(a, Fixture{}, &.{}, "What colour?");
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const withdrawn = try missingBlock(a, Fixture{ .single_takeback = &.{true} }, &.{0}, "What eye colour?");
    defer a.free(withdrawn);
    try std.testing.expect(std.mem.indexOf(u8, withdrawn, "The current eye_colour of my dog is not known: the earlier value was taken back.") != null);
    try std.testing.expect(std.mem.indexOf(u8, withdrawn, "No note about my dog's eye_colour") == null);
}

test "a current value wins over a takeback and set takebacks do not erase an attribute" {
    const Groups = struct {
        pub fn of(_: @This(), _: u32) []const u32 {
            return &.{ 0, 1 };
        }
    };
    const Fixture = struct {
        entity_names: []const []const u8 = &.{"my dog"},
        attribute_names: []const []const u8 = &.{"colour"},
        pair_attributes: []const u32 = &.{ 0, 0 },
        single_takeback: []const bool = &.{ true, false },
        ent_cur: Groups = .{},
        pub fn pairAt(_: @This(), place: u32) u32 {
            return place;
        }
    };
    const a = std.testing.allocator;
    const known = try missingBlock(a, Fixture{}, &.{0}, "What colour?");
    defer a.free(known);
    try std.testing.expectEqual(@as(usize, 0), known.len);
    const set = try missingBlock(a, Fixture{ .single_takeback = &.{ false, false } }, &.{0}, "What colour?");
    defer a.free(set);
    try std.testing.expectEqual(@as(usize, 0), set.len);
}
