//! A night restores the teacher's accepted answers and lesson rotation alongside the model's weights.
const std = @import("std");
const api = @import("engine_api");
const teacher = @import("slide_teacher.zig");
const Allocator = std.mem.Allocator;

pub const Kept = struct {
    lessons: usize,
    told: []teacher.Told,
    keep: ?[]api.Example,
    bank: ?[]teacher.Banked,
    languages: std.StringHashMapUnmanaged(teacher.Local),

    pub fn deinit(k: *Kept, a: Allocator) void {
        a.free(k.told);
        if (k.keep) |x| a.free(x);
        if (k.bank) |x| a.free(x);
        k.languages.deinit(a);
    }
};

pub fn keep(t: *teacher.Teacher, io: std.Io, a: Allocator) !Kept {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    const told = try a.dupe(teacher.Told, t.told.items);
    errdefer a.free(told);
    const answers = if (t.keep) |x| try a.dupe(api.Example, x) else null;
    errdefer if (answers) |x| a.free(x);
    const bank = if (t.bank) |x| try a.dupe(teacher.Banked, x) else null;
    errdefer if (bank) |x| a.free(x);
    return .{ .lessons = t.lessons, .told = told, .keep = answers, .bank = bank, .languages = try t.languages.clone(a) };
}

pub fn restore(t: *teacher.Teacher, io: std.Io, k: Kept) !void {
    t.mutex.lockUncancelable(io);
    defer t.mutex.unlock(io);
    const a = t.arena.allocator();
    const told = try a.dupe(teacher.Told, k.told);
    const answers = if (k.keep) |x| try a.dupe(api.Example, x) else null;
    const bank = if (k.bank) |x| try a.dupe(teacher.Banked, x) else null;
    const languages = try k.languages.clone(a);
    t.lessons = k.lessons;
    t.told = .fromOwnedSlice(told);
    t.keep = answers;
    t.bank = bank;
    t.languages = languages;
}

test "promotion: teacher rewind restores removed document answers, cached answers, languages and rotation" {
    const testing = std.testing;
    var t = teacher.Teacher.init(testing.allocator);
    defer t.deinit();
    const a = t.arena.allocator();
    try t.remember("boat", "Boat?", "Blue.");
    t.ended(true);
    t.keep = try a.dupe(api.Example, &.{.{ .ids = &.{ 1, 2 }, .start = 1, .decide = 0 }});
    t.bank = try a.dupe(teacher.Banked, &.{.{ .question = "Q", .before = "old", .ex = t.keep.?[0] }});
    try t.languages.put(a, "de", .{ .keep = t.keep.?, .personal = &.{} });
    var k = try keep(&t, testing.io, testing.allocator);
    defer k.deinit(testing.allocator);
    t.forgetFact(testing.io, &.{"Boat?"});
    try t.remember("tent", "Tent?", "Red.");
    t.ended(true);
    t.keep = try a.dupe(api.Example, &.{.{ .ids = &.{ 3, 4 }, .start = 1, .decide = 0 }});
    try t.languages.put(a, "fi", .{ .keep = t.keep.?, .personal = &.{} });
    try restore(&t, testing.io, k);
    try testing.expectEqual(@as(usize, 1), t.lessons);
    try testing.expectEqualStrings("Boat?", t.told.items[0].question);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, t.keep.?[0].ids);
    try testing.expectEqualStrings("old", t.bank.?[0].before);
    try testing.expect(t.languages.contains("de") and !t.languages.contains("fi"));
}
