//! A merge off the writer's path: a new suffix-array core built on its own thread from a frozen copy of the notes.
const std = @import("std");
const index = @import("index.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const sa = @import("sa.zig");
const Allocator = std.mem.Allocator;

/// Tests only: while set, a merge waits before it builds (so writes come in during it).
pub var hold: std.atomic.Value(bool) = .init(false);

/// One merge in flight: the copy it reads, and the core it made once `done`.
pub const Job = struct {
    gpa: Allocator,
    frozen: *Model, // the model's lists copied as the write that started it left them; the bytes they point to shared
    mark: usize, // how many retired places the store had listed then: the ones after it are the new core's
    prev: ?*sa.Base, // retained: the current core's base, merged linearly with the notes after it (null: built anew)
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    result: ?*index.Index = null,

    /// Starts a merge of every note in `m` (the writer's lock held: nothing changes while it copies).
    pub fn start(gpa: Allocator, m: *const Model, mark: usize, prev: ?*sa.Base) !*Job {
        const fm = try freeze(gpa, m);
        errdefer thaw(gpa, fm);
        const j = try gpa.create(Job);
        errdefer gpa.destroy(j);
        j.* = .{ .gpa = gpa, .frozen = fm, .mark = mark, .prev = if (prev) |b| b.retain() else null };
        errdefer if (j.prev) |b| b.release();
        j.thread = try std.Thread.spawn(.{}, run, .{j});
        return j;
    }

    fn run(j: *Job) void {
        while (hold.load(.acquire)) std.atomic.spinLoopHint();
        j.result = index.Index.buildMerging(j.gpa, j.frozen, .sa, j.prev) catch null; // null: the next merge starts again
        j.done.store(true, .release);
    }

    pub fn ready(j: *const Job) bool {
        return j.done.load(.acquire);
    }

    /// Waits for the merge, frees the job and its copy; the core it made (the caller's reference), or null.
    pub fn finish(j: *Job) ?*index.Index {
        j.thread.join();
        const r = j.result;
        thaw(j.gpa, j.frozen);
        if (j.prev) |b| b.release();
        j.gpa.destroy(j);
        return r;
    }
};

/// A model whose lists are copies; the bodies, names and vocabulary they point to stay (a build keeps lines as slices).
fn freeze(gpa: Allocator, m: *const Model) Allocator.Error!*Model {
    const fm = try gpa.create(Model);
    errdefer gpa.destroy(fm);
    fm.* = m.*;
    fm.ix = .{}; // unused by a build
    fm.notes = .empty;
    fm.pairs = .empty;
    fm.phrases = .empty;
    fm.entities = .empty;
    fm.attributes = .empty;
    errdefer thawLists(gpa, fm);
    fm.notes = .fromOwnedSlice(try gpa.dupe(model_mod.Note, m.notes.items));
    fm.phrases = .fromOwnedSlice(try gpa.dupe(model_mod.Phrase, m.phrases.items));
    fm.entities = .fromOwnedSlice(try gpa.dupe([]u8, m.entities.items));
    fm.attributes = .fromOwnedSlice(try gpa.dupe([]u8, m.attributes.items));
    const pairs = try gpa.alloc(model_mod.Pair, m.pairs.items.len);
    for (pairs) |*p| p.* = .{ .entity = 0, .attribute = 0 };
    fm.pairs = .fromOwnedSlice(pairs);
    for (m.pairs.items, pairs) |p, *q| q.* = .{ .entity = p.entity, .attribute = p.attribute, .ids = .fromOwnedSlice(try gpa.dupe(u32, p.ids.items)) };
    return fm;
}

fn thawLists(gpa: Allocator, fm: *Model) void {
    gpa.free(fm.notes.items);
    gpa.free(fm.phrases.items);
    gpa.free(fm.entities.items);
    gpa.free(fm.attributes.items);
    for (fm.pairs.items) |p| gpa.free(p.ids.items);
    gpa.free(fm.pairs.items);
}

/// Frees what freeze() copied, never what the copies point to.
fn thaw(gpa: Allocator, fm: *Model) void {
    thawLists(gpa, fm);
    gpa.destroy(fm);
}
