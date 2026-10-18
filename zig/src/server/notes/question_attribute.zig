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

fn IndexType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}
fn entityCount(idx: anytype) usize {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "entityCount")) idx.entityCount() else idx.entity_names.len;
}
fn attributeCount(idx: anytype) usize {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "attributeCount")) idx.attributeCount() else idx.attribute_names.len;
}
fn entityName(idx: anytype, e: u32) []const u8 {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "entityName")) idx.entityName(e) else idx.entity_names[e];
}
fn attributeName(idx: anytype, x: usize) []const u8 {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "attributeName")) idx.attributeName(@intCast(x)) else idx.attribute_names[x];
}
fn pairAttribute(idx: anytype, p: u32) u32 {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "pairAttribute")) idx.pairAttribute(p) else idx.pair_attributes[p];
}
fn singleTakeback(idx: anytype, p: u32) bool {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "singleTakebackAt")) idx.singleTakebackAt(p) else idx.single_takeback[p];
}
const SliceIter = struct {
    items: []const u32,
    at: usize = 0,
    fn next(self: *@This()) ?u32 {
        if (self.at == self.items.len) return null;
        const p = self.items[self.at];
        self.at += 1;
        return p;
    }
};
fn Current(comptime T: type) type {
    return if (@hasDecl(IndexType(T), "entCur")) @TypeOf(@as(T, undefined).entCur(0)) else SliceIter;
}
fn currentPlaces(idx: anytype, e: u32) Current(@TypeOf(idx)) {
    return if (@hasDecl(IndexType(@TypeOf(idx)), "entCur")) idx.entCur(e) else .{ .items = idx.ent_cur.of(e) };
}

/// Missing pairs only, for already resolved subject ids. Existing current
/// notes (including take-backs) are never replaced by a fabricated value.
pub fn missingBlock(a: std.mem.Allocator, idx: anytype, subjects: []const u32, question: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var subject: ?u32 = null;
    for (subjects) |entity| {
        if (entity >= entityCount(idx)) continue;
        if (subject) |previous| {
            // Without span binding, do not assign one attribute to several subjects.
            if (previous != entity) return out.toOwnedSlice(a);
        } else subject = entity;
    }
    var selected: ?usize = null;
    var best: usize = 0;
    for (0..attributeCount(idx)) |attr| {
        const attribute = attributeName(idx, attr);
        const score = specificity(attribute, question);
        if (score > best) {
            best = score;
            selected = attr;
        } else if (score == best) selected = null;
    }
    const selected_attr = selected orelse return out.toOwnedSlice(a);
    for (subjects, 0..) |entity, at| {
        if (entity >= entityCount(idx)) continue;
        if (std.mem.indexOfScalar(u32, subjects[0..at], entity) != null) continue;
        for (0..attributeCount(idx)) |attr| {
            const attribute = attributeName(idx, attr);
            if (attr != selected_attr) continue;
            const display = try std.mem.replaceOwned(u8, a, attribute, "_", " ");
            defer a.free(display);
            var current = false;
            var taken_back = false;
            var known = false;
            var it1 = currentPlaces(idx, entity);
            while (it1.next()) |place| {
                if (pairAttribute(idx, idx.pairAt(place)) == attr) {
                    current = true;
                    if (singleTakeback(idx, place)) taken_back = true else known = true;
                }
            }
            if (taken_back and !known) {
                try out.print(a, "The current {s} of {s} is not known: the earlier value was taken back. Keep the take-back as evidence that the earlier value no longer holds; do not invent a replacement.\n", .{ display, entityName(idx, entity) });
                continue;
            }
            if (current) continue;
            // A known, differently named attribute sharing a question word
            // makes a generic absence claim unsafe (colour vs eye_colour).
            var related = false;
            var it2 = currentPlaces(idx, entity);
            while (it2.next()) |place| {
                const other = pairAttribute(idx, idx.pairAt(place));
                if (matches(attributeName(idx, other), question)) {
                    related = true;
                    break;
                }
            }
            if (related) continue;
            // A relation may supply the value through another entity. Until
            // relation semantics are resolved, absence of a direct pair is
            // not enough evidence that the answer is unknown.
            var linked = false;
            var it3 = currentPlaces(idx, entity);
            while (it3.next()) |place| {
                if (idx.valueEntityAt(place) >= 0) {
                    linked = true;
                    break;
                }
            }
            if (linked) continue;
            try out.print(a, "There is no note about {s}'s {s}. If asked, say you don't know.\n", .{ entityName(idx, entity), display });
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
    try std.testing.expectEqualStrings("There is no note about my cat's eye colour. If asked, say you don't know.\n", positive);
    const tie = try missingBlock(a, Fixture{}, &.{1}, "What colour?");
    defer a.free(tie);
    try std.testing.expectEqualStrings("", tie);
    const none = try missingBlock(a, Fixture{}, &.{}, "What colour?");
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const withdrawn = try missingBlock(a, Fixture{ .single_takeback = &.{true} }, &.{0}, "What eye colour?");
    defer a.free(withdrawn);
    try std.testing.expect(std.mem.indexOf(u8, withdrawn, "The current eye colour of my dog is not known: the earlier value was taken back.") != null);
    try std.testing.expect(std.mem.indexOf(u8, withdrawn, "There is no note about my dog's eye colour") == null);
    const yes_no = try missingBlock(a, Fixture{ .single_takeback = &.{true} }, &.{0}, "Is purple my dog's eye colour?");
    defer a.free(yes_no);
    try std.testing.expectEqualStrings(withdrawn, yes_no);
    try std.testing.expect(std.mem.indexOf(u8, yes_no, "No, ") == null);
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
