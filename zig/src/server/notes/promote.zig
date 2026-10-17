//! Nightly promotion: used, unchanged notes taught into the pocket; a note leaves the prompt once its neurons answer.
const std = @import("std");
const api = @import("engine_api");
const Allocator = std.mem.Allocator;

pub const Neuron = api.Neuron;
pub const NeuronKey = api.NeuronKey;

/// Where a fact stands: a note only, taught (promoted), answered alone (in_weights), or given up on.
pub const Status = enum { note, promoted, in_weights, missed, rejected, freed };

/// A question the learner asked of a fact, and the untaught model's answer with the fact before it.
pub const Probe = struct { q: []const u8, ref: []const u8 };

pub const Fact = struct {
    key: []const u8, // the note's write source ("w12"), or "s<id>" for a snapshot's note
    text: []const u8,
    told: i64 = 0,
    status: Status = .note,
    since: u32 = 0, // nights done when the note was first seen
    retrieved: bool = false, // in a chat request's block at least once
    alone: u32 = 0, // nights running its probes came back without its note
    night: u32 = 0, // the night it was taught
    neurons: []const Neuron = &.{},
    probes: []const Probe = &.{},
    why: []const u8 = "", // the last thing that happened to it
};

/// One night as the report shows it.
pub const NightLog = struct {
    night: u32 = 0,
    started_ms: i64 = 0,
    secs: f64 = 0,
    due: u32 = 0,
    stale: u32 = 0,
    plan: []const u8 = "none", // the plan kept: none, add, rebuild, rebuild-old, source
    tries: u32 = 0,
    taught: u32 = 0,
    kept: u32 = 0,
    missed: u32 = 0,
    probes: u32 = 0, // regression questions asked each time
    worse: u32 = 0, // in the last plan tried
    rejected: u32 = 0, // plans rejected tonight
    alone_asked: u32 = 0,
    alone_right: u32 = 0,
    left_prompt: u32 = 0, // facts that became in_weights tonight
    back_to_prompt: u32 = 0,
    in_weights: u32 = 0,
    pocket: u32 = 0,
    asks: u32 = 0,
};

/// A night in progress, on disk before the weights change: the neurons placed so far, the text being taught.
pub const Open = struct { night: u32, teaching: []const u8 = "", placed: []const Neuron = &.{} };

/// A note as the store lists it now.
pub const Note = struct { id: u32, key: []const u8, text: []const u8, told: i64, fact: bool };

/// What teaching one fact did.
pub const Taught = struct { kept: bool, neurons: []const Neuron = &.{}, questions: []const []const u8 = &.{}, why: []const u8 = "" };

/// A question to ask as production does, with these note ids left out of its block (null: no notes at all).
pub const Ask = struct { q: []const u8, exclude: ?[]const u32 = &.{} };

pub const Settings = struct { hold: u32 = 1, alone: u32 = 2, tolerance: u32 = 0, probes_per_fact: usize = 4 };

/// Prompts that no lesson should change, asked before and after each night.
pub const controls = [_][]const u8{ "What is the capital of France?", "How many legs does a spider have?", "Tell me something interesting about the ocean.", "What is my teacher's name?" };

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    settings: Settings = .{},
    nights_done: u32 = 0,
    rebuild_next: bool = false, // a night stopped half way: the next one zeroes and teaches again
    open: ?Open = null,
    pocket: []const Neuron = &.{}, // every neuron promotion placed and has not zeroed
    facts: std.ArrayList(Fact) = .empty,
    nights: std.ArrayList(NightLog) = .empty,

    pub fn init(gpa: Allocator, settings: Settings) State {
        return .{ .arena = .init(gpa), .settings = settings };
    }

    pub fn deinit(s: *State) void {
        s.arena.deinit();
    }

    pub fn alloc(s: *State) Allocator {
        return s.arena.allocator();
    }

    pub fn find(s: *State, key: []const u8) ?*Fact {
        for (s.facts.items) |*f| if (std.mem.eql(u8, f.key, key)) return f;
        return null;
    }

    /// The keys whose notes production leaves out of the prompt.
    pub fn inWeights(s: *const State, a: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (s.facts.items) |f| if (f.status == .in_weights) try out.append(a, f.key);
        return out.items;
    }

    fn count(s: *const State, comptime pred: fn (Status) bool) u32 {
        var n: u32 = 0;
        for (s.facts.items) |f| n += @intFromBool(pred(f.status));
        return n;
    }
};

/// Whether `ns` holds neuron `n`.
pub fn has(ns: []const Neuron, n: Neuron) bool {
    for (ns) |x| if (x.layer == n.layer and x.neuron == n.neuron and x.key == n.key) return true;
    return false;
}

pub fn active(s: Status) bool {
    return s == .promoted or s == .in_weights;
}

fn isWeights(s: Status) bool {
    return s == .in_weights;
}

/// Whether a note's words name a date: a year 1900-2099, or "since" / "until" (a dated value has two values).
pub fn dated(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i]) or (i > 0 and std.ascii.isDigit(text[i - 1]))) continue;
        var j = i;
        while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
        if (j - i == 4 and (std.mem.startsWith(u8, text[i..], "19") or std.mem.startsWith(u8, text[i..], "20"))) return true;
    }
    var it = std.mem.tokenizeAny(u8, text, " ,.;:!?\"'()");
    while (it.next()) |w| for ([_][]const u8{ "since", "until", "till" }) |d| if (std.ascii.eqlIgnoreCase(w, d)) return true;
    return false;
}

/// The note ids among `notes` whose keys are in `keys`.
pub fn idsOf(a: Allocator, notes: []const Note, keys: []const []const u8) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (notes) |n| for (keys) |k| if (std.mem.eql(u8, n.key, k)) {
        try out.append(a, n.id);
        break;
    };
    return out.items;
}

fn noteOf(notes: []const Note, key: []const u8) ?Note {
    for (notes) |n| if (std.mem.eql(u8, n.key, key)) return n;
    return null;
}

fn byTold(_: void, x: *Fact, y: *Fact) bool {
    return x.told < y.told or (x.told == y.told and std.mem.lessThan(u8, x.key, y.key));
}

const Regress = struct { asks: []const Ask, facts: []const ?*const Fact, probe: []const ?Probe, before: []const []const u8, right: []const bool };

/// The regression set: each fact's probes, then the controls; asked as production asks them now.
fn regressSet(a: Allocator, keep: []const *Fact, excl: []const u32) !struct { asks: []Ask, facts: []?*const Fact, probe: []?Probe } {
    var asks: std.ArrayList(Ask) = .empty;
    var facts: std.ArrayList(?*const Fact) = .empty;
    var probe: std.ArrayList(?Probe) = .empty;
    for (keep) |f| for (f.probes) |p| {
        try asks.append(a, .{ .q = p.q, .exclude = excl });
        try facts.append(a, f);
        try probe.append(a, p);
    };
    for (controls) |q| {
        try asks.append(a, .{ .q = q, .exclude = excl });
        try facts.append(a, null);
        try probe.append(a, null);
    }
    return .{ .asks = asks.items, .facts = facts.items, .probe = probe.items };
}

/// Questions right before and wrong now (a control: changed in substance).
fn worseCount(a: Allocator, b: anytype, r: Regress, after: []const []const u8) !u32 {
    var n: u32 = 0;
    for (r.asks, 0..) |q, i| {
        if (!r.right[i]) continue;
        const ok = if (r.facts[i]) |f| b.agrees(f.text, q.q, r.probe[i].?.ref, after[i]) else std.mem.eql(u8, r.before[i], after[i]) or try b.same(a, q.q, r.before[i], after[i]);
        n += @intFromBool(!ok);
    }
    return n;
}

fn setPocket(s: *State, add: []const Neuron) !void {
    s.pocket = try std.mem.concat(s.alloc(), Neuron, &.{ s.pocket, add });
}

/// Every promotion neuron zeroed (the untaught model, for promotion's part); recorded as such before it happens.
fn zeroAll(s: *State, a: Allocator, b: anytype) !void {
    if (s.pocket.len > 0) try b.retire(a, s.pocket);
    s.pocket = &.{};
    for (s.facts.items) |*f| f.neurons = &.{};
}

/// Teaches each of `list` in order; records the open night's neurons as it goes.
fn teachAll(s: *State, a: Allocator, b: anytype, k: u32, list: []const *Fact, log: *NightLog) ![]Taught {
    const out = try a.alloc(Taught, list.len);
    for (list, out) |f, *t| {
        s.open = .{ .night = k, .teaching = f.text, .placed = s.pocket };
        try b.persist(s);
        t.* = try b.teach(a, f.text);
        log.taught += 1;
        if (t.kept) {
            try setPocket(s, t.neurons);
            log.kept += 1;
        } else log.missed += 1;
        s.open = .{ .night = k, .placed = s.pocket };
        try b.persist(s);
    }
    return out;
}

/// The fact's probes from its lesson's questions: at most a few, each with its reference answer.
fn probesOf(s: *State, a: Allocator, b: anytype, f: *Fact, t: Taught) !void {
    const qs = t.questions[0..@min(t.questions.len, s.settings.probes_per_fact)];
    const refs = try b.references(a, f.text, qs);
    const out = try s.alloc().alloc(Probe, qs.len);
    for (qs, refs, out) |q, r, *p| p.* = .{ .q = try s.alloc().dupe(u8, q), .ref = try s.alloc().dupe(u8, r) };
    f.probes = out;
    f.neurons = try s.alloc().dupe(Neuron, t.neurons);
}

const Plan = enum { add, rebuild, @"rebuild-old", source };

/// One night: qualify, teach, check for regressions, and move notes out of the prompt or back.
pub fn night(s: *State, a: Allocator, b: anytype) !NightLog {
    const k = s.nights_done + 1;
    var log: NightLog = .{ .night = k, .started_ms = b.nowMs() };
    const sa = s.alloc();
    const notes = try b.notes(a);
    for (notes) |n| if (n.fact and s.find(n.key) == null) try s.facts.append(sa, .{ .key = try sa.dupe(u8, n.key), .text = try sa.dupe(u8, n.text), .told = n.told, .since = b.firstSeen(n.key) orelse s.nights_done });
    var stale: std.ArrayList(*Fact) = .empty;
    var keep: std.ArrayList(*Fact) = .empty;
    var due: std.ArrayList(*Fact) = .empty;
    for (s.facts.items) |*f| {
        const cur = noteOf(notes, f.key);
        if (cur == null or !cur.?.fact) {
            if (active(f.status)) try stale.append(a, f);
            continue;
        }
        f.retrieved = f.retrieved or b.wasRetrieved(f.key);
        if (active(f.status)) try keep.append(a, f) else if (f.status == .note and f.retrieved and !dated(f.text) and k - f.since >= s.settings.hold) try due.append(a, f);
    }
    std.mem.sort(*Fact, keep.items, {}, byTold);
    std.mem.sort(*Fact, due.items, {}, byTold);
    log.due = @intCast(due.items.len);
    log.stale = @intCast(stale.items.len);
    const rebuild = stale.items.len > 0 or s.rebuild_next;
    if (rebuild or due.items.len > 0) try runPlans(s, a, b, k, notes, stale.items, keep.items, due.items, rebuild, &log);
    try alone(s, a, b, notes, &log);
    log.in_weights = s.count(isWeights);
    log.pocket = s.count(active);
    log.secs = @as(f64, @floatFromInt(b.nowMs() - log.started_ms)) / 1000;
    s.nights_done = k;
    s.open = null;
    s.rebuild_next = false;
    try s.nights.append(sa, log);
    try b.persist(s);
    return log;
}

fn runPlans(s: *State, a: Allocator, b: anytype, k: u32, notes: []const Note, stale: []*Fact, keep: []*Fact, due: []*Fact, rebuild: bool, log: *NightLog) !void {
    const excl = try idsOf(a, notes, try s.inWeights(a));
    const set = try regressSet(a, keep, excl);
    const before = try b.askAll(a, set.asks);
    log.asks += @intCast(set.asks.len);
    const right = try a.alloc(bool, set.asks.len);
    for (set.asks, 0..) |q, i| right[i] = if (set.facts[i]) |f| b.agrees(f.text, q.q, set.probe[i].?.ref, before[i]) else true;
    const r: Regress = .{ .asks = set.asks, .facts = set.facts, .probe = set.probe, .before = before, .right = right };
    log.probes = @intCast(set.asks.len);
    var plans: std.ArrayList(Plan) = .empty;
    if (!rebuild) try plans.append(a, .add) else {
        if (keep.len + due.len > 0) try plans.append(a, .rebuild);
        if (keep.len > 0 and due.len > 0) try plans.append(a, .@"rebuild-old");
        try plans.append(a, .source);
    }
    s.open = .{ .night = k, .placed = s.pocket };
    try b.persist(s);
    for (plans.items) |plan| {
        log.tries += 1;
        log.plan = @tagName(plan);
        const list: []const *Fact = switch (plan) {
            .add => due,
            .rebuild => try std.mem.concat(a, *Fact, &.{ keep, due }),
            .@"rebuild-old" => keep,
            .source => &.{},
        };
        if (plan != .add) try zeroAll(s, a, b);
        const before_add = s.pocket;
        const sorted = try a.dupe(*Fact, list);
        std.mem.sort(*Fact, sorted, {}, byTold);
        const taught = try teachAll(s, a, b, k, sorted, log);
        // a rebuild teaches every fact anew: every note is in its prompt until it answers alone again
        const ask_excl = if (plan == .add) excl else &[_]u32{};
        const asks2 = try a.dupe(Ask, set.asks);
        for (asks2) |*q| q.exclude = ask_excl;
        const after = try b.askAll(a, asks2);
        log.asks += @intCast(asks2.len);
        log.worse = try worseCount(a, b, r, after);
        if (log.worse <= s.settings.tolerance or plan == .source) {
            try accept(s, a, b, k, plan, stale, keep, due, sorted, taught);
            return;
        }
        log.rejected += 1;
        if (plan == .add) {
            const tonight = s.pocket[before_add.len..];
            if (tonight.len > 0) try b.retire(a, tonight);
            s.pocket = before_add;
            const again = try b.askAll(a, set.asks);
            log.asks += @intCast(set.asks.len);
            log.worse = try worseCount(a, b, r, again);
            for (due) |f| reject(s, f, "rejected: the night made answers worse");
            if (log.worse > s.settings.tolerance) {
                log.tries += 1;
                log.plan = "source";
                try zeroAll(s, a, b);
                try accept(s, a, b, k, .source, stale, keep, &.{}, &.{}, &.{});
            } else log.plan = "none";
            return;
        }
    }
}

fn reject(s: *State, f: *Fact, why: []const u8) void {
    _ = s;
    f.status = .rejected;
    f.why = why;
}

fn accept(s: *State, a: Allocator, b: anytype, k: u32, plan: Plan, stale: []*Fact, keep: []*Fact, due: []*Fact, sorted: []const *Fact, taught: []const Taught) !void {
    const keptOf = struct {
        fn of(list: []const *Fact, ts: []const Taught, f: *Fact) ?Taught {
            for (list, ts) |x, t| if (x == f) return t;
            return null;
        }
    }.of;
    for (stale) |f| {
        f.status = .freed;
        f.alone = 0;
        f.neurons = &.{};
        f.why = "freed: its note changed or was taken back; the pocket was rebuilt without it";
    }
    if (plan != .add) for (keep) |f| {
        const t = keptOf(sorted, taught, f);
        if (t != null and t.?.kept) {
            f.status = .promoted;
            f.alone = 0;
            f.why = "taught again in the rebuilt pocket";
            try probesOf(s, a, b, f, t.?);
        } else {
            f.status = .note;
            f.alone = 0;
            f.neurons = &.{};
            f.probes = &.{};
            f.why = if (plan == .source) "back to notes: the rebuild left it out" else "back to notes: not kept when the pocket was rebuilt";
        }
    };
    for (due) |f| {
        if (plan == .@"rebuild-old" or plan == .source) {
            reject(s, f, "rejected: the night with it made answers worse");
            continue;
        }
        const t = keptOf(sorted, taught, f) orelse continue;
        if (t.kept) {
            f.status = .promoted;
            f.night = k;
            f.alone = 0;
            f.why = "promoted";
            try probesOf(s, a, b, f, t);
        } else {
            f.status = .missed;
            f.why = if (t.why.len > 0) try s.alloc().dupe(u8, t.why) else "missed: the learner did not keep it; it stays a note";
        }
    }
}

/// Each fact in the pocket asked its probes without its own note; `alone` nights running moves the note out.
fn alone(s: *State, a: Allocator, b: anytype, notes: []const Note, log: *NightLog) !void {
    var asks: std.ArrayList(Ask) = .empty;
    var owner: std.ArrayList(*Fact) = .empty;
    var probe: std.ArrayList(Probe) = .empty;
    const weights = try s.inWeights(a);
    for (s.facts.items) |*f| {
        if (!active(f.status) or f.probes.len == 0) continue;
        const own = noteOf(notes, f.key) orelse continue;
        const excl = try std.mem.concat(a, u32, &.{ try idsOf(a, notes, weights), &.{own.id} });
        for (f.probes) |p| {
            try asks.append(a, .{ .q = p.q, .exclude = excl });
            try owner.append(a, f);
            try probe.append(a, p);
        }
    }
    if (asks.items.len == 0) return;
    const replies = try b.askAll(a, asks.items);
    log.asks += @intCast(asks.items.len);
    log.alone_asked = @intCast(asks.items.len);
    var wrong: std.ArrayList(*Fact) = .empty;
    for (asks.items, owner.items, probe.items, replies) |q, f, p, reply| {
        if (b.agrees(f.text, q.q, p.ref, reply)) log.alone_right += 1 else if (std.mem.indexOfScalar(*Fact, wrong.items, f) == null) try wrong.append(a, f);
    }
    var seen: ?*Fact = null;
    for (owner.items) |f| {
        if (seen == f) continue;
        seen = f;
        const was = f.status;
        const ok = std.mem.indexOfScalar(*Fact, wrong.items, f) == null;
        f.alone = if (ok) f.alone + 1 else 0;
        f.status = if (f.alone >= s.settings.alone) .in_weights else .promoted;
        if (f.status == was) continue;
        if (f.status == .in_weights) {
            log.left_prompt += 1;
            f.why = "in weights: its note leaves the prompt";
        } else {
            log.back_to_prompt += 1;
            f.why = "back in the prompt: answered wrong without its note";
        }
    }
}
