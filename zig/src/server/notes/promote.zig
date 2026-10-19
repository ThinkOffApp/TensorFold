//! Nightly promotion: used, unchanged notes taught into the pocket; a note leaves the prompt once its neurons answer.
const std = @import("std");
const api = @import("engine_api");
const Allocator = std.mem.Allocator;
const probes = @import("promote_probes.zig");

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
    retries: u32 = 0, // nights it was due again after a miss or a rejection
    ask: ?Probe = null, // the note's own question and its reference answer, for every night's regression set
    neighbours: []const []const u8 = &.{}, // its own question asked about others the user knows (written once)
    pair: ?Pair = null, // a question that needs this note and another (written once)
};

/// A two-note question, its reference answer and the two facts it was written from.
pub const Pair = struct { q: []const u8, ref: []const u8, text: []const u8 };

/// A probe asked on a night, one line of SNAPSHOT.promote-probes.jsonl: a regression probe's two replies, an alone ask.
pub const Record = struct {
    night: u32,
    kind: []const u8, // fact, control, neighbour, pair; alone
    q: []const u8,
    before: ?[]const u8 = null, // a regression probe's reply before tonight's lessons
    after: ?[]const u8 = null, // and after
    reply: ?[]const u8 = null, // an alone ask's reply
    ok: bool = false,
    key: []const u8 = "", // the fact an alone ask is of, or the one fact a one-by-one check taught
    exclude: ?[]const u32 = null, // the note ids left out of an alone ask's block
    round: u32 = 0, // the alone check's round (1: every candidate's note out; later: the failures' notes back in)
    ref: []const u8 = "", // the reference the reply was judged against
    why: []const u8 = "", // why a probe was dropped or its reference written again
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
    one_by_one: u32 = 0, // facts of a rejected add plan taught again one at a time, each checked on its own
    blamed: u32 = 0, // of those, the ones that made answers worse on their own: rewound and rejected alone
    alone_asked: u32 = 0,
    alone_right: u32 = 0,
    alone_rounds: u32 = 0, // rounds until no candidate dropped (each asks the candidates still standing)
    dropped: u32 = 0, // probes left out tonight: a reference not giving its fact twice, or a degenerate wording
    left_prompt: u32 = 0, // facts that became in_weights tonight
    back_to_prompt: u32 = 0,
    in_weights: u32 = 0,
    pocket: u32 = 0,
    asks: u32 = 0,
    worse_list: []const u8 = "", // the regression questions that went wrong in the last plan tried
};

/// A night in progress, on disk before the weights change: the neurons placed so far, the text being taught.
pub const Open = struct { night: u32, teaching: []const u8 = "", placed: []const Neuron = &.{} };

/// A note as the store lists it now.
pub const Note = struct { id: u32, key: []const u8, text: []const u8, told: i64, fact: bool };

/// What teaching one fact did.
pub const Taught = struct { kept: bool, neurons: []const Neuron = &.{}, questions: []const []const u8 = &.{}, why: []const u8 = "" };

/// A question to ask as production does, with these note ids left out of its block (null: no notes at all).
pub const Ask = struct { q: []const u8, exclude: ?[]const u32 = &.{} };

/// regress_notes: current notes whose own question joins the regression set (null: all); retries: tries after a miss.
pub const Settings = struct { hold: u32 = 1, alone: u32 = 2, tolerance: u32 = 0, probes_per_fact: usize = 4, regress_notes: ?u32 = null, retries: u32 = 1, targeted: bool = true };

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

    pub fn count(s: *const State, comptime pred: fn (Status) bool) u32 {
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

pub fn noteOfPub(notes: []const Note, key: []const u8) ?Note {
    return noteOf(notes, key);
}

fn noteOf(notes: []const Note, key: []const u8) ?Note {
    for (notes) |n| if (std.mem.eql(u8, n.key, key)) return n;
    return null;
}

fn byTold(_: void, x: *Fact, y: *Fact) bool {
    return x.told < y.told or (x.told == y.told and std.mem.lessThan(u8, x.key, y.key));
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

/// The fact's probes from its lesson's questions: at most a few, each with a reference answer that gives the fact.
fn probesOf(s: *State, a: Allocator, b: anytype, f: *Fact, t: Taught, log: *NightLog) !void {
    var qs: std.ArrayList([]const u8) = .empty;
    for (t.questions) |q| {
        if (qs.items.len == s.settings.probes_per_fact) break;
        if (!probes.degenerate(q)) try qs.append(a, q) else drop(b, log, f, q, "", why_degenerate);
    }
    const refs = try b.references(a, f.text, qs.items);
    var out: std.ArrayList(Probe) = .empty;
    for (qs.items, refs) |q, first| {
        var ref = first;
        // run6's "My name is Nemotron." for "Who is my dog?" switched the judge to its lenient path: written once more
        if (!b.gives(f.text, q, ref)) {
            const again = try b.referenceAgain(a, f.text, q);
            const kept = b.gives(f.text, q, again);
            b.recordProbe(.{ .night = log.night, .kind = "reference", .key = f.key, .q = q, .before = first, .after = again, .ok = kept, .why = if (kept) "the first reference did not give the fact; the second does" else why_ref });
            if (!kept) {
                log.dropped += 1;
                continue;
            }
            ref = again;
        }
        try out.append(s.alloc(), .{ .q = try s.alloc().dupe(u8, q), .ref = try s.alloc().dupe(u8, ref) });
    }
    f.probes = out.items;
    f.neurons = try s.alloc().dupe(Neuron, t.neurons);
}

const why_degenerate = "a degenerate wording (a possessive said twice in a row): never asked";
const why_ref = "its reference does not give the fact, written twice: the probe is dropped";
const why_stored = "on load: its stored reference does not give the fact";

/// A probe left out, recorded with why.
fn drop(b: anytype, log: *NightLog, f: *const Fact, q: []const u8, ref: []const u8, why: []const u8) void {
    log.dropped += 1;
    b.recordProbe(.{ .night = log.night, .kind = "dropped", .key = f.key, .q = q, .ref = ref, .why = why });
}

/// Stored probes a night would not build now (a reference not giving its fact, a degenerate wording), dropped.
pub fn repair(s: *State, a: Allocator, b: anytype) !u32 {
    var log: NightLog = .{ .night = s.nights_done };
    for (s.facts.items) |*f| {
        const whys = try a.alloc(?[]const u8, f.probes.len);
        var kept: usize = 0;
        for (f.probes, whys) |p, *why| {
            why.* = if (probes.degenerate(p.q)) why_degenerate else if (!b.gives(f.text, p.q, p.ref)) why_stored else null;
            kept += @intFromBool(why.* == null);
        }
        if (kept == f.probes.len) continue;
        const keep = try s.alloc().alloc(Probe, kept);
        var i: usize = 0;
        for (f.probes, whys) |p, why| if (why) |w| drop(b, &log, f, p.q, p.ref, w) else {
            keep[i] = p;
            i += 1;
        };
        f.probes = keep;
    }
    return log.dropped;
}

const Plan = enum { add, rebuild, @"rebuild-old", source };

/// The pocket and each fact's neurons as the night found them: a refused plan puts the state back to these.
const Marked = struct { pocket: []const Neuron, neurons: []const []const Neuron };

fn markedNow(s: *const State, a: Allocator) !Marked {
    const neurons = try a.alloc([]const Neuron, s.facts.items.len);
    for (s.facts.items, neurons) |f, *n| n.* = f.neurons;
    return .{ .pocket = s.pocket, .neurons = neurons };
}

/// A refused plan undone: the learner rewinds to its mark (refits and 4-bit roundings too), then the state follows.
fn rewind(s: *State, a: Allocator, b: anytype, k: u32, m: Marked) !void {
    try b.rewind(a);
    s.pocket = m.pocket;
    for (s.facts.items[0..m.neurons.len], m.neurons) |*f, ns| f.neurons = ns;
    s.open = .{ .night = k, .placed = s.pocket };
    try b.persist(s);
}

/// night(); a failure marks a rebuild, allocating nothing (the pocket and the open lesson record every neuron placed).
pub fn nightOrRebuild(s: *State, a: Allocator, b: anytype) !NightLog {
    return night(s, a, b) catch |e| {
        s.rebuild_next = true;
        return e;
    };
}

/// One night: qualify, teach, check for regressions, and move notes out of the prompt or back.
pub fn night(s: *State, a: Allocator, b: anytype) !NightLog {
    const k = s.nights_done + 1;
    var log: NightLog = .{ .night = k, .started_ms = b.nowMs() };
    const sa = s.alloc();
    // a night stopped while a lesson ran: what that lesson placed joins the pocket, so the rebuild zeroes it too
    if (s.open) |op| if (op.teaching.len > 0) {
        var all: std.ArrayList(Neuron) = .empty;
        try all.appendSlice(sa, s.pocket);
        for (try b.placedFor(a, op.teaching)) |n| if (!has(all.items, n)) try all.append(sa, n);
        s.pocket = all.items;
        s.rebuild_next = true;
        s.open.?.teaching = "";
    };
    const notes = try b.notes(a);
    for (notes) |n| if (n.fact and s.find(n.key) == null) try s.facts.append(sa, .{ .key = try sa.dupe(u8, n.key), .text = try sa.dupe(u8, n.text), .told = n.told, .since = b.firstSeen(n.key) orelse s.nights_done });
    var stale: std.ArrayList(*Fact) = .empty;
    var keep: std.ArrayList(*Fact) = .empty;
    var due: std.ArrayList(*Fact) = .empty;
    // a missed or rejected fact is due once more (the learner and the night both vary), never a third time
    for (s.facts.items) |*f| if ((f.status == .missed or f.status == .rejected) and f.retries < s.settings.retries and noteOf(notes, f.key) != null) {
        f.status = .note;
        f.retries += 1;
        f.why = "due again: one more try after a miss or a rejection";
    };
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
    log.worse_list = try sa.dupe(u8, log.worse_list);
    try s.nights.append(sa, log);
    try b.persist(s);
    return log;
}

fn runPlans(s: *State, a: Allocator, b: anytype, k: u32, notes: []const Note, stale: []*Fact, keep: []*Fact, due: []*Fact, rebuild: bool, log: *NightLog) !void {
    const excl = try idsOf(a, notes, try s.inWeights(a));
    const noted = try probes.sampleNotes(a, s, notes, s.settings.regress_notes);
    try probes.askOf(s, a, b, noted);
    // the targeted probes (neighbours, two-note, untold): of the facts taught tonight and in the pocket, unless off
    const targeted: []const *Fact = if (s.settings.targeted) try std.mem.concat(a, *Fact, &.{ keep, due }) else &.{};
    try probes.askOf(s, a, b, targeted);
    try probes.build(s, a, b, targeted, notes);
    var set = try probes.set(a, keep, noted, targeted, excl, s.settings.targeted);
    try probes.before(b, &set, a, try b.askAll(a, set.asks));
    log.asks += @intCast(set.asks.len);
    const r = set;
    log.probes = @intCast(set.asks.len);
    var plans: std.ArrayList(Plan) = .empty;
    if (!rebuild) try plans.append(a, .add) else {
        if (keep.len + due.len > 0) try plans.append(a, .rebuild);
        if (keep.len > 0 and due.len > 0) try plans.append(a, .@"rebuild-old");
        try plans.append(a, .source);
    }
    s.open = .{ .night = k, .placed = s.pocket };
    try b.persist(s);
    const marked = try markedNow(s, a);
    for (plans.items) |plan| {
        // every plan starts from the pocket as the night found it, which the learner keeps until a rewind
        try b.mark(a);
        log.tries += 1;
        log.plan = @tagName(plan);
        const list: []const *Fact = switch (plan) {
            .add => due,
            .rebuild => try std.mem.concat(a, *Fact, &.{ keep, due }),
            .@"rebuild-old" => keep,
            .source => &.{},
        };
        if (plan != .add) try zeroAll(s, a, b);
        const sorted = try a.dupe(*Fact, list);
        std.mem.sort(*Fact, sorted, {}, byTold);
        const taught = try teachAll(s, a, b, k, sorted, log);
        // a rebuild teaches every fact anew: every note is in its prompt until it answers alone again
        const ask_excl = if (plan == .add) excl else &[_]u32{};
        const asks2 = try a.dupe(Ask, set.asks);
        for (asks2) |*q| q.exclude = ask_excl;
        const after = try b.askAll(a, asks2);
        log.asks += @intCast(asks2.len);
        log.worse = try probes.worse(a, b, r, after, log, "");
        if (log.worse <= s.settings.tolerance or plan == .source) {
            try accept(s, a, b, k, plan, stale, keep, due, sorted, taught, log);
            return;
        }
        log.rejected += 1;
        try rewind(s, a, b, k, marked);
        if (plan == .add) {
            const again = try b.askAll(a, set.asks);
            log.asks += @intCast(set.asks.len);
            log.worse = try probes.worse(a, b, r, again, log, "");
            if (log.worse > s.settings.tolerance) {
                for (due) |f| reject(s, f, "rejected: the night made answers worse");
                log.tries += 1;
                log.plan = "source";
                try zeroAll(s, a, b);
                try accept(s, a, b, k, .source, stale, keep, &.{}, &.{}, &.{}, log);
            } else if (due.len > 1) {
                try oneByOne(s, a, b, k, keep, due, r, set.asks, excl, log);
            } else {
                for (due) |f| reject(s, f, "rejected: the night made answers worse");
                log.plan = "none";
            }
            return;
        }
    }
}

/// A refused add plan taught again fact by fact, each checked against the night's first replies; a spiller goes alone.
fn oneByOne(s: *State, a: Allocator, b: anytype, k: u32, keep: []*Fact, due: []*Fact, r: probes.Regress, asks: []const Ask, excl: []const u32, log: *NightLog) !void {
    const sorted = try a.dupe(*Fact, due);
    std.mem.sort(*Fact, sorted, {}, byTold);
    var good: std.ArrayList(*Fact) = .empty;
    var taught: std.ArrayList(Taught) = .empty;
    const asked = try a.dupe(Ask, asks);
    for (asked) |*q| q.exclude = excl;
    var last = log.worse; // the state kept is the one after the last fact kept, or the night's own after its rewind
    for (sorted) |f| {
        try b.mark(a);
        const m = try markedNow(s, a);
        log.one_by_one += 1;
        const t = (try teachAll(s, a, b, k, &.{f}, log))[0];
        // a lesson the learner did not keep is asked too: the state after it is the one the next fact starts from
        const n = try probes.worse(a, b, r, try b.askAll(a, asked), log, f.key);
        log.asks += @intCast(asked.len);
        if (n <= s.settings.tolerance) {
            try good.append(a, f);
            try taught.append(a, t);
            last = n;
            continue;
        }
        try rewind(s, a, b, k, m);
        log.blamed += 1;
        reject(s, f, try std.fmt.allocPrint(s.alloc(), "rejected: taught on its own it made {d} answers worse", .{n}));
    }
    log.worse = last;
    log.plan = if (good.items.len > 0) "add" else "none";
    if (good.items.len > 0) try accept(s, a, b, k, .add, &.{}, keep, good.items, good.items, taught.items, log);
}

fn reject(s: *State, f: *Fact, why: []const u8) void {
    _ = s;
    f.status = .rejected;
    f.why = why;
}

fn accept(s: *State, a: Allocator, b: anytype, k: u32, plan: Plan, stale: []*Fact, keep: []*Fact, due: []*Fact, sorted: []const *Fact, taught: []const Taught, log: *NightLog) !void {
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
            try probesOf(s, a, b, f, t.?, log);
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
            try probesOf(s, a, b, f, t, log);
        } else {
            f.status = .missed;
            f.why = if (t.why.len > 0) try s.alloc().dupe(u8, t.why) else "missed: the learner did not keep it; it stays a note";
        }
    }
}

/// Each pocket fact asked its probes in the state after it leaves the prompt; `alone` nights running move it out.
fn alone(s: *State, a: Allocator, b: anytype, notes: []const Note, log: *NightLog) !void {
    // other notes in the block answered for a fact: run6's green pair passed only while each other's note was in it,
    const Cand = struct { f: *Fact, id: u32, ok: bool, right: []bool };
    // bridged by "My cat's eyes are the same colour as mine."; they left together, failed, came back: a 3-night loop.
    var cands: std.ArrayList(Cand) = .empty;
    for (s.facts.items) |*f| {
        if (!active(f.status)) continue;
        const own = noteOf(notes, f.key) orelse continue;
        // a fact with no probe left cannot be asked alone: its note stays in the prompt
        try cands.append(a, .{ .f = f, .id = own.id, .ok = f.probes.len > 0, .right = try a.alloc(bool, f.probes.len) });
    }
    var round: u32 = 0;
    // a fixpoint: every round but the last drops a candidate at least, so at most one round per candidate
    while (round <= cands.items.len) {
        // left out: the note of every candidate still standing, the fact's own and the in-weights ones among them,
        var excl: std.ArrayList(u32) = .empty;
        // so no note that leaves the prompt with a fact can answer for it; non-candidates' notes stay, as in production
        for (cands.items) |c| if (c.ok) try excl.append(a, c.id);
        var asks: std.ArrayList(Ask) = .empty;
        var at: std.ArrayList([2]usize) = .empty; // each ask's candidate and probe
        for (cands.items, 0..) |c, ci| if (c.ok) for (c.f.probes, 0..) |p, pi| {
            try asks.append(a, .{ .q = p.q, .exclude = excl.items });
            try at.append(a, .{ ci, pi });
        };
        if (asks.items.len == 0) break;
        round += 1;
        const replies = try b.askAll(a, asks.items);
        log.asks += @intCast(asks.items.len);
        if (round == 1) log.alone_asked = @intCast(asks.items.len);
        for (asks.items, at.items, replies) |q, x, reply| {
            const c = cands.items[x[0]];
            const p = c.f.probes[x[1]];
            const ok = b.agrees(c.f.text, q.q, p.ref, reply);
            b.recordProbe(.{ .night = log.night, .kind = "alone", .key = c.f.key, .q = q.q, .exclude = q.exclude, .round = round, .reply = reply, .ref = p.ref, .ok = ok });
            c.right[x[1]] = ok;
        }
        // the round's failures stay in the prompt, so the rest are asked again with their notes back in the block,
        var dropped = false;
        // where a note can override the neurons too (in run6 the sister's "orange" answered for my favourite colour)
        for (cands.items) |*c| if (c.ok and std.mem.indexOfScalar(bool, c.right, false) != null) {
            c.ok = false;
            dropped = true;
        };
        if (!dropped) break;
    }
    log.alone_rounds = round;
    for (cands.items) |c| {
        for (c.right) |r| log.alone_right += @intFromBool(r); // each probe's verdict in the last round it was asked
        const f = c.f;
        const was = f.status;
        f.alone = if (c.ok) f.alone + 1 else 0;
        f.status = if (f.alone >= s.settings.alone) .in_weights else .promoted;
        if (f.probes.len == 0) f.why = "no probe left to ask it alone: its note stays in the prompt";
        if (f.status == was) continue;
        if (f.status == .in_weights) {
            log.left_prompt += 1;
            f.why = "in weights: its note leaves the prompt";
        } else {
            log.back_to_prompt += 1;
            f.why = if (f.probes.len == 0) "back in the prompt: no probe left to ask it alone" else "back in the prompt: answered wrong without its note";
        }
    }
}
