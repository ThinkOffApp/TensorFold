//! The scripted learner promotion's host tests run nights against: a fake store, pocket and model.
const std = @import("std");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const Allocator = std.mem.Allocator;
const Neuron = promote.Neuron;

/// A note as the fake store keeps it; its text is "topic=value".
const FNote = struct { id: u32, key: []const u8, text: []const u8, told: i64, fact: bool = true, current: bool = true };

/// A taught fact in the fake pocket: its topic, value and neurons (live until retired).
pub const Live = struct { topic: []const u8, value: []const u8, neurons: []const Neuron, live: bool = true, breaks: bool = false, clobbers: bool = false, text: []const u8 = "", fits: u32 = 0 };

pub const Fake = struct {
    a: Allocator,
    store: std.ArrayList(FNote) = .empty,
    pocket: std.ArrayList(Live) = .empty,
    retrieved: std.ArrayList([]const u8) = .empty,
    misses: []const []const u8 = &.{}, // texts the learner does not keep
    breaks: []const u8 = "", // a text whose neurons, taught from now on and while live, change a control's answer
    weak: []const u8 = "", // a topic the neurons do not answer alone
    clobbers: []const u8 = "", // a text whose neurons, while live, make `clobbered` answer wrong even with its note
    clobbered: []const u8 = "",
    miss_once: []const u8 = "", // a text the learner misses the first time only
    questions: u32 = 0, // notes' own questions written
    pairs: u32 = 0, // two-note questions written
    leaks: []const u8 = "", // a text whose neurons, while live, answer every neighbour question with its value
    flips: []const u8 = "", // a text whose neurons, while live, answer two-note questions "No"
    invents: []const u8 = "", // a text whose neurons, while live, make up an answer to the untold questions
    hedged_invent: bool = false, // the made-up answer wrapped in a don't-know
    crash_at_teach: ?u32 = null, // the teach call to stop at (a crash): error.Crash
    refits: []const u8 = "", // a text whose lesson fits every earlier live fact's neurons again, as the pocket's refits do
    marked: ?[]Live = null, // the pocket as the last mark kept it, and its next neuron
    marked_next: u16 = 0,
    teaches: u32 = 0,
    retires: u32 = 0,
    retired: std.ArrayList(Neuron) = .empty,
    next_neuron: u16 = 0,
    saved: ?[]u8 = null, // the last state persisted, as the file would hold it
    saves: u32 = 0,
    clock: i64 = 1000,

    pub fn topic(text: []const u8) []const u8 {
        return text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
    }
    fn val(text: []const u8) []const u8 {
        const at = std.mem.indexOfScalar(u8, text, '=') orelse return "";
        return text[at + 1 ..];
    }

    pub fn add(f: *Fake, key: []const u8, text: []const u8) !u32 {
        const id: u32 = @intCast(f.store.items.len + 1);
        try f.store.append(f.a, .{ .id = id, .key = key, .text = text, .told = @as(i64, id) * 100 });
        try f.retrieved.append(f.a, key);
        return id;
    }

    /// A change: the old note is no longer current, a new one (a new key) is.
    pub fn change(f: *Fake, old: []const u8, key: []const u8, text: []const u8) !void {
        for (f.store.items) |*n| if (std.mem.eql(u8, n.key, old)) {
            n.current = false;
        };
        _ = try f.add(key, text);
    }

    pub fn notes(f: *Fake, a: Allocator) ![]promote.Note {
        var out: std.ArrayList(promote.Note) = .empty;
        for (f.store.items) |n| if (n.current) try out.append(a, .{ .id = n.id, .key = n.key, .text = n.text, .told = n.told, .fact = n.fact });
        return out.items;
    }
    pub fn firstSeen(_: *Fake, _: []const u8) ?u32 {
        return null;
    }
    pub fn wasRetrieved(f: *Fake, key: []const u8) bool {
        for (f.retrieved.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }
    pub fn nowMs(f: *Fake) i64 {
        f.clock += 1;
        return f.clock;
    }
    pub fn teach(f: *Fake, a: Allocator, text: []const u8) !promote.Taught {
        f.teaches += 1;
        if (f.crash_at_teach) |c| if (c == f.teaches) return error.Crash;
        for (f.misses) |m| if (std.mem.eql(u8, m, text)) return .{ .kept = false, .why = "too few clean answers to learn from" };
        if (f.miss_once.len > 0 and std.mem.eql(u8, f.miss_once, text)) {
            f.miss_once = "";
            return .{ .kept = false, .why = "missed once" };
        }
        if (std.mem.eql(u8, text, f.refits)) for (f.pocket.items) |*l| if (l.live) {
            l.fits += 1;
        };
        const ns = try f.a.alloc(Neuron, 2);
        for (ns) |*n| {
            n.* = .{ .layer = 1, .neuron = f.next_neuron, .key = .reply };
            f.next_neuron += 1;
        }
        try f.pocket.append(f.a, .{ .topic = topic(text), .value = val(text), .neurons = ns, .breaks = std.mem.eql(u8, text, f.breaks), .clobbers = std.mem.eql(u8, text, f.clobbers), .text = text });
        const q = try std.fmt.allocPrint(a, "Q:{s}", .{topic(text)});
        return .{ .kept = true, .neurons = ns, .questions = try a.dupe([]const u8, &.{ q, q, q, q, q }) };
    }
    pub fn placedFor(f: *Fake, a: Allocator, text: []const u8) ![]const Neuron {
        var out: std.ArrayList(Neuron) = .empty;
        for (f.pocket.items) |l| if (l.live and std.mem.eql(u8, l.topic, topic(text)) and std.mem.eql(u8, l.value, val(text))) try out.appendSlice(a, l.neurons);
        return out.items;
    }
    pub fn neighbours(_: *Fake, a: Allocator, q: []const u8) ![]const []const u8 {
        return a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "N:{s}", .{q[2..]})});
    }
    pub fn pairQuestion(f: *Fake, a: Allocator, one: []const u8, two: []const u8) ![]const u8 {
        f.pairs += 1;
        return std.fmt.allocPrint(a, "P:{s}+{s}", .{ topic(one), topic(two) });
    }
    pub fn texts(f: *Fake, a: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (f.store.items) |n| if (n.current) try out.append(a, n.text);
        return out.items;
    }
    pub fn recordProbe(_: *Fake, _: u32, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: bool) void {}
    pub fn questionOf(f: *Fake, a: Allocator, text: []const u8) ![]const u8 {
        f.questions += 1;
        return std.fmt.allocPrint(a, "Q:{s}", .{topic(text)});
    }
    pub fn references(_: *Fake, a: Allocator, fact: []const u8, qs: []const []const u8) ![]const []const u8 {
        const out = try a.alloc([]const u8, qs.len);
        for (out, qs) |*r, q| r.* = if (std.mem.startsWith(u8, q, "P:")) "Yes." else val(fact);
        return out;
    }
    fn live(f: *Fake, text: []const u8) ?Live {
        if (text.len == 0) return null;
        for (f.pocket.items) |l| if (l.live and std.mem.eql(u8, l.text, text)) return l;
        return null;
    }
    fn answer(f: *Fake, q: promote.Ask) []const u8 {
        if (std.mem.startsWith(u8, q.q, "N:")) return if (f.live(f.leaks)) |l| l.value else "I don't know.";
        if (std.mem.startsWith(u8, q.q, "P:")) return if (f.live(f.flips) != null) "No." else "Yes.";
        for (@import("notes/promote_probes.zig").untold) |u| if (std.mem.eql(u8, u, q.q)) return if (f.live(f.invents) == null) "I don't know your rabbit's name." else if (f.hedged_invent) "I don't know for sure, but your rabbit is named Floppy." else "Floppy.";
        if (!std.mem.startsWith(u8, q.q, "Q:")) {
            for (f.pocket.items) |l| if (l.live and l.breaks) return "Lyon";
            return "Paris";
        }
        const t = q.q[2..];
        for (f.pocket.items) |l| if (l.live and l.clobbers and std.mem.eql(u8, t, f.clobbered)) return "wrong";
        if (q.exclude) |ex| for (f.store.items) |n| {
            if (!n.current or std.mem.indexOfScalar(u32, ex, n.id) != null or !std.mem.eql(u8, topic(n.text), t)) continue;
            return val(n.text);
        };
        if (std.mem.eql(u8, t, f.weak)) return "unknown";
        var i = f.pocket.items.len;
        while (i > 0) : (i -= 1) {
            const l = f.pocket.items[i - 1];
            if (l.live and std.mem.eql(u8, l.topic, t)) return l.value;
        }
        return "unknown";
    }
    pub fn askAll(f: *Fake, a: Allocator, qs: []const promote.Ask) ![]const []const u8 {
        const out = try a.alloc([]const u8, qs.len);
        for (qs, out) |q, *r| r.* = f.answer(q);
        return out;
    }
    pub fn agrees(_: *Fake, _: []const u8, _: []const u8, ref: []const u8, reply: []const u8) bool {
        return std.mem.eql(u8, ref, reply);
    }
    pub fn same(_: *Fake, _: Allocator, _: []const u8, before: []const u8, reply: []const u8) !bool {
        return std.mem.eql(u8, before, reply);
    }
    pub fn retire(f: *Fake, _: Allocator, ns: []const Neuron) !void {
        f.retires += 1;
        try f.retired.appendSlice(f.a, ns);
        for (f.pocket.items) |*l| for (l.neurons) |n| if (promote.has(ns, n)) {
            l.live = false;
        };
    }
    pub fn mark(f: *Fake, _: Allocator) !void {
        f.marked = try f.a.dupe(Live, f.pocket.items);
        f.marked_next = f.next_neuron;
    }
    pub fn rewind(f: *Fake, _: Allocator) !void {
        const m = f.marked orelse return error.NothingToRewind;
        f.pocket.clearRetainingCapacity();
        try f.pocket.appendSlice(f.a, m);
        f.next_neuron = f.marked_next;
        f.marked = null;
    }
    pub fn persist(f: *Fake, s: *const promote.State) !void {
        f.saves += 1;
        f.saved = try pjson.encode(s, f.a);
    }

    pub fn liveCount(f: *const Fake) usize {
        var n: usize = 0;
        for (f.pocket.items) |l| n += @intFromBool(l.live);
        return n;
    }
};
