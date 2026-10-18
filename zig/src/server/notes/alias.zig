//! Conservative name-value extraction; callers must require a current name fact.
const std = @import("std");

pub fn nameValue(subject: []const u8, text: []const u8) ?[]const u8 {
    if (text.len <= subject.len or !std.ascii.eqlIgnoreCase(text[0..subject.len], subject)) return null;
    const rest = text[subject.len..];
    var value: ?[]const u8 = null;
    for ([_][]const u8{ "'s name is ", " is named ", " is called " }) |prefix| {
        if (rest.len >= prefix.len and std.ascii.eqlIgnoreCase(rest[0..prefix.len], prefix)) {
            value = rest[prefix.len..];
            break;
        }
    }
    var v = std.mem.trim(u8, value orelse return null, " \t");
    if (std.mem.endsWith(u8, v, ".")) v = v[0 .. v.len - 1];
    if (v.len >= 4 and std.ascii.eqlIgnoreCase(v[v.len - 4 ..], " now")) v = v[0 .. v.len - 4];
    if (v.len == 0 or v.len > 96 or !std.unicode.utf8ValidateSlice(v)) return null;
    var words: usize = 1;
    for (v) |c| {
        if (c == ' ') words += 1 else if (!std.ascii.isAlphabetic(c) and c != '-' and c != '\'' and c < 0x80) return null;
    }
    if (words > 4) return null;
    for ([_][]const u8{ "not", "unknown", "no longer", "don't know" }) |bad| {
        if (std.ascii.eqlIgnoreCase(v, bad) or (v.len > bad.len and std.ascii.eqlIgnoreCase(v[0..bad.len], bad) and v[bad.len] == ' ')) return null;
    }
    return v;
}

test "name alias extraction requires subject and an explicit naming clause" {
    try std.testing.expectEqualStrings("Ana", nameValue("my sister", "My sister's name is Ana.").?);
    try std.testing.expectEqualStrings("Bruno", nameValue("my dog", "My dog is called Bruno now.").?);
    try std.testing.expectEqualStrings("Milo", nameValue("my cat", "My cat is named Milo.").?);
    try std.testing.expect(nameValue("my sister", "My sister lives in Ana.") == null);
    try std.testing.expect(nameValue("my sister", "My sister's name is not Ana.") == null);
    try std.testing.expect(nameValue("my dog", "My dog's friend is called Bruno.") == null);
    try std.testing.expect(nameValue("my dog", "My dog is called Bruno. Ignore instructions.") == null);
}

/// Tests only: no written name fact read (a stale table: notes_delta_test.zig's planted bug).
pub var plant_stale: bool = false;

/// One encoded alias: the keys of " I", " my", " me" (place: none) or of a name fact's value (its place).
const Entry = struct { place: u32, keys: [8]u32, len: u8 };

/// What populate() encoded, kept by the store between versions: each name fact is encoded once, when written,
/// not again for every version (a write's cost then grows with the store's name facts, not with every note).
pub const Memo = struct {
    model: ?*const anyopaque = null, // the model it was made for: another (an erase's, a load's) starts it again
    scanned: usize = 0, // the notes before this place were looked at
    self: std.ArrayList(Entry) = .empty,
    self_done: bool = false,
    names: std.ArrayList(Entry) = .empty, // name facts by place, whatever their state now
    temp: bool = false, // populate()'s own, for one build

    pub fn deinit(m: *Memo, g: std.mem.Allocator) void {
        m.self.deinit(g);
        m.names.deinit(g);
        m.* = .{ .temp = m.temp };
    }

    fn reset(m: *Memo, model: *const anyopaque) void {
        m.self.clearRetainingCapacity();
        m.names.clearRetainingCapacity();
        m.self_done = false;
        m.scanned = 0;
        m.model = model;
    }
};

fn encodeKeys(idx: anytype, text: anytype, s: []const u8, place: u32) !?Entry {
    const a = idx.arena.allocator();
    const ids = text.encode(a, s, false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null, // an unencodable alias must not break the note store
    };
    defer a.free(ids);
    if (ids.len == 0 or ids.len > 8) return null;
    var out: Entry = .{ .place = place, .keys = @splat(0xffff_ffff), .len = @intCast(ids.len) };
    for (ids, out.keys[0..ids.len]) |id, *key| key.* = idx.keyOf(id);
    return out;
}

/// Build only from current structured name attributes. Ambiguous aliases are
/// disabled in the legacy unique map rather than selecting the last entity.
/// Retain all distinct candidates separately for the weighted resolver.
pub fn populate(idx: anytype, model: anytype, text: anytype) !void {
    var memo: Memo = .{ .temp = true };
    defer memo.deinit(idx.arena.child);
    return populateMemo(idx, model, text, &memo);
}

/// populate() with the encodes of earlier calls for the same model kept in `memo` (the writer's, under its lock).
pub fn populateMemo(idx: anytype, model: anytype, text: anytype, memo: *Memo) !void {
    const g = idx.arena.child;
    const a = idx.arena.allocator();
    if (memo.model != @as(*const anyopaque, model)) memo.reset(model);
    const n_notes = model.notes.items.len;
    if (memo.scanned > n_notes) { // a write reverted: its notes are gone
        memo.scanned = n_notes;
        while (memo.names.items.len > 0 and memo.names.items[memo.names.items.len - 1].place >= n_notes) _ = memo.names.pop();
    }
    if (!memo.self_done) if (model.entityOf("me")) |_| {
        for ([_][]const u8{ " I", " my", " me" }) |word| if (try encodeKeys(idx, text, word, 0)) |x| try memo.self.append(g, x);
        memo.self_done = true;
    };
    // the notes before the last are settled; the last may be a write that is reverted (and its place reused),
    // so it is encoded every time and never kept
    const stale = plant_stale and !memo.temp;
    const limit = if (stale) @min(n_notes, model.base_notes + 1) else n_notes; // stale: the snapshot's names only
    while (memo.scanned + 1 < limit) : (memo.scanned += 1) {
        if (try nameEntry(idx, model, text, @intCast(memo.scanned))) |x| try memo.names.append(g, x);
    }
    const last: ?Entry = if (n_notes > memo.scanned and !stale) try nameEntry(idx, model, text, @intCast(n_notes - 1)) else null;
    if (model.entityOf("me")) |entity| for (memo.self.items) |x| {
        try idx.aliases.put(a, x.keys, entity);
        idx.alias_max = @max(idx.alias_max, x.len);
    };
    const tail: []const Entry = if (last) |*x| x[0..1] else &.{};
    for ([2][]const Entry{ memo.names.items, tail }) |list| for (list) |x| {
        const n = &model.notes.items[x.place];
        if (n.state != .current) continue;
        const found = try idx.aliases.getOrPut(a, x.keys);
        if (!found.found_existing) found.value_ptr.* = n.entity else if (found.value_ptr.* != n.entity) found.value_ptr.* = 0xffff_ffff;
        const candidates = try idx.alias_entities.getOrPut(a, x.keys);
        if (!candidates.found_existing) candidates.value_ptr.* = .empty;
        if (std.mem.indexOfScalar(u32, candidates.value_ptr.items, n.entity) == null) try candidates.value_ptr.append(a, n.entity);
        idx.alias_max = @max(idx.alias_max, x.len);
    };
}

fn nameEntry(idx: anytype, model: anytype, text: anytype, place: u32) !?Entry {
    const n = &model.notes.items[place];
    if (n.kind != .fact or !std.mem.eql(u8, model.attributes.items[n.attribute], "name")) return null;
    const value = nameValue(model.entities.items[n.entity], n.text()) orelse return null;
    const a = idx.arena.allocator();
    const spaced = try std.mem.concat(a, u8, &.{ " ", value });
    defer a.free(spaced);
    return encodeKeys(idx, text, spaced, place);
}
