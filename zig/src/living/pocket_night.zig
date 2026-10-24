//! A whole-night checkpoint, separate from the pocket's per-lesson rejection checkpoint.
const std = @import("std");

const lists = .{ "moe", "up", "down", "gate", "used", "learned", "pos", "taken", "refits", "refit_up", "refit_gate", "joint", "joint_down", "retired_lessons", "retired", "retired_w" };
const values = .{ "lesson", "learned_before", "pos_before", "retired_marks", "back", "phase", "split" };

pub fn Kept(comptime P: type) type {
    return struct { copy: P };
}

/// Keep the whole pocket only when no device or persistence recovery is outstanding.
pub fn mark(p: anytype, t: anytype, host: anytype) !void {
    if (p.night_pending or p.restore_pending or p.retire_pending or p.saved_mismatch or p.save_pending or p.forgot.held)
        return error.PocketUnresolved;
    try p.load(t, host);
    const kept = try p.gpa.create(Kept(@TypeOf(p.*)));
    kept.* = .{ .copy = .{ .gpa = p.gpa, .mode = p.mode, .hidden = p.hidden, .layers = p.layers } };
    errdefer free(p.gpa, kept);
    inline for (lists) |field| try @field(kept.copy, field).appendSlice(p.gpa, @field(p, field).items);
    inline for (values) |field| @field(kept.copy, field) = @field(p, field);
    drop(p);
    p.night_mark = kept;
}

/// Write the checkpoint before replacing live values; a failed write or upload retains it for another rewind.
pub fn rewind(p: anytype, t: anytype, host: anytype) !void {
    const kept = p.night_mark orelse return error.NothingToRewind;
    inline for (lists) |field| try @field(p, field).ensureTotalCapacity(p.gpa, @field(kept.copy, field).items.len);
    p.night_pending = true;
    if (p.written or p.save_pending or p.saved_mismatch or kept.copy.written) {
        _ = try kept.copy.save(t, host);
        p.written = true;
    }
    inline for (lists) |field| {
        @field(p, field).clearRetainingCapacity();
        @field(p, field).appendSliceAssumeCapacity(@field(kept.copy, field).items);
    }
    inline for (values) |field| @field(p, field) = @field(kept.copy, field);
    for (0..p.moe.items.len) |slot| try p.upload(t, host, slot);
    p.restore_pending = false;
    p.retire_pending = false;
    p.save_pending = false;
    p.saved_mismatch = false;
    p.snap.valid = false;
    @import("pocket_forget.zig").settle(p);
    p.read.deinit(p.gpa);
    p.read = .{};
    p.v.deinit(p.gpa);
    p.v = .{};
    p.answered = &.{};
    p.prompts = &.{};
    p.held = &.{};
    p.steady = &.{};
    p.replay_lessons = &.{};
    p.joint_answers.clearRetainingCapacity();
    p.night_pending = false;
    drop(p);
}

pub fn drop(p: anytype) void {
    const kept = p.night_mark orelse return;
    free(p.gpa, kept);
    p.night_mark = null;
}

fn free(a: std.mem.Allocator, kept: anytype) void {
    kept.copy.deinit();
    a.destroy(kept);
}
