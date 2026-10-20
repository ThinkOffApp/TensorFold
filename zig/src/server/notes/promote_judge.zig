//! Promotion's judge without an answer key: does a reply give the fact as its reference answer does.
const std = @import("std");
const wording = @import("../slide_words.zig");
const units = @import("../slide_units.zig");

/// What the judge knows besides the reply: the other notes' texts, the store's subjects and the fact's own subject.
pub const Known = struct { others: []const []const u8 = &.{}, subjects: []const []const u8 = &.{}, subject: []const u8 = "" };

/// Whether `reply` gives the fact as `ref` does: the reference's answer words, or a notable fact word ("Grey").
pub fn agreesWith(fact: []const u8, question: []const u8, ref: []const u8, whole: []const u8, known: Known) bool {
    var buf: [16 << 10]u8 = undefined;
    const reply = own(fact, question, whole, known, &buf); // "...is pears. (Your sister likes orange best.)" keeps pears
    if (std.mem.trim(u8, reply, " \t\r\n.,;:!?()*_-").len == 0) return false; // every clause is another subject's
    if (!plain(fact, question, ref, reply)) return false; // "Not grey.", "Maybe grey.", "I do not know whether grey."
    if (otherSubject(fact, question, reply, known)) return false; // "Your sister's eyes are brown." for the dog's
    if (userValue(fact) and aboutUser(question) and namesUser(ref) and givesUser(fact, question, reply)) return true;
    if (wording.recalls(fact, question, ref, reply)) return true;
    // a terse reply ("Grey") only: a few words, and no word another note gives that this fact and question do not
    var words: usize = 0;
    var wi = std.mem.tokenizeAny(u8, whole, delims);
    while (wi.next()) |w| {
        words += 1;
        if (w.len < 3 or wording.isFiller(w) or hasStem(fact, w) or hasStem(question, w)) continue;
        for (known.others) |o| if (hasStem(o, w)) return false; // "grey or brown", "brown, not grey"
    }
    if (words > terse_words) return false;
    // value words (in reference and fact, not fillers, not the question's): names and numbers said, half the rest
    var n: usize = 0;
    var said: usize = 0;
    var first = true;
    var it = std.mem.tokenizeAny(u8, ref, delims);
    while (it.next()) |w| : (first = false) {
        if (w.len < 2 or wording.isFiller(w) or !hasStem(fact, w) or hasStem(question, w)) continue;
        const there = hasStem(reply, w);
        if ((!first and std.ascii.isUpper(w[0])) or std.ascii.isDigit(w[0])) if (!there) return false;
        n += 1;
        said += @intFromBool(there);
    }
    return n > 0 and 2 * said >= n;
}

/// Whether a stored reference gives its fact: judged as a reply, with the fact's own words as its reference.
pub fn gives(fact: []const u8, question: []const u8, ref: []const u8, known: Known) bool {
    return agreesWith(fact, question, fact, ref, known);
}

/// Whether `reply` gives a value neither `before` nor the question has: a name, a number, or a stored note's word.
pub fn newValue(question: []const u8, before: []const u8, reply: []const u8, notes: []const []const u8, subjects: []const []const u8) bool {
    const cites: Cites = .init(reply, notes); // a quoted note ("I like pears.") is the user's words, not the reply's
    const asked = askedNoun(question);
    // clause by clause: a denying clause asserts nothing; "I don't know, but your rabbit is Floppy." asserts its second
    var clauses = std.mem.tokenizeAny(u8, reply, ".!?;,");
    while (clauses.next()) |raw| {
        var parts = std.mem.splitSequence(u8, raw, " but ");
        while (parts.next()) |clause| {
            if (denies(clause) or !aboutAsked(question, asked, clause, subjects)) continue;
            var it = std.mem.tokenizeAny(u8, clause, delims);
            var first = true;
            var prev: []const u8 = "";
            while (it.next()) |w| : ({
                first = false;
                prev = w;
            }) {
                if (cites.has(reply, w)) continue;
                if (std.ascii.isDigit(w[0]) and holds(prev, &.{ "item", "statement", "note", "entry", "line" })) continue; // "(item 28)"
                if (std.ascii.isDigit(w[0]) and !hasStem(before, w) and !hasStem(question, w)) return true;
                if (w.len < 2 or wording.isFiller(w) or hasStem(before, w) or hasStem(question, w)) continue;
                if (!first and std.ascii.isUpper(w[0]) and !std.mem.eql(u8, w, "I")) return true;
                if (w.len >= 3 and !common(w)) for (notes) |n| if (hasStem(n, w)) return true;
            }
        }
    }
    return false;
}

/// Whether `now` says every word of `before` (fillers aside, by stem): the same reply, at more length.
pub fn extends(before: []const u8, now: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, before, delims);
    var n: usize = 0;
    while (it.next()) |w| {
        if (w.len < 3 or wording.isFiller(w)) continue;
        n += 1;
        if (!hasStem(now, w)) return false;
    }
    return n > 0;
}

/// Whether a reply copies the notes block: two of its lines (`[21] "..."`) or more; one is a citation and is judged.
pub fn copiesBlock(reply: []const u8) bool {
    var lines: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, reply, i, '[')) |at| : (i = at + 1) {
        var j = at + 1;
        while (j < reply.len and std.ascii.isDigit(reply[j])) j += 1;
        if (j == at + 1 or j >= reply.len or reply[j] != ']') continue;
        j += 1;
        while (j < reply.len and (reply[j] == ' ' or reply[j] == '\t')) j += 1;
        if (j < reply.len and reply[j] == '"') lines += 1;
        if (lines >= 2) return true;
    }
    return false;
}

/// Whether a reply says it does not know (the model's ways of saying nothing was told).
pub fn unknown(reply: []const u8) bool {
    const marks = [_][]const u8{ "don't know", "do not know", "don’t know", "not sure", "no information", "haven't told", "have not told", "haven't mentioned", "have not mentioned", "not mentioned", "don't have", "do not have", "can't know", "cannot know", "no way of knowing", "not been told", "wasn't told", "unknown", "not provided", "not given", "not specified", "not stated", "doesn't tell", "does not tell", "doesn't say", "does not say", "doesn't mention", "does not mention", "no data", "no record", "not explicitly", "isn't explicitly" };
    for (marks) |m| if (std.ascii.findIgnoreCase(reply, m) != null) return true;
    return false;
}

/// Whether a reply gives no answer: unknown()'s ways, or how a long thinking reply says its record lacks the value.
pub fn noAnswer(reply: []const u8) bool {
    if (unknown(reply)) return true;
    const marks = [_][]const u8{ "no mention", "any mention", "don't see", "do not see", "don’t see", "never referenced", "never mentioned", "not referenced", "cannot determine", "can't determine", "nothing about", "not included", "doesn't include", "does not include", "isn't mentioned", "is not mentioned", "aren't mentioned", "no reference to" };
    for (marks) |m| if (std.ascii.findIgnoreCase(reply, m) != null) return true;
    return false;
}

/// "yes" or "no" when the reply opens with one (null: neither).
pub fn yesNo(reply: []const u8) ?bool {
    const t = std.mem.trimStart(u8, reply, " \t\r\n*\"'");
    if (std.ascii.startsWithIgnoreCase(t, "yes") and (t.len == 3 or !std.ascii.isAlphabetic(t[3]))) return true;
    if (std.ascii.startsWithIgnoreCase(t, "no") and (t.len == 2 or !std.ascii.isAlphabetic(t[2]))) return false;
    return null;
}

const delims = " \t\r\n.,;:!?\"'()*_";

/// A reply at most this many words long may agree by its value words alone.
const terse_words = 8;

/// Words that deny, doubt or offer a choice: a clause holding one and a value word does not give the fact as told.
const hedges = [_][]const u8{ "not", "no", "isn", "aren", "don", "doesn", "didn", "never", "maybe", "perhaps", "possibly", "probably", "might", "whether", "unsure", "or", "either", "neither", "nor" };

/// Words that deny: a clause holding one asserts no value (a doubt, "maybe green", still offers one).
const denials = [_][]const u8{ "not", "no", "isn", "aren", "don", "doesn", "didn", "never", "neither", "nor", "without" };

fn denies(clause: []const u8) bool {
    return holds(clause, &denials);
}

fn holds(text: []const u8, list: []const []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, delims);
    while (it.next()) |w| for (list) |h| if (std.ascii.eqlIgnoreCase(w, h)) return true;
    return false;
}

/// Whether `reply` states the value plainly: a hedge word fails it only where it denies, doubts or replaces the value.
fn plain(fact: []const u8, question: []const u8, ref: []const u8, reply: []const u8) bool {
    if (unknown(reply)) return false;
    // "No, your sister lives in Bergen." states Bergen plainly; its no is judged as the answer to a yes-or-no question
    if (yesNo(reply)) |said| {
        if (yesNo(ref)) |want| {
            if (said != want) return false;
        } else if (!said and wording.yesNo(question)) return false;
    }
    // clause by clause: "not grey", "maybe grey" and "grey or brown" fail; "grey; I no longer like cheese" does not
    var hedge = false;
    var stated = false;
    var doubt = false; // a hedged clause ended in a colon: what it opens ("colours you might see: Brown") shares it
    var opened = false; // the last clause ended in that colon (a blank line after it does not close it)
    var start: usize = 0;
    for (0..reply.len + 1) |i| {
        if (i < reply.len and std.mem.indexOfScalar(u8, ".!?;,:\n", reply[i]) == null) continue;
        const stop: u8 = if (i < reply.len) reply[i] else '.';
        const seg = reply[start..i];
        start = i + 1;
        if (std.mem.trim(u8, seg, " \t\r*_-").len == 0) {
            if (stop == '\n' and !opened) doubt = false; // a blank line ends a list
            continue;
        }
        var h_any = false;
        var buts = std.mem.splitSequence(u8, seg, " but ");
        while (buts.next()) |half| {
            var ands = std.mem.splitSequence(u8, half, " and ");
            while (ands.next()) |clause| {
                const h = holds(clause, &hedges);
                const v = valueIn(fact, question, clause);
                if (v and (h or doubt)) return false;
                h_any = h_any or h;
                stated = stated or v;
            }
        }
        hedge = hedge or h_any;
        opened = stop == ':';
        if (opened) doubt = doubt or h_any else if (std.mem.indexOfScalar(u8, ".!?;", stop) != null) doubt = false;
    }
    return !hedge or stated;
}

/// Whether `clause` says a value word: the fact's names and numbers if any, else its marked words the question lacks.
fn valueIn(fact: []const u8, question: []const u8, clause: []const u8) bool {
    if (userValue(fact) and holds(clause, &.{ "you", "yours", "your", "yourself" })) return true; // the user as value
    var named = false;
    var it: units.Units = .init(fact);
    while (it.next()) |u| if (!u.paired and (std.ascii.isDigit(u.raw[0]) or (!u.first and std.ascii.isUpper(u.raw[0])))) {
        named = true;
        if (hasStem(clause, bare(u.raw))) return true;
    };
    if (named) return false;
    it = .init(fact);
    while (it.next()) |u| {
        if (!u.marked() or hasStem(question, bare(u.raw))) continue;
        if (hasStem(clause, bare(u.raw))) return true;
    }
    return false;
}

/// A word as written without the full stop or quote after it ("green." as "green").
fn bare(raw: []const u8) []const u8 {
    return std.mem.trimEnd(u8, raw, ".'");
}

/// Whether the fact's value is the user: it says me or mine ("The tent belongs to me.", "The red cup is mine.").
fn userValue(fact: []const u8) bool {
    return holds(fact, &.{ "me", "mine", "myself" });
}

/// Whether a question asks about the user's world, not the model's own things ("What tent is yours?").
fn aboutUser(question: []const u8) bool {
    return !holds(question, &.{ "your", "yours", "yourself" });
}

/// Whether a reference names the user in either person ("Your tent.", "The tent belongs to the user.").
fn namesUser(ref: []const u8) bool {
    return holds(ref, &.{ "me", "mine", "myself", "you", "yours", "your", "yourself", "user" });
}

/// Whether a reply gives the user as the value: yours, "Your tent.", or "belongs to you" (not "You told me...").
fn givesUser(fact: []const u8, question: []const u8, reply: []const u8) bool {
    if (holds(reply, &.{ "yours", "yourself" })) return true;
    var lead: [48]u8 = undefined; // the fact's word before its me, made normal
    var lead_len: usize = 0;
    var prev: [48]u8 = undefined;
    var prev_len: usize = 0;
    var fi: units.Units = .init(fact);
    while (fi.next()) |u| {
        if (std.mem.eql(u8, u.word, "me") or std.mem.eql(u8, u.word, "mine")) {
            @memcpy(lead[0..prev_len], prev[0..prev_len]);
            lead_len = prev_len;
        }
        prev_len = @min(u.word.len, prev.len);
        @memcpy(prev[0..prev_len], u.word[0..prev_len]);
    }
    prev_len = 0;
    var your = false; // the unit before was "your" (made normal it reads "yor", as colour reads color)
    var ri: units.Units = .init(reply);
    while (ri.next()) |u| {
        if (your and units.says(question, u.word)) return true;
        if (std.mem.eql(u8, u.word, "you") and lead_len > 0 and std.mem.eql(u8, prev[0..prev_len], lead[0..lead_len])) return true;
        your = std.ascii.eqlIgnoreCase(bare(u.raw), "your");
        prev_len = @min(u.word.len, prev.len);
        @memcpy(prev[0..prev_len], u.word[0..prev_len]);
    }
    return false;
}

/// Whether `reply` names a subject the store knows ("your sister") that the fact, its subject and the question do not.
fn otherSubject(fact: []const u8, question: []const u8, reply: []const u8, known: Known) bool {
    for (known.subjects) |s| {
        var buf: [48]u8 = undefined;
        const noun = subjectNoun(s, &buf);
        if (noun.len == 0) continue;
        if (units.says(fact, noun) or units.says(question, noun) or units.says(known.subject, noun)) continue;
        if (units.says(reply, noun)) return true;
    }
    return false;
}

/// A subject's noun as units reads it ("my sister": "sister"), in `buf`; empty for the user, who is no other subject.
fn subjectNoun(s: []const u8, buf: *[48]u8) []const u8 {
    var len: usize = 0;
    var count: usize = 0;
    var it: units.Units = .init(s);
    while (it.next()) |u| : (count += 1) {
        len = @min(u.word.len, buf.len);
        @memcpy(buf[0..len], u.word[0..len]);
    }
    const noun = buf[0..len];
    if (len == 0 or (count == 1 and holds(noun, &.{ "me", "i", "myself", "we", "us" }))) return "";
    return noun;
}

/// `reply` without its clauses about another subject the store knows ("your sister likes orange best"), in `buf`.
fn own(fact: []const u8, question: []const u8, reply: []const u8, known: Known, buf: []u8) []const u8 {
    if (reply.len > buf.len or known.subjects.len == 0) return reply;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= reply.len) : (i += 1) {
        if (i < reply.len and std.mem.indexOfScalar(u8, ".!?;,:\n()", reply[i]) == null) continue;
        const seg = reply[start..i];
        const stop = reply[i..@min(i + 1, reply.len)]; // the delimiter, kept so plain() reads the clauses as before
        start = i + 1;
        if (!otherSubject(fact, question, seg, known)) {
            n = put(buf, n, seg);
        } else {
            var kept: usize = 0;
            var buts = std.mem.splitSequence(u8, seg, " but ");
            while (buts.next()) |half| {
                var ands = std.mem.splitSequence(u8, half, " and ");
                while (ands.next()) |part| {
                    if (otherSubject(fact, question, part, known)) continue;
                    if (kept > 0) n = put(buf, n, " and ");
                    n = put(buf, n, part);
                    kept += 1;
                }
            }
        }
        n = put(buf, n, stop);
    }
    return buf[0..n];
}

fn put(buf: []u8, n: usize, s: []const u8) usize {
    const k = @min(s.len, buf.len - n);
    @memcpy(buf[n..][0..k], s[0..k]);
    return n + k;
}

/// The words a reply calls the user by (in the reply, "you" is the user and "I" the model).
const users = [_][]const u8{ "you", "your", "yours", "yourself", "user" };

/// The subject a question asks about by its possessive ("my neighbour's", "your dog's"), or "".
fn askedNoun(question: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, question, " \t\r\n.,;:!?\"()*_");
    while (it.next()) |w| {
        if (w.len > 2 and std.mem.endsWith(u8, w, "'s")) return w[0 .. w.len - 2];
        if (w.len > 4 and std.mem.endsWith(u8, w, "’s")) return w[0 .. w.len - 4];
    }
    return "";
}

/// Whether a clause may give the asked subject's value: it names it, or names no other subject nor the user instead.
fn aboutAsked(question: []const u8, asked: []const u8, clause: []const u8, subjects: []const []const u8) bool {
    if (asked.len > 0 and hasStem(clause, asked)) return true;
    for (subjects) |s| {
        var buf: [48]u8 = undefined;
        const noun = subjectNoun(s, &buf);
        if (noun.len > 0 and !units.says(question, noun) and units.says(clause, noun)) return false; // "your sister likes..."
    }
    // "yours are green" when the neighbour's are asked (a user clause may leak when the model is asked)
    if (asked.len > 0 and holds(clause, &users)) return false;
    return true;
}

/// The quoted spans of a reply that cite a stored note: the user's own statement, not a value the reply gives.
const Cites = struct {
    spans: [32][2]usize = undefined,
    n: usize = 0,

    fn init(reply: []const u8, notes: []const []const u8) Cites {
        var c: Cites = .{};
        var i: usize = 0;
        while (c.n < c.spans.len) {
            const open = quoteAt(reply, i) orelse break;
            const close = quoteAt(reply, open[1]) orelse break;
            const inner = std.mem.trim(u8, reply[open[1]..close[0]], " \t\r\n.,;:!?*");
            if (inner.len >= 3) for (notes) |n| if (std.ascii.findIgnoreCase(n, inner) != null) {
                c.spans[c.n] = .{ open[1], close[0] };
                c.n += 1;
                break;
            };
            i = close[1];
        }
        return c;
    }

    fn has(c: *const Cites, reply: []const u8, w: []const u8) bool {
        const at = @intFromPtr(w.ptr) -% @intFromPtr(reply.ptr);
        for (c.spans[0..c.n]) |s| if (at >= s[0] and at < s[1]) return true;
        return false;
    }
};

/// The next quote mark at or after `i`, straight or curly, as its first byte and the byte after it; null: none.
fn quoteAt(text: []const u8, i: usize) ?[2]usize {
    var j = i;
    while (j < text.len) : (j += 1) {
        if (text[j] == '"') return .{ j, j + 1 };
        if (j + 3 <= text.len and text[j] == 0xE2 and text[j + 1] == 0x80 and (text[j + 2] == 0x9C or text[j + 2] == 0x9D)) return .{ j, j + 3 };
    }
    return null;
}

/// A word no note's value is ("like", "called"), compared without case.
fn common(w: []const u8) bool {
    var buf: [48]u8 = undefined;
    if (w.len > buf.len) return false;
    const low = std.ascii.lowerString(&buf, w);
    return units.isCommon(low) or std.mem.eql(u8, low, "own"); // "your own statements"; "own" would match "owner"
}

/// Whether `text` has a word of `w`'s stem (case folded; a plural s and the last letters of a long word aside).
fn hasStem(text: []const u8, w: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (w.len > buf.len) return std.ascii.findIgnoreCase(text, w) != null;
    const low = std.ascii.lowerString(&buf, w);
    const base = if (low.len > 3 and low[low.len - 1] == 's') low[0 .. low.len - 1] else low;
    const stem = base[0..@min(base.len, @max(4, base.len -| 2))];
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n.,;:!?\"'()*_");
    while (it.next()) |t| if (t.len >= stem.len and std.ascii.eqlIgnoreCase(t[0..stem.len], stem)) return true;
    return false;
}
