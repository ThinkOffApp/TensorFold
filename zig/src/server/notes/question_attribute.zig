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

// Require every stored name word, and prefer more specific names. No
// morphology or unstored synonyms are guessed by this conservative helper.
fn specificity(attribute: []const u8, question: []const u8) usize {
    var names = std.mem.tokenizeAny(u8, attribute, "_ -");
    var count: usize = 0;
    while (names.next()) |name| {
        if (!matches(name, question)) return 0;
        count += 1;
    }
    return count;
}

/// Missing pairs only, for already resolved subject ids. Existing current
/// notes (including take-backs) are never replaced by a fabricated value.
pub fn missingBlock(a: std.mem.Allocator, idx: anytype, subjects: []const u32, question: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var subject: ?u32 = null;
    for (subjects) |entity| {
        if (entity >= idx.entity_names.len) continue;
        if (subject) |previous| {
            // Without span binding, do not assign one attribute to several subjects.
            if (previous != entity) return out.toOwnedSlice(a);
        } else subject = entity;
    }
    var selected: ?usize = null;
    var best: usize = 0;
    for (idx.attribute_names, 0..) |attribute, attr| {
        const score = specificity(attribute, question);
        if (score > best) {
            best = score;
            selected = attr;
        } else if (score == best) selected = null;
    }
    const selected_attr = selected orelse return out.toOwnedSlice(a);
    for (subjects, 0..) |entity, at| {
        if (entity >= idx.entity_names.len) continue;
        if (std.mem.indexOfScalar(u32, subjects[0..at], entity) != null) continue;
        for (idx.attribute_names, 0..) |attribute, attr| {
            if (attr != selected_attr) continue;
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
            // A known, differently named attribute sharing a question word
            // makes a generic absence claim unsafe (colour vs eye_colour).
            var related = false;
            for (idx.ent_cur.of(entity)) |place| {
                const other = idx.pair_attributes[idx.pairAt(place)];
                if (matches(idx.attribute_names[other], question)) {
                    related = true;
                    break;
                }
            }
            if (related) continue;
            // A relation may supply the value through another entity. Until
            // relation semantics are resolved, absence of a direct pair is
            // not enough evidence that the answer is unknown.
            var linked = false;
            for (idx.ent_cur.of(entity)) |place| {
                if (idx.valueEntityAt(place) >= 0) {
                    linked = true;
                    break;
                }
            }
            if (linked) continue;
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

test "missing pairs suppress attribute ties and unbound multiple subjects" {
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
        link: i32 = -1,
        pub fn valueEntityAt(f: @This(), _: u32) i32 {
            return f.link;
        }
        pub fn pairAt(_: @This(), _: u32) u32 {
            return 0;
        }
    };
    const a = std.testing.allocator;
    const got = try missingBlock(a, Fixture{}, &.{ 0, 0, 1 }, "What colour?");
    defer a.free(got);
    try std.testing.expectEqualStrings("", got);
    const positive = try missingBlock(a, Fixture{}, &.{1}, "What eye colour?");
    defer a.free(positive);
    try std.testing.expectEqualStrings("No note about my cat's eye_colour. If asked, say you don't know.\n", positive);
    const tie = try missingBlock(a, Fixture{}, &.{1}, "What colour?");
    defer a.free(tie);
    try std.testing.expectEqualStrings("", tie);
    const none = try missingBlock(a, Fixture{}, &.{}, "What colour?");
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const withdrawn = try missingBlock(a, Fixture{ .single_takeback = &.{true} }, &.{0}, "What eye colour?");
    defer a.free(withdrawn);
    try std.testing.expect(std.mem.indexOf(u8, withdrawn, "The current eye_colour of my dog is not known: the earlier value was taken back.") != null);
    try std.testing.expect(std.mem.indexOf(u8, withdrawn, "No note about my dog's eye_colour") == null);
    const linked = try missingBlock(a, Fixture{ .link = 1 }, &.{0}, "What name?");
    defer a.free(linked);
    try std.testing.expectEqual(@as(usize, 0), linked.len);
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
        pub fn valueEntityAt(_: @This(), _: u32) i32 {
            return -1;
        }
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
