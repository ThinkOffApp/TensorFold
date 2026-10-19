//! A night's regression set: the facts' and notes' own questions, neighbours, untold questions, two-note questions.
const std = @import("std");
const promote = @import("promote.zig");
const Allocator = std.mem.Allocator;
const State = promote.State;
const Fact = promote.Fact;
const Note = promote.Note;
const Ask = promote.Ask;
const Probe = promote.Probe;
const NightLog = promote.NightLog;
const judge = @import("promote_judge.zig");

/// Judged: fact and pair right to wrong; control changed; neighbour and untold "don't know" to a value, or changed.
pub const Kind = enum { fact, control, neighbour, pair };

/// Personal questions nothing tells: a lesson that makes the model answer one has made something up.
pub const untold = [_][]const u8{ "What is my rabbit's name?", "Where does my cousin live?", "What is my neighbour's favourite colour?" };

/// Neighbour questions a fact keeps at most: the same question about others the user knows, and the model.
pub const neighbours_per_fact = 3;

pub const Regress = struct {
    asks: []Ask,
    kind: []Kind,
    text: [][]const u8, // the fact (or both facts) a fact's or pair's reference comes from; "" otherwise
    ref: [][]const u8,
    before: []const []const u8 = &.{},
    right: []bool = &.{},
};

/// Whom a fact's question is also asked about, in place of its subject: a near relation and one nobody told of.
pub const swaps = [_][]const u8{ "sister", "neighbour" };

/// `question` with its first "my X" about `who` ("my cat's eyes": "my sister's eyes"); null if none or X is who.
pub fn swapSubject(a: Allocator, question: []const u8, who: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (std.ascii.findIgnoreCasePos(question, i, "my ")) |at| : (i = at + 3) {
        if (at > 0 and std.ascii.isAlphabetic(question[at - 1])) continue;
        var j = at + 3;
        while (j < question.len and std.ascii.isAlphabetic(question[j])) j += 1;
        if (j == at + 3) continue;
        if (std.ascii.eqlIgnoreCase(question[at + 3 .. j], who)) return null;
        return try std.mem.concat(a, u8, &.{ question[0 .. at + 3], who, question[j..] });
    }
    return null;
}

/// Whether a question says a possessive twice in a row ("the boat's colour's colour's colour?"): a wording gone wrong.
pub fn degenerate(q: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, q, " \t\r\n,;:!?\"()*");
    var last: []const u8 = "";
    while (it.next()) |raw| {
        const w = std.mem.trimEnd(u8, raw, ".");
        const possessive = std.mem.endsWith(u8, w, "'s") or std.mem.endsWith(u8, w, "\u{2019}s");
        if (possessive and std.ascii.eqlIgnoreCase(w, last)) return true;
        last = w;
    }
    return false;
}

/// Whether a reply says it does not know (the judge's list, which a reply stating its value plainly must not match).
pub const unknown = judge.unknown;

/// "yes" or "no" when the reply opens with one (null: neither).
pub const yesNo = judge.yesNo;

fn words(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?\"'()*_=");
    while (it.next()) |w| if (w.len >= 3) try out.append(a, w);
    return out.items;
}

const plain = [_][]const u8{ "the", "and", "are", "was", "has", "have", "with", "now", "for", "that", "this", "than", "not", "longer", "really", "most" };

fn isPlain(w: []const u8) bool {
    for (plain) |p| if (std.ascii.eqlIgnoreCase(w, p)) return true;
    return false;
}

/// The current fact note sharing the most words with `f` (one at least, common words aside), or null.
pub fn partner(a: Allocator, s: *State, f: *const Fact, notes: []const Note) !?*Fact {
    const mine = try words(a, f.text);
    var best: ?*Fact = null;
    var most: usize = 0;
    for (s.facts.items) |*g| {
        if (g == f or g.status == .freed) continue;
        const cur = promote.noteOfPub(notes, g.key) orelse continue;
        if (!cur.fact) continue;
        var n: usize = 0;
        for (try words(a, g.text)) |w| {
            if (isPlain(w)) continue;
            for (mine) |m| if (std.ascii.eqlIgnoreCase(w, m)) {
                n += 1;
                break;
            };
        }
        if (n > most) {
            most = n;
            best = g;
        }
    }
    return best;
}

/// The targeted probes of each fact in `facts` that has none yet, written once and kept in the state.
pub fn build(s: *State, a: Allocator, b: anytype, facts: []const *Fact, notes: []const Note) !void {
    const sa = s.alloc();
    for (facts) |f| {
        if (f.neighbours.len == 0) if (f.ask) |own| {
            const ns = try b.neighbours(a, own.q); // the backend's order: the most telling first
            const out = try sa.alloc([]const u8, @min(ns.len, neighbours_per_fact));
            for (out, ns[0..out.len]) |*q, x| q.* = try sa.dupe(u8, x);
            f.neighbours = out;
        };
        if (f.pair == null) if (try partner(a, s, f, notes)) |g| {
            const q = try b.pairQuestion(a, f.text, g.text);
            if (q.len > 0) {
                const both = try std.fmt.allocPrint(a, "{s} {s}", .{ f.text, g.text });
                const ref = (try b.references(a, both, &.{q}))[0];
                f.pair = .{ .q = try sa.dupe(u8, q), .ref = try sa.dupe(u8, ref), .text = try sa.dupe(u8, both) };
            }
        };
    }
}

/// The regression set: pocket probes, notes' questions, neighbours, two-note, untold and control questions.
pub fn set(a: Allocator, keep: []const *Fact, noted: []const *Fact, targeted: []const *Fact, excl: []const u32, untold_on: bool) !Regress {
    var asks: std.ArrayList(Ask) = .empty;
    var kind: std.ArrayList(Kind) = .empty;
    var text: std.ArrayList([]const u8) = .empty;
    var ref: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(al: Allocator, xs: *std.ArrayList(Ask), ks: *std.ArrayList(Kind), ts: *std.ArrayList([]const u8), rs: *std.ArrayList([]const u8), q: []const u8, k: Kind, t: []const u8, r: []const u8, ex: []const u32) !void {
            for (xs.items) |x| if (std.mem.eql(u8, x.q, q)) return; // each question once
            try xs.append(al, .{ .q = q, .exclude = ex });
            try ks.append(al, k);
            try ts.append(al, t);
            try rs.append(al, r);
        }
    }.f;
    for (keep) |f| for (f.probes) |p| try add(a, &asks, &kind, &text, &ref, p.q, .fact, f.text, p.ref, excl);
    for (noted) |f| if (f.ask) |p| try add(a, &asks, &kind, &text, &ref, p.q, .fact, f.text, p.ref, excl);
    for (targeted) |f| {
        for (f.neighbours) |q| try add(a, &asks, &kind, &text, &ref, q, .neighbour, "", "", excl);
        if (f.pair) |p| try add(a, &asks, &kind, &text, &ref, p.q, .pair, p.text, p.ref, excl);
    }
    if (untold_on) for (untold) |q| try add(a, &asks, &kind, &text, &ref, q, .neighbour, "", "", excl);
    for (promote.controls) |q| try add(a, &asks, &kind, &text, &ref, q, .control, "", "", excl);
    return .{ .asks = asks.items, .kind = kind.items, .text = text.items, .ref = ref.items };
}

/// Whether a fact's or a pair's reply gives what its reference gives (a yes/no reference: the same yes or no).
fn right(b: anytype, r: Regress, i: usize, reply: []const u8) bool {
    if (r.kind[i] == .pair) if (yesNo(r.ref[i])) |want| return yesNo(reply) == want;
    return b.agrees(r.text[i], r.asks[i].q, r.ref[i], reply);
}

/// Each probe's reply before tonight's lessons: which are right, for the kinds judged right to wrong.
pub fn before(b: anytype, r: *Regress, a: Allocator, replies: []const []const u8) !void {
    r.before = replies;
    r.right = try a.alloc(bool, replies.len);
    for (r.right, 0..) |*x, i| x.* = switch (r.kind[i]) {
        .fact, .pair => right(b, r.*, i, replies[i]),
        .control, .neighbour => true,
    };
}

/// A change settled from the two replies alone (null: the probe's check decides); see PROMOTION-IN-SERVER.md, Judge.
pub fn settled(kind: Kind, q: []const u8, was: []const u8, now: []const u8, notes: []const []const u8) ?bool {
    const fresh = judge.newValue(q, was, now, notes);
    if (kind != .fact and unknown(now) and !fresh) return true;
    if (kind == .neighbour and unknown(was)) return false; // it gave a value, or a new one beside its don't-know
    if (fresh) return null;
    if (yesNo(was)) |w| if (yesNo(now)) |x| if (w == x) return true;
    if (judge.extends(was, now)) return true;
    return null;
}

/// Probes worse now than before; their kinds and wordings joined into `log`.
pub fn worse(a: Allocator, b: anytype, r: Regress, after: []const []const u8, log: *NightLog) !u32 {
    var n: u32 = 0;
    var list: std.ArrayList(u8) = .empty;
    for (r.asks, 0..) |q, i| {
        if (!r.right[i]) continue;
        const was = r.before[i];
        const now = after[i];
        const ok = settled(r.kind[i], q.q, was, now, try b.texts(a)) orelse switch (r.kind[i]) {
            .fact, .pair => right(b, r, i, now),
            .control => std.mem.eql(u8, was, now) or try b.same(a, q.q, was, now),
            // "I don't know for sure, but your rabbit is named Floppy." gives a new value: worse
            .neighbour => if (unknown(was)) unknown(now) and !judge.newValue(q.q, was, now, try b.texts(a)) else std.mem.eql(u8, was, now) or try b.same(a, q.q, was, now),
        };
        b.recordProbe(.{ .night = log.night, .kind = @tagName(r.kind[i]), .q = q.q, .before = was, .after = now, .ok = ok });
        if (ok) continue;
        n += 1;
        if (list.items.len > 0) try list.appendSlice(a, " | ");
        try list.print(a, "{s}: {s} -> {s} (was {s})", .{ @tagName(r.kind[i]), q.q, now[0..@min(now.len, 80)], was[0..@min(was.len, 80)] });
    }
    // the list of a rejected plan stays in the log beside any later one
    if (n > 0) log.worse_list = if (log.worse_list.len > 0) try std.mem.concat(a, u8, &.{ log.worse_list, " || ", list.items }) else list.items;
    return n;
}

/// The current fact notes whose own question joins tonight's regression set: all, or `n` chosen by key hash.
pub fn sampleNotes(a: Allocator, s: *State, notes: []const Note, n: ?u32) ![]*Fact {
    var out: std.ArrayList(*Fact) = .empty;
    for (s.facts.items) |*f| if (promote.noteOfPub(notes, f.key)) |cur| if (cur.fact and f.status != .freed) try out.append(a, f);
    const Order = struct {
        fn lt(_: void, x: *Fact, y: *Fact) bool {
            return std.hash.Wyhash.hash(0, x.key) < std.hash.Wyhash.hash(0, y.key);
        }
    };
    std.mem.sort(*Fact, out.items, {}, Order.lt);
    const m = if (n) |x| @min(x, out.items.len) else out.items.len;
    return out.items[0..m];
}

/// A question for each note that has none yet, written by the model, with its reference answer (kept in the state).
pub fn askOf(s: *State, a: Allocator, b: anytype, facts: []const *Fact) !void {
    for (facts) |f| {
        if (f.ask != null) continue;
        const q = try b.questionOf(a, f.text);
        if (q.len == 0) continue;
        const ref = (try b.references(a, f.text, &.{q}))[0];
        f.ask = .{ .q = try s.alloc().dupe(u8, q), .ref = try s.alloc().dupe(u8, ref) };
    }
}

test "a fact's question about someone else in its subject's place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("What colour are my sister's eyes?", (try swapSubject(a, "What colour are my cat's eyes?", "sister")).?);
    try std.testing.expectEqualStrings("Where does my neighbour live?", (try swapSubject(a, "Where does my sister live?", "neighbour")).?);
    try std.testing.expect(try swapSubject(a, "Where does my sister live?", "sister") == null);
    try std.testing.expect(try swapSubject(a, "What do I like?", "sister") == null);
}

test "don't know and yes or no, read off a reply" {
    try std.testing.expect(unknown("I don't know your rabbit's name. You haven't told me."));
    try std.testing.expect(!unknown("Your rabbit's name is Floppy."));
    try std.testing.expectEqual(@as(?bool, true), yesNo("Yes."));
    try std.testing.expectEqual(@as(?bool, false), yesNo("No, your cat's eyes are green and your eyes are not green."));
    try std.testing.expectEqual(@as(?bool, null), yesNo("Nobody knows."));
    try std.testing.expectEqual(@as(?bool, null), yesNo("Yesterday it rained."));
    try std.testing.expectEqual(@as(?bool, true), yesNo("Yes, it is."));
}
