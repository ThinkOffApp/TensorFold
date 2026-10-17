//! Nightly promotion against a scripted learner: qualify, teach, regress, alone, stale rebuilds and restarts.
const std = @import("std");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Neuron = promote.Neuron;

/// A note as the fake store keeps it; its text is "topic=value".
const FNote = struct { id: u32, key: []const u8, text: []const u8, told: i64, fact: bool = true, current: bool = true };

/// A taught fact in the fake pocket: its topic, value and neurons (live until retired).
const Live = struct { topic: []const u8, value: []const u8, neurons: []const Neuron, live: bool = true, breaks: bool = false };

const Fake = struct {
    a: Allocator,
    store: std.ArrayList(FNote) = .empty,
    pocket: std.ArrayList(Live) = .empty,
    retrieved: std.ArrayList([]const u8) = .empty,
    misses: []const []const u8 = &.{}, // texts the learner does not keep
    breaks: []const u8 = "", // a text whose neurons, taught from now on and while live, change a control's answer
    weak: []const u8 = "", // a topic the neurons do not answer alone
    crash_at_teach: ?u32 = null, // the teach call to stop at (a crash): error.Crash
    teaches: u32 = 0,
    retires: u32 = 0,
    retired: std.ArrayList(Neuron) = .empty,
    next_neuron: u16 = 0,
    saved: ?[]u8 = null, // the last state persisted, as the file would hold it
    saves: u32 = 0,
    clock: i64 = 1000,

    fn topic(text: []const u8) []const u8 {
        return text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
    }
    fn val(text: []const u8) []const u8 {
        const at = std.mem.indexOfScalar(u8, text, '=') orelse return "";
        return text[at + 1 ..];
    }

    fn add(f: *Fake, key: []const u8, text: []const u8) !u32 {
        const id: u32 = @intCast(f.store.items.len + 1);
        try f.store.append(f.a, .{ .id = id, .key = key, .text = text, .told = @as(i64, id) * 100 });
        try f.retrieved.append(f.a, key);
        return id;
    }

    /// A change: the old note is no longer current, a new one (a new key) is.
    fn change(f: *Fake, old: []const u8, key: []const u8, text: []const u8) !void {
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
        const ns = try f.a.alloc(Neuron, 2);
        for (ns) |*n| {
            n.* = .{ .layer = 1, .neuron = f.next_neuron, .key = .reply };
            f.next_neuron += 1;
        }
        try f.pocket.append(f.a, .{ .topic = topic(text), .value = val(text), .neurons = ns, .breaks = std.mem.eql(u8, text, f.breaks) });
        const q = try std.fmt.allocPrint(a, "Q:{s}", .{topic(text)});
        return .{ .kept = true, .neurons = ns, .questions = try a.dupe([]const u8, &.{ q, q, q, q, q }) };
    }
    pub fn references(_: *Fake, a: Allocator, fact: []const u8, qs: []const []const u8) ![]const []const u8 {
        const out = try a.alloc([]const u8, qs.len);
        for (out) |*r| r.* = val(fact);
        return out;
    }
    fn answer(f: *Fake, q: promote.Ask) []const u8 {
        if (!std.mem.startsWith(u8, q.q, "Q:")) {
            for (f.pocket.items) |l| if (l.live and l.breaks) return "Lyon";
            return "Paris";
        }
        const t = q.q[2..];
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
    pub fn persist(f: *Fake, s: *const promote.State) !void {
        f.saves += 1;
        f.saved = try pjson.encode(s, f.a);
    }

    fn liveCount(f: *const Fake) usize {
        var n: usize = 0;
        for (f.pocket.items) |l| n += @intFromBool(l.live);
        return n;
    }
};

fn status(s: *promote.State, key: []const u8) promote.Status {
    return (s.find(key) orelse return .note).status;
}

fn run(s: *promote.State, f: *Fake, arena: *std.heap.ArenaAllocator) !promote.NightLog {
    return promote.night(s, arena.allocator(), f);
}

test "promotion: a used note is due after hold nights; unused, take-backs and dated notes never are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "boat=blue");
    f.retrieved.items.len = 1; // w2 never in a block
    try f.store.append(f.a, .{ .id = 3, .key = "w3", .text = "cheese=no", .told = 300, .fact = false }); // a take-back
    _ = try f.add("w4", "home=Porto since 2019");
    var s = promote.State.init(testing.allocator, .{ .hold = 2 });
    defer s.deinit();
    const n1 = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 0), n1.due); // one night old: not yet with hold 2
    try testing.expectEqual(@as(u32, 0), f.teaches);
    const n2 = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 1), n2.due);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
    try testing.expectEqual(promote.Status.note, status(&s, "w2"));
    try testing.expect(s.find("w3") == null);
    try testing.expectEqual(promote.Status.note, status(&s, "w4"));
    try testing.expect(promote.dated("I moved in 2019.") and promote.dated("Until March I lived in Turku.") and !promote.dated("My PIN is 12345.") and !promote.dated("My dog is Luna."));
}

test "promotion: a kept fact is promoted, a missed one stays a note; two nights alone and its note leaves the prompt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator(), .misses = &.{"cat=green"} };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "cat=green");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    const n1 = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 2), n1.taught);
    try testing.expectEqual(@as(u32, 1), n1.kept);
    try testing.expectEqual(@as(u32, 1), n1.missed);
    try testing.expectEqualStrings("add", n1.plan);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1")); // one night alone: not yet
    try testing.expectEqual(promote.Status.missed, status(&s, "w2"));
    try testing.expectEqual(@as(usize, 0), (try s.inWeights(arena.allocator())).len);
    try testing.expectEqual(@as(usize, 4), s.find("w1").?.probes.len); // at most four of its five questions
    const n2 = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 1), n2.left_prompt);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
    const w = try s.inWeights(arena.allocator());
    try testing.expectEqual(@as(usize, 1), w.len);
    try testing.expectEqualStrings("w1", w[0]);
    try testing.expectEqual(@as(u32, 2), f.teaches); // a missed fact is not taught again
}

test "promotion: wrong once without its note and the fact goes back to the prompt, its streak from zero" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "dog=Luna");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try run(&s, &f, &arena);
    _ = try run(&s, &f, &arena);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
    f.weak = "dog";
    const n3 = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 1), n3.back_to_prompt);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1"));
    try testing.expectEqual(@as(u32, 0), s.find("w1").?.alone);
    f.weak = "";
    _ = try run(&s, &f, &arena);
    try testing.expectEqual(promote.Status.promoted, status(&s, "w1")); // one night right again: not yet
    _ = try run(&s, &f, &arena);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
}

test "promotion: a night that changes a control is rejected; its neurons are zeroed and the old answers come back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "dog=Luna");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try run(&s, &f, &arena);
    f.breaks = "boat=blue";
    _ = try f.add("w2", "boat=blue");
    const n = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 1), n.rejected);
    try testing.expectEqualStrings("none", n.plan);
    try testing.expectEqual(promote.Status.rejected, status(&s, "w2"));
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1")); // the fact taught before stays
    try testing.expectEqual(@as(usize, 1), f.liveCount());
    try testing.expectEqual(@as(usize, 2), s.pocket.len); // w1's neurons only
    try testing.expectEqualStrings("Paris", (try f.askAll(arena.allocator(), &.{.{ .q = "What is the capital of France?" }}))[0]);
    // control: the same night without the breaking fact is kept
    var g: Fake = .{ .a = arena.allocator() };
    _ = try g.add("w1", "dog=Luna");
    var s2 = promote.State.init(testing.allocator, .{});
    defer s2.deinit();
    _ = try run(&s2, &g, &arena);
    _ = try g.add("w2", "boat=blue");
    const n2 = try run(&s2, &g, &arena);
    try testing.expectEqual(@as(u32, 0), n2.rejected);
    try testing.expectEqual(promote.Status.promoted, status(&s2, "w2"));
}

test "promotion: a change of a promoted fact is served by its note at once and the pocket is rebuilt that night" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "boat=blue");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try run(&s, &f, &arena);
    _ = try run(&s, &f, &arena);
    try testing.expectEqual(promote.Status.in_weights, status(&s, "w1"));
    try f.change("w1", "w3", "dog=Bruno");
    // before the night: the new note answers, the stale neurons do not (the old note is no longer current)
    const w = try promote.idsOf(arena.allocator(), try f.notes(arena.allocator()), try s.inWeights(arena.allocator()));
    try testing.expectEqualStrings("Bruno", (try f.askAll(arena.allocator(), &.{.{ .q = "Q:dog", .exclude = w }}))[0]);
    const taught_before = f.teaches;
    const n = try run(&s, &f, &arena);
    try testing.expectEqual(@as(u32, 1), n.stale);
    try testing.expectEqualStrings("rebuild", n.plan);
    try testing.expectEqual(promote.Status.freed, status(&s, "w1"));
    try testing.expectEqual(promote.Status.promoted, status(&s, "w2")); // taught again: alone from zero
    try testing.expectEqual(promote.Status.promoted, status(&s, "w3"));
    try testing.expectEqual(taught_before + 2, f.teaches); // w2 again and w3, not w1
    try testing.expectEqual(@as(usize, 4), f.retired.items.len); // every promotion neuron zeroed first
    try testing.expectEqual(@as(usize, 2), f.liveCount());
    try testing.expectEqualStrings("Bruno", (try f.askAll(arena.allocator(), &.{.{ .q = "Q:dog", .exclude = null }}))[0]);
}

test "promotion: when every rebuild makes answers worse the untaught model serves and every fact is a note again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "boat=blue");
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    _ = try run(&s, &f, &arena);
    try f.change("w1", "w3", "dog=Bruno");
    f.breaks = "boat=blue"; // teaching the boat again now breaks a control
    const n = try run(&s, &f, &arena);
    try testing.expectEqualStrings("source", n.plan);
    try testing.expectEqual(@as(u32, 3), n.tries); // rebuild, rebuild-old, source
    try testing.expectEqual(@as(usize, 0), f.liveCount());
    try testing.expectEqual(promote.Status.note, status(&s, "w2"));
    try testing.expectEqual(promote.Status.rejected, status(&s, "w3"));
    try testing.expectEqual(promote.Status.freed, status(&s, "w1"));
    try testing.expectEqual(@as(usize, 0), s.pocket.len);
}

test "promotion: the state survives a restart, and a night stopped half way is rebuilt with its neurons zeroed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .a = arena.allocator() };
    _ = try f.add("w1", "dog=Luna");
    _ = try f.add("w2", "boat=blue");
    var s = promote.State.init(testing.allocator, .{ .hold = 1, .alone = 2 });
    defer s.deinit();
    _ = try run(&s, &f, &arena);
    _ = try run(&s, &f, &arena);
    const bytes = try pjson.encode(&s, arena.allocator());
    var back = try pjson.decode(testing.allocator, bytes, .{ .hold = 1, .alone = 2 });
    defer back.deinit();
    try testing.expectEqualStrings(bytes, try pjson.encode(&back, arena.allocator()));
    try testing.expectEqual(promote.Status.in_weights, status(&back, "w1"));
    try testing.expectEqual(@as(u32, 2), back.nights_done);
    try testing.expect(!back.rebuild_next);
    // a crash while teaching the second fact of a night: the file says the night is open, with what it placed
    _ = try f.add("w3", "cat=Milo");
    _ = try f.add("w4", "tent=yellow");
    f.crash_at_teach = f.teaches + 2;
    try testing.expectError(error.Crash, run(&s, &f, &arena));
    var again = try pjson.decode(testing.allocator, f.saved.?, .{ .hold = 1, .alone = 2 });
    defer again.deinit();
    try testing.expect(again.rebuild_next);
    try testing.expectEqual(@as(usize, 6), again.pocket.len); // w1, w2 and the w3 placed before the stop
    f.crash_at_teach = null;
    const before = f.retired.items.len;
    const n = try promote.night(&again, arena.allocator(), &f);
    try testing.expectEqualStrings("rebuild", n.plan);
    try testing.expectEqual(before + 6, f.retired.items.len);
    try testing.expectEqual(promote.Status.promoted, status(&again, "w3"));
    try testing.expectEqual(promote.Status.promoted, status(&again, "w1")); // taught again: alone from zero
    try testing.expectEqual(@as(usize, 4 * 2), again.pocket.len);
    try testing.expect(again.open == null and !again.rebuild_next);
}

test "promotion: the state file is written whole through a fresh name, and a bad one is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/snap.json.promote", .{tmp.sub_path});
    var s = promote.State.init(testing.allocator, .{});
    defer s.deinit();
    try pjson.writeFile(a, path, try pjson.encode(&s, a));
    try pjson.writeFile(a, path, "{\"format\": \"tf-notes-promote/1\", \"nights_done\": 3, \"pocket\": [], \"open\": null, \"facts\": [], \"nights\": []}");
    const read = try tmp.dir.readFileAlloc(testing.io, "snap.json.promote", a, .limited(1 << 20));
    var back = try pjson.decode(testing.allocator, read, .{});
    defer back.deinit();
    try testing.expectEqual(@as(u32, 3), back.nights_done);
    try testing.expectError(error.BadState, pjson.decode(testing.allocator, "{\"format\": \"other\"}", .{}));
    try testing.expectError(error.BadState, pjson.decode(testing.allocator, "not json", .{}));
}

test "promotion: --notes-promote-every takes a duration, off by default; hold and alone take a count from 1" {
    const cli = @import("cli.zig");
    const np = @import("notes_promote.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u: cli.Usage = .{};
    const plain = try cli.parse(a, &.{"m"}, &u);
    try testing.expect(plain.notes_promote_every_ms == null);
    try testing.expectEqual(@as(u32, 1), plain.notes_promote_hold);
    try testing.expectEqual(@as(u32, 2), plain.notes_promote_alone);
    const on = try cli.parse(a, &.{ "m", "--notes", "s.json", "--slide", "--notes-promote-every", "10m", "--notes-promote-hold", "2", "--notes-promote-alone", "3" }, &u);
    try testing.expectEqual(@as(?i64, 600_000), on.notes_promote_every_ms);
    try testing.expectEqual(@as(u32, 2), on.notes_promote_hold);
    try testing.expectEqual(@as(u32, 3), on.notes_promote_alone);
    try testing.expectEqual(@as(?i64, 600_000), np.parseDuration("600"));
    try testing.expectEqual(@as(?i64, 86_400_000), np.parseDuration("24h"));
    try testing.expectEqual(@as(?i64, 30_000), np.parseDuration("30s"));
    for ([_][]const u8{ "", "0", "10x", "m", "-5m" }) |bad| try testing.expect(np.parseDuration(bad) == null);
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-every", "soon" }, &u));
    try testing.expectError(error.Usage, cli.parse(a, &.{ "m", "--notes-promote-hold", "0" }, &u));
}
