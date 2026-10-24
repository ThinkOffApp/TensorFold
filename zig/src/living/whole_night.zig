//! Promotion's whole-night checkpoint includes replay ownership and the last settled lesson.
const std = @import("std");
const examples = @import("lesson_examples.zig");
const whole = @import("whole.zig");
const pocket = @import("pocket_night.zig");
const Example = examples.Example;

pub const Marked = struct {
    replay: []Example,
    replay_of: []u32,
    last: []Example,
    owned: examples.Lesson,
    answers: []Example,
    last_lesson: u32,
    lessons: u32,
    kept_rounds: u32,
    rounds: u64,
};

pub fn advance(l: anytype) !@import("learner.zig").Step {
    const operation = l.phase;
    l.phase = .idle;
    if (operation == .mark) try mark(l) else try rewind(l);
    return .{ .done = true, .changed = true };
}

pub fn mark(l: anytype) !void {
    if (!l.whole or l.method != .pocket) return error.MarksUnsupported;
    try whole.settle(l);
    const kept = try keepLessons(l);
    errdefer freeLessons(l.gpa, kept);
    try pocket.mark(&l.pockets, l.trainer.?, hooks(l));
    dropLessons(l);
    l.marked = kept;
}

pub fn rewind(l: anytype) !void {
    if (!l.whole or l.method != .pocket) return error.MarksUnsupported;
    const kept = l.marked orelse return error.NothingToRewind;
    try l.replay.ensureTotalCapacity(l.gpa, kept.replay.len);
    try l.replay_of.ensureTotalCapacity(l.gpa, kept.replay_of.len);
    try pocket.rewind(&l.pockets, l.trainer.?, hooks(l));
    for (l.replay.items) |ex| l.gpa.free(ex.ids);
    l.replay.clearRetainingCapacity();
    l.replay.appendSliceAssumeCapacity(kept.replay);
    l.gpa.free(kept.replay);
    l.replay_of.clearRetainingCapacity();
    l.replay_of.appendSliceAssumeCapacity(kept.replay_of);
    l.gpa.free(kept.replay_of);
    examples.disown(l.gpa, l.last);
    l.last = kept.last;
    l.gpa.free(l.answers);
    examples.disownLesson(l.gpa, l.owned);
    l.owned = kept.owned;
    l.lesson = l.owned;
    l.answers = kept.answers;
    l.last_lesson = kept.last_lesson;
    l.lessons = kept.lessons;
    l.kept_rounds = kept.kept_rounds;
    l.rounds = kept.rounds;
    l.pocketed = false;
    l.edited = false;
    l.live.clearRetainingCapacity();
    l.live_of.clearRetainingCapacity();
    for (l.extra.items) |ex| l.gpa.free(ex.ids);
    l.extra.clearRetainingCapacity();
    l.stay = @splat(&.{});
    l.marked = null;
}

fn hooks(l: anytype) whole.Hooks(@TypeOf(l.*).Host) {
    return .{ .b = l.b, .gpa = l.gpa, .io = l.io };
}

fn keepLessons(l: anytype) !Marked {
    const replay = try examples.own(l.gpa, l.replay.items);
    errdefer examples.disown(l.gpa, replay);
    const replay_of = try l.gpa.dupe(u32, l.replay_of.items);
    errdefer l.gpa.free(replay_of);
    const last = try examples.own(l.gpa, l.last);
    errdefer examples.disown(l.gpa, last);
    const owned = try examples.ownLesson(l.gpa, l.owned);
    errdefer examples.disownLesson(l.gpa, owned);
    const answers = try std.mem.concat(l.gpa, Example, &.{ owned.train, owned.think });
    return .{
        .replay = replay,
        .replay_of = replay_of,
        .last = last,
        .owned = owned,
        .answers = answers,
        .last_lesson = l.last_lesson,
        .lessons = l.lessons,
        .kept_rounds = l.kept_rounds,
        .rounds = l.rounds,
    };
}

pub fn dropLessons(l: anytype) void {
    const kept = l.marked orelse return;
    freeLessons(l.gpa, kept);
    l.marked = null;
}

fn freeLessons(a: std.mem.Allocator, kept: Marked) void {
    examples.disown(a, kept.replay);
    a.free(kept.replay_of);
    examples.disown(a, kept.last);
    a.free(kept.answers);
    examples.disownLesson(a, kept.owned);
}
