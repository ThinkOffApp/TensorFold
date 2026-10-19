//! A mark and its rewind: a night's lessons, refits, retires and saves undone to the same floats and the same bytes.
const std = @import("std");
const cfg = @import("config.zig");
const pocket_mod = @import("pocket.zig");
const pocket_mark = @import("pocket_mark.zig");
const whole = @import("whole.zig");
const examples = @import("lesson_examples.zig");
const pocket_shards = @import("pocket_shards.zig");
const core = struct {
    pub const shard_edit = @import("../../core/shard_edit.zig");
    pub const safetensors = @import("../../core/safetensors.zig");
    pub const affine4_host = @import("../../core/affine4_host.zig");
};
const Shards = pocket_shards.Io(core);
const host4 = core.affine4_host;
const Example = examples.Example;
const testing = std.testing;

const d = 64;
const own = 64; // the shared expert's own neurons
const n = pocket_mod.neurons;
const layers = 3; // two MoE layers with a pocket, then a Mamba layer

/// What the forward holds of each layer's pocket (an upload's copy), and the folder whose shards a save writes.
const Model = struct {
    dir: []const u8,
    c: cfg.Config,
    up: [layers][n * d]f32 = @splat(@splat(0)),
    down: [layers][n * d]f32 = @splat(@splat(0)),
    used: [layers]usize = @splat(0),
    saves: u32 = 0, // writes of the shards that went through
    fail_save: bool = false, // the next write fails before it writes anything (a full disk)
};

/// The host the pocket reaches through whole.zig's hooks.
const Forward = struct {
    pub const Ctx = *Model;

    pub fn pocket(m: Ctx, l: usize, up: []const f32, down: []const f32, used: usize) !void {
        @memcpy(&m.up[l], up);
        @memcpy(&m.down[l], down);
        m.used[l] = used;
    }

    pub fn pocketRead(_: Ctx, _: usize, _: []f32, _: []f32) usize {
        return 0;
    }

    pub fn pocketSave(m: Ctx, gpa: std.mem.Allocator, io: std.Io, moe: []const usize, neurons: usize, up: []f32, down: []f32) !usize {
        if (m.fail_save) {
            m.fail_save = false;
            return error.DiskFull;
        }
        m.saves += 1;
        return Shards.write(gpa, io, m.dir, m.c, moe, neurons, up, down);
    }

    pub fn seconds(_: std.Io) f64 {
        return 0;
    }
};

const Trainer = struct {
    c: cfg.Config,
    pub fn config(t: *const Trainer) cfg.Config {
        return t.c;
    }
};

/// The learner's fields whole.zig reads for a pocket: its lessons' bookkeeping beside the pocket.
const Learner = struct {
    pub const Host = Forward;
    gpa: std.mem.Allocator,
    io: std.Io,
    b: *Model,
    trainer: ?*Trainer,
    pockets: pocket_mod.Pocket(Trainer),
    method: whole.Method = .pocket,
    whole: bool = true,
    pocketed: bool = false,
    kept_rounds: u32 = 0,
    replay: std.ArrayList(Example) = .empty,
    replay_of: std.ArrayList(u32) = .empty,
    live: std.ArrayList(Example) = .empty,
    live_of: std.ArrayList(u32) = .empty,
    last: []Example = &.{},
    last_lesson: u32 = 0,
    lessons: u32 = 0,
    stay: [5][]const Example = @splat(&.{}),
    owned: examples.Lesson = .{},
    marked: ?whole.Marked = null,
    edits: void = {}, // no editor: a pocket's lessons only

    pub fn recalls(_: *Learner, _: []const Example, _: bool) !bool {
        return true;
    }

    fn hooks(l: *Learner) whole.Hooks(Forward) {
        return .{ .b = l.b, .gpa = l.gpa, .io = l.io };
    }

    fn deinit(l: *Learner) void {
        l.pockets.deinit();
        for (l.replay.items) |ex| l.gpa.free(ex.ids);
        l.replay.deinit(l.gpa);
        l.replay_of.deinit(l.gpa);
        l.live.deinit(l.gpa);
        l.live_of.deinit(l.gpa);
        examples.disown(l.gpa, l.last);
        whole.dropLessons(l);
    }

    /// A new lesson begun as the learner's begin does: the last one's answers into the replay if kept, the pocket open.
    fn begin(l: *Learner, ids: []const u32) !void {
        try l.pockets.load(l.trainer.?, l.hooks());
        const now = try examples.own(l.gpa, &.{.{ .ids = ids, .start = 1, .decide = 0 }});
        try whole.settle(l);
        if (l.kept_rounds > 0) {
            for (l.last) |ex| {
                try l.replay.append(l.gpa, ex);
                try l.replay_of.append(l.gpa, l.last_lesson);
            }
            l.gpa.free(l.last);
        } else examples.disown(l.gpa, l.last);
        l.last = now;
        l.last_lesson = l.lessons;
        l.lessons += 1;
        l.kept_rounds = 0;
        const p = &l.pockets;
        p.taken.clearRetainingCapacity();
        p.refits.clearRetainingCapacity();
        p.refit_up.clearRetainingCapacity();
        p.learned_before = p.learned.items.len;
        p.pos_before = p.pos.items.len;
        p.lesson = l.last_lesson;
        l.pocketed = true;
    }

    /// `k` neurons taken at slot `slot` as the pocket's own take does, their inputs, outputs and fact rows filled in.
    fn take(l: *Learner, r: std.Random, slot: usize, k: usize) !void {
        const p = &l.pockets;
        for (0..k) |_| {
            const at = p.used.items[slot];
            p.used.items[slot] += 1;
            try p.taken.append(p.gpa, .{ .slot = slot, .neuron = at, .key = .reply });
            for (p.neuron(p.up.items, slot, at, d)) |*x| x.* = r.floatNorm(f32) * 0.05;
            for (p.neuron(p.down.items, slot, at, d)) |*x| x.* = r.floatNorm(f32) * 0.2;
            const start = p.pos.items.len / d;
            for (0..3 * d) |_| try p.pos.append(p.gpa, r.int(u16));
            try p.learned.append(p.gpa, .{ .slot = slot, .neuron = at, .key = .reply, .start = start, .count = 3, .subject = 0, .lesson = p.lesson });
        }
        try p.upload(l.trainer.?, l.hooks(), slot);
    }

    /// Earlier neuron `i` (of `learned`) fitted again as the pocket's quiet does: its inputs moved, the old ones kept.
    fn refit(l: *Learner, r: std.Random, i: usize) !void {
        const p = &l.pockets;
        const e = p.learned.items[i];
        const u = p.neuron(p.up.items, e.slot, e.neuron, d);
        try p.refits.append(p.gpa, .{ .slot = e.slot, .neuron = e.neuron });
        try p.refit_up.appendSlice(p.gpa, u);
        for (u) |*x| x.* += r.floatNorm(f32) * 0.02;
        try p.upload(l.trainer.?, l.hooks(), e.slot);
    }
};

/// A folder with one shard: layers 0 and 1's shared experts (random codes), config.json telling their width.
fn folder(gpa: std.mem.Allocator, io: std.Io, tmp: *testing.TmpDir, r: std.Random) ![:0]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tensors: std.ArrayList(core.shard_edit.New) = .empty;
    for (0..2) |l| {
        const leaves = [_]struct { []const u8, core.safetensors.DType, [2]usize }{
            .{ "up_proj.weight", .u32, .{ own, d / 8 } },   .{ "up_proj.scales", .bf16, .{ own, d / 64 } },   .{ "up_proj.biases", .bf16, .{ own, d / 64 } },
            .{ "down_proj.weight", .u32, .{ d, own / 8 } }, .{ "down_proj.scales", .bf16, .{ d, own / 64 } }, .{ "down_proj.biases", .bf16, .{ d, own / 64 } },
        };
        for (leaves) |leaf| {
            const bytes = try a.alloc(u8, leaf[2][0] * leaf[2][1] * leaf[1].size());
            if (leaf[1] == .u32) r.bytes(bytes) else {
                for (std.mem.bytesAsSlice(u16, bytes)) |*h| h.* = host4.bf16of(0.01 + r.float(f32) * 0.01);
            }
            const name = try std.fmt.allocPrint(a, "backbone.layers.{d}.mixer.shared_experts.{s}", .{ l, leaf[0] });
            try tensors.append(a, .{ .name = name, .dtype = leaf[1], .shape = try a.dupe(usize, &leaf[2]), .bytes = bytes });
        }
    }
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    errdefer gpa.free(dir);
    try core.shard_edit.create(gpa, try std.fs.path.join(a, &.{ dir, "model.safetensors" }), &.{.{ "format", "mlx" }}, tensors.items);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"model_type\":\"nemotron_h\",\"moe_shared_expert_intermediate_size\":64}" });
    return dir;
}

fn modelConfig() cfg.Config {
    var c: cfg.Config = .{ .hidden = d, .vocab = 16, .layers = layers, .mamba_heads = 1, .mamba_head_dim = 1, .groups = 1, .state = 1, .conv_kernel = 4, .heads = 1, .kv_heads = 1, .head_dim = 1, .experts = 1, .top_k = 1, .expert_width = 64, .shared_width = own, .routed_scaling = 1, .eps = 1e-5 };
    c.kinds[0] = .moe;
    c.kinds[1] = .moe;
    c.kinds[2] = .mamba;
    return c;
}

/// A neuron's record in the pocket: its slot, neuron, key, rows and lesson.
const Learned = std.meta.Elem(@FieldType(@FieldType(pocket_mod.Pocket(Trainer), "learned"), "items"));

/// Everything a rewind is to bring back, copied: the pocket's lists and values, the learner's lessons.
const Copy = struct {
    arena: std.heap.ArenaAllocator,
    up: []const f32,
    down: []const f32,
    used: []const usize,
    pos: []const u16,
    learned: []const Learned,
    retired: []const [2]usize,
    retired_w: []const f32,
    retired_lessons: []const u32,
    refit_up: []const f32,
    values: [6]usize,
    replay: []const []const u32,
    replay_of: []const u32,
    last: []const []const u32,
    counts: [3]u32,

    fn of(gpa: std.mem.Allocator, l: *const Learner) !Copy {
        var c: Copy = undefined;
        c.arena = .init(gpa);
        const a = c.arena.allocator();
        const p = &l.pockets;
        c.up = try a.dupe(f32, p.up.items);
        c.down = try a.dupe(f32, p.down.items);
        c.used = try a.dupe(usize, p.used.items);
        c.pos = try a.dupe(u16, p.pos.items);
        c.learned = try a.dupe(Learned, p.learned.items);
        c.retired = try a.dupe([2]usize, p.retired.items);
        c.retired_w = try a.dupe(f32, p.retired_w.items);
        c.retired_lessons = try a.dupe(u32, p.retired_lessons.items);
        c.refit_up = try a.dupe(f32, p.refit_up.items);
        c.values = .{ p.lesson, p.learned_before, p.pos_before, p.retired_marks, p.taken.items.len, p.refits.items.len };
        const replay = try a.alloc([]const u32, l.replay.items.len);
        for (l.replay.items, replay) |ex, *x| x.* = try a.dupe(u32, ex.ids);
        c.replay = replay;
        c.replay_of = try a.dupe(u32, l.replay_of.items);
        const last = try a.alloc([]const u32, l.last.len);
        for (l.last, last) |ex, *x| x.* = try a.dupe(u32, ex.ids);
        c.last = last;
        c.counts = .{ l.last_lesson, l.lessons, l.kept_rounds };
        return c;
    }

    /// The learner now against this copy, byte for byte; the forward's copy of every slot too.
    fn expectSame(c: *const Copy, l: *const Learner) !void {
        const p = &l.pockets;
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(c.up), std.mem.sliceAsBytes(p.up.items));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(c.down), std.mem.sliceAsBytes(p.down.items));
        try testing.expectEqualSlices(usize, c.used, p.used.items);
        try testing.expectEqualSlices(u16, c.pos, p.pos.items);
        try testing.expectEqual(c.learned.len, p.learned.items.len);
        for (c.learned, p.learned.items) |x, y| try testing.expect(std.meta.eql(x, y));
        try testing.expectEqualSlices([2]usize, c.retired, p.retired.items);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(c.retired_w), std.mem.sliceAsBytes(p.retired_w.items));
        try testing.expectEqualSlices(u32, c.retired_lessons, p.retired_lessons.items);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(c.refit_up), std.mem.sliceAsBytes(p.refit_up.items));
        try testing.expectEqual(c.values, [6]usize{ p.lesson, p.learned_before, p.pos_before, p.retired_marks, p.taken.items.len, p.refits.items.len });
        try testing.expectEqual(c.replay.len, l.replay.items.len);
        for (c.replay, l.replay.items) |x, ex| try testing.expectEqualSlices(u32, x, ex.ids);
        try testing.expectEqualSlices(u32, c.replay_of, l.replay_of.items);
        try testing.expectEqual(c.last.len, l.last.len);
        for (c.last, l.last) |x, ex| try testing.expectEqualSlices(u32, x, ex.ids);
        try testing.expectEqual(c.counts, [3]u32{ l.last_lesson, l.lessons, l.kept_rounds });
        for (p.moe.items, 0..) |layer, j| {
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(p.up.items[j * n * d ..][0 .. n * d]), std.mem.sliceAsBytes(&l.b.up[layer]));
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(p.down.items[j * n * d ..][0 .. n * d]), std.mem.sliceAsBytes(&l.b.down[layer]));
            try testing.expectEqual(p.used.items[j], l.b.used[layer]);
        }
    }

    fn deinit(c: *Copy) void {
        c.arena.deinit();
    }
};

/// Two facts taught and saved, as a night finds the pocket: fact 0 at both layers, fact 1 at the second.
fn day(l: *Learner, r: std.Random) !void {
    try l.begin(&.{ 1, 2, 3 });
    try l.take(r, 0, 3);
    try l.take(r, 1, 2);
    l.kept_rounds = 1;
    try l.begin(&.{ 4, 5, 6 });
    try l.take(r, 1, 3);
    l.kept_rounds = 1;
    try testing.expect(try whole.save(l));
}

/// A night: a fact kept that refits fact 0's neuron, saved; fact 1 retired, saved; a fact given up at the next save.
fn night(l: *Learner, r: std.Random) !void {
    try l.begin(&.{ 7, 8, 9 });
    try l.take(r, 0, 2);
    try l.take(r, 1, 2);
    try l.refit(r, 0); // fact 0's first neuron
    l.kept_rounds = 1;
    try testing.expect(try whole.save(l));
    try testing.expect(try whole.retire(l, &.{ .{ 1, 2 }, .{ 1, 3 }, .{ 1, 4 } }, false));
    try testing.expect(try whole.save(l));
    try l.begin(&.{ 10, 11 });
    try l.take(r, 0, 1);
    try l.refit(r, 3);
    try testing.expect(try whole.save(l));
}

fn shard(tmp: *testing.TmpDir, a: std.mem.Allocator) ![]const u8 {
    return tmp.dir.readFileAlloc(testing.io, "model.safetensors", a, .limited(1 << 24));
}

fn learner(gpa: std.mem.Allocator, m: *Model, t: *Trainer) Learner {
    return .{ .gpa = gpa, .io = testing.io, .b = m, .trainer = t, .pockets = .{ .gpa = gpa, .mode = .reply } };
}

test "a rewind brings a night's pocket back to the mark: refits, retires, 4-bit roundings, the lessons and the bytes" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try day(&l, r);
    const saved = try shard(&tmp, arena.allocator());
    try whole.mark(&l);
    var at_mark = try Copy.of(gpa, &l);
    defer at_mark.deinit();
    try night(&l, r);
    // the night moved what it should: the floats, the counts, the replay, and the bytes in the shard
    try testing.expect(!std.mem.eql(f32, at_mark.up, l.pockets.up.items));
    try testing.expect(!std.mem.eql(usize, at_mark.used, l.pockets.used.items));
    try testing.expect(l.replay.items.len > at_mark.replay.len);
    try testing.expect(!std.mem.eql(u8, saved, try shard(&tmp, arena.allocator())));
    const night_saves = m.saves;
    try whole.rewind(&l);
    try at_mark.expectSame(&l);
    try testing.expect(l.pockets.marked == null and l.marked == null);
    // the rewind wrote the files itself: the same bytes as before the night
    try testing.expectEqual(night_saves + 1, m.saves);
    try testing.expectEqualSlices(u8, saved, try shard(&tmp, arena.allocator()));
    // saved again from the restored floats: the same bytes again, the floats left as they are
    const saves = m.saves;
    try testing.expect(try whole.save(&l));
    try testing.expectEqual(saves + 1, m.saves);
    try testing.expectEqualSlices(u8, saved, try shard(&tmp, arena.allocator()));
    try at_mark.expectSame(&l);
    // a second rewind has no mark to go back to: an error, never a silent no-op
    try testing.expectError(error.NothingToRewind, whole.rewind(&l));
    try testing.expectError(error.NothingToRewind, pocket_mark.rewind(&l.pockets, &t, l.hooks()));
}

test "control: zeroing only the night's own neurons leaves its refits and roundings in the floats and the bytes" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try day(&l, r);
    const saved = try shard(&tmp, arena.allocator());
    const up = try arena.allocator().dupe(f32, l.pockets.up.items);
    try night(&l, r);
    // the undo before the mark: the night's neurons zeroed, saved again
    try testing.expect(try whole.retire(&l, &.{ .{ 0, 3 }, .{ 0, 4 }, .{ 1, 5 }, .{ 1, 6 } }, false));
    try testing.expect(try whole.save(&l));
    try testing.expect(!std.mem.eql(f32, up, l.pockets.up.items));
    try testing.expect(!std.mem.eql(u8, saved, try shard(&tmp, arena.allocator())));
}

test "a pocket empty at the mark is written empty by the rewind, though the night's saves widened the shards" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try testing.expect(try whole.save(&l)); // nothing learned: nothing written, the shards not widened
    try testing.expectEqual(@as(u32, 0), m.saves);
    try whole.mark(&l);
    try l.begin(&.{ 1, 2 });
    try l.take(r, 0, 2);
    l.kept_rounds = 1;
    try testing.expect(try whole.save(&l));
    try testing.expectEqual(@as(u32, 1), m.saves);
    try whole.rewind(&l);
    try testing.expect(l.pockets.empty());
    try testing.expectEqual(@as(u32, 2), m.saves);
    // the learned rows of layer 0's up_proj read back as zero: the night's neurons are out of the files
    try expectZeroRows(gpa, try std.fs.path.join(arena.allocator(), &.{ dir, "model.safetensors" }), 2);
}

/// The first `k` learned rows of layer 0's up_proj in the shard at `path` read back as zero.
fn expectZeroRows(gpa: std.mem.Allocator, path: []const u8, k: usize) !void {
    var f = try core.safetensors.File.open(gpa, testing.io, path);
    defer f.close(testing.io);
    const uw = f.get("backbone.layers.0.mixer.shared_experts.up_proj.weight").?;
    const us = f.get("backbone.layers.0.mixer.shared_experts.up_proj.scales").?;
    const ub = f.get("backbone.layers.0.mixer.shared_experts.up_proj.biases").?;
    try testing.expect(uw.is(.u32, &.{ own + n, d / 8 }));
    var words: [d / 8]u32 = undefined;
    var back: [d]f32 = undefined;
    for (0..k) |i| {
        const row = own + i;
        for (&words, std.mem.bytesAsSlice(u32, uw.bytes[row * d / 2 ..][0 .. d / 2])) |*x, y| x.* = y;
        const s: []align(1) const u16 = std.mem.bytesAsSlice(u16, us.bytes[row * 2 ..][0..2]);
        const b: []align(1) const u16 = std.mem.bytesAsSlice(u16, ub.bytes[row * 2 ..][0..2]);
        host4.dequantize(&words, &.{s[0]}, &.{b[0]}, &back);
        for (back) |x| try testing.expectEqual(@as(f32, 0), x);
    }
}

test "a second mark replaces the first; a rewind goes back to the latest" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try day(&l, r);
    try whole.mark(&l);
    try l.begin(&.{ 20, 21 });
    try l.take(r, 1, 1);
    l.kept_rounds = 1;
    try testing.expect(try whole.save(&l)); // the rewind writes the files: a mark of saved floats comes back exactly
    try whole.mark(&l);
    var second = try Copy.of(gpa, &l);
    defer second.deinit();
    try l.begin(&.{ 22, 23 });
    try l.take(r, 0, 2);
    try l.refit(r, 1);
    l.kept_rounds = 1;
    try whole.rewind(&l);
    try second.expectSame(&l);
}

test "a lesson open at the mark is settled first: an unkept one's neurons do not come back with the rewind" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var prng = std.Random.DefaultPrng.init(9);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try day(&l, r);
    const used = try gpa.dupe(usize, l.pockets.used.items);
    defer gpa.free(used);
    // a lesson whose rounds never came back, still open: the next lesson's begin would take it out
    try l.begin(&.{ 30, 31 });
    try l.take(r, 0, 2);
    try whole.mark(&l);
    try testing.expect(!l.pocketed);
    try testing.expectEqualSlices(usize, used, l.pockets.used.items);
    try night(&l, r);
    try whole.rewind(&l);
    try testing.expectEqualSlices(usize, used, l.pockets.used.items);
    try testing.expectEqualSlices(usize, used, &.{ m.used[0], m.used[1] });
}

test "a rewind whose write fails changes nothing: the night stays in memory, the forward and the files, the mark too" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(13);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try day(&l, r);
    const saved = try shard(&tmp, arena.allocator());
    try whole.mark(&l);
    var at_mark = try Copy.of(gpa, &l);
    defer at_mark.deinit();
    try night(&l, r);
    var at_night = try Copy.of(gpa, &l);
    defer at_night.deinit();
    const night_bytes = try shard(&tmp, arena.allocator());
    // the disk is full: the rewind fails, and memory, the forward, the night's places and the files keep the night
    m.fail_save = true;
    try testing.expectError(error.DiskFull, whole.rewind(&l));
    try at_night.expectSame(&l);
    try testing.expectEqualSlices(u8, night_bytes, try shard(&tmp, arena.allocator()));
    try testing.expect(l.pockets.marked != null and l.marked != null);
    // the disk back: the same rewind goes through to the mark, in memory and in the files
    try whole.rewind(&l);
    try at_mark.expectSame(&l);
    try testing.expectEqualSlices(u8, saved, try shard(&tmp, arena.allocator()));
}

test "an undo after a save empties the pocket, and the next save still writes it: the shards held the lesson" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(17);
    const r = prng.random();
    const dir = try folder(gpa, testing.io, &tmp, r);
    defer gpa.free(dir);
    var m: Model = .{ .dir = dir, .c = modelConfig() };
    var t: Trainer = .{ .c = m.c };
    var l = learner(gpa, &m, &t);
    defer l.deinit();
    try l.begin(&.{ 1, 2 });
    try l.take(r, 0, 2);
    l.kept_rounds = 1;
    try testing.expect(try whole.save(&l));
    try testing.expect(try whole.undo(&l));
    try testing.expect(l.pockets.empty());
    try testing.expect(try whole.save(&l));
    try testing.expectEqual(@as(u32, 2), m.saves);
    try expectZeroRows(gpa, try std.fs.path.join(arena.allocator(), &.{ dir, "model.safetensors" }), 2);
}
