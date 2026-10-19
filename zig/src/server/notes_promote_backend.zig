//! The night's backend in the server: the learner, the store's notes and the model's questions and answers.
const std = @import("std");
const errors = @import("errors.zig");
const log = @import("log.zig");
const np = @import("notes_promote.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const ops = @import("notes_ops.zig");
const past_mod = @import("notes/past.zig");
const slide = @import("slide.zig");
const slide_ask = @import("slide_ask.zig");
const side = @import("slide_side.zig");
const prompts = @import("slide_prompts.zig");
const slide_route = @import("slide_route.zig");
const probes_mod = @import("notes/promote_probes.zig");
const Server = @import("server.zig").Server;
const Promoter = np.Promoter;
const Stop = np.Stop;
const clockMs = np.clockMs;
const keyOf = np.keyOf;
const agreesWith = np.agreesWith;
const judge = @import("notes/promote_judge.zig");
const Allocator = std.mem.Allocator;

/// How a note's own question is asked for: the model writes what its user would ask to hear the note again.
const question_prompt = "The user once told you: \"{s}\"\nWrite the one short question the user would ask you later to hear this again, in the user's own words (for example: What is my dog's name?). Reply with the question only.";

/// How a two-note question is asked for: one the user could ask that needs both statements.
const pair_prompt = "The user once told you: \"{s}\" and \"{s}\"\nWrite one short question the user could ask you that needs both statements to answer, a yes-or-no comparison or a two-step question, in the user's own words. Reply with the question only.";

/// Tokens a night's question is answered in at most (the learner's own checks read 48).
pub const answer_tokens = 48;

/// A reference written again is sampled at the lesson's wording temperature, so it can differ from the greedy one.
const again_temperature = 0.9;

/// The night's learner, notes and questions: the server's own (slide.teachText, slide_ask, the store's lookup).
pub const Backend = struct {
    p: *Promoter,
    arena: Allocator, // the night's
    listed: ?[]const ops.View = null, // the current notes, listed once a night
    marked: ?slide.Mark = null, // the graph and teacher as the learner's last mark tonight found them

    fn srv(b: *Backend) *Server {
        return b.p.srv;
    }
    fn stopper(b: *Backend) Stop {
        return .{ .flag = &b.p.stop };
    }

    /// The neurons the slide graph records for learned facts of `text` (a lesson a stop or a failure left unrecorded).
    pub fn placedFor(b: *Backend, a: Allocator, text: []const u8) ![]const promote.Neuron {
        const graph = try b.srv().slide.learnedChat(a, 0, std.math.maxInt(usize));
        var out: std.ArrayList(promote.Neuron) = .empty;
        for (graph) |g| if (std.mem.eql(u8, g.text, text)) try out.appendSlice(a, g.neurons);
        return out.items;
    }

    pub fn notes(b: *Backend, a: Allocator) ![]promote.Note {
        const list = try ops.list(b.p.store, a, false);
        const out = try a.alloc(promote.Note, list.len);
        for (list, out) |v, *n| n.* = .{ .id = v.id, .key = try keyOf(a, v), .text = v.text, .told = v.told, .fact = v.kind == .fact };
        return out;
    }
    pub fn firstSeen(b: *Backend, key: []const u8) ?u32 {
        b.p.mu.lockUncancelable(b.p.io);
        defer b.p.mu.unlock(b.p.io);
        return b.p.seen.get(key);
    }
    pub fn wasRetrieved(b: *Backend, key: []const u8) bool {
        b.p.mu.lockUncancelable(b.p.io);
        defer b.p.mu.unlock(b.p.io);
        return b.p.retrieved.contains(key);
    }
    pub fn nowMs(b: *Backend) i64 {
        return clockMs(b.p.io);
    }

    /// The fact's text through the learn route's own code; a text that splits into facts not all kept keeps none.
    pub fn teach(b: *Backend, a: Allocator, text: []const u8) !promote.Taught {
        if (b.p.stop.load(.acquire)) return error.Stopped;
        var out: slide.Out = .{ .conn = null, .a = a };
        slide.teachText(b.srv(), a, text, "chat", b.stopper(), &out);
        if (b.p.stop.load(.acquire)) return error.Stopped;
        if (out.results.items.len == 0) return .{ .kept = false, .why = "missed: the learner found no fact in its text" };
        const graph = try b.srv().slide.learnedChat(a, 0, std.math.maxInt(usize));
        var neurons: std.ArrayList(promote.Neuron) = .empty;
        var qs: std.ArrayList([]const u8) = .empty;
        var all = true;
        for (out.results.items) |r| {
            all = all and r.recalled;
            if (!r.recalled) continue;
            for (graph) |g| if (g.id == r.id) {
                try neurons.appendSlice(a, g.neurons);
                try qs.appendSlice(a, g.questions);
            };
        }
        if (!all) {
            if (neurons.items.len > 0 and !slide.retire(b.srv(), a, neurons.items)) return error.RetireRefused;
            return .{ .kept = false, .why = "missed: the learner did not keep every fact of its text; it stays a note" };
        }
        return .{ .kept = true, .neurons = neurons.items, .questions = qs.items };
    }

    pub fn retire(b: *Backend, a: Allocator, ns: []const promote.Neuron) !void {
        if (!slide.retire(b.srv(), a, ns)) return error.RetireRefused;
    }

    /// The learner keeps the pocket as it is, the graph and teacher beside it (a new mark replaces the last one).
    pub fn mark(b: *Backend, a: Allocator) !void {
        b.marked = slide.mark(b.srv(), a) orelse return error.MarkRefused;
    }

    /// The pocket, graph and teacher put back as the last mark found them and saved; refused without a mark.
    pub fn rewind(b: *Backend, a: Allocator) !void {
        const m = b.marked orelse return error.NothingToRewind;
        if (!slide.rewind(b.srv(), a, m, "taken back: the night that taught it made answers worse")) return error.RewindRefused;
        b.marked = null;
    }

    /// Each question answered by the untaught model with the fact before it, as a lesson writes its answers.
    pub fn references(b: *Backend, a: Allocator, fact: []const u8, qs: []const []const u8) ![]const []const u8 {
        const note = try std.fmt.allocPrint(a, prompts.told_note, .{fact});
        const out = try a.alloc([]const u8, qs.len);
        const Job = struct {
            b: *Backend,
            a: Allocator,
            note: []const u8,
            qs: []const []const u8,
            out: [][]const u8,
            pub fn run(j: *const @This(), i: usize) !void {
                var cx: errors.Cx = .{ .a = j.a };
                j.out[i] = (try slide_ask.askBase(j.b.srv(), &cx, j.note, j.qs[i], answer_tokens, j.b.stopper())).content;
            }
        };
        try side.each(qs.len, &Job{ .b = b, .a = a, .note = note, .qs = qs, .out = out });
        return out;
    }

    /// A reference written once more, sampled (seeded by the prompt) like a lesson's extra wordings: greedy repeats.
    pub fn referenceAgain(b: *Backend, a: Allocator, fact: []const u8, q: []const u8) ![]const u8 {
        var cx: errors.Cx = .{ .a = a };
        const note = try std.fmt.allocPrint(a, prompts.told_note, .{fact});
        return (try slide_ask.askBaseAt(b.srv(), &cx, note, q, answer_tokens, again_temperature, b.stopper())).content;
    }

    /// Whether a reference answer gives its fact, as the judge reads a reply against the fact's own words.
    pub fn gives(b: *Backend, fact: []const u8, question: []const u8, ref: []const u8) bool {
        return judge.gives(fact, question, ref, b.knownOf(fact));
    }

    /// Each question as production asks it: the store's block for it (these notes left out) first, on the live weights.
    pub fn askAll(b: *Backend, a: Allocator, asks: []const promote.Ask) ![]const []const u8 {
        const out = try a.alloc([]const u8, asks.len);
        const Job = struct {
            b: *Backend,
            a: Allocator,
            asks: []const promote.Ask,
            out: [][]const u8,
            pub fn run(j: *const @This(), i: usize) !void {
                var cx: errors.Cx = .{ .a = j.a };
                const s = j.b.srv();
                const q = j.asks[i];
                var block: ?[]const u8 = null;
                if (q.exclude) |ex| {
                    const qids = s.text.encode(j.a, q.q, false) catch return error.Tokenizer;
                    const st = j.b.p.store;
                    const found = try st.retrieve(j.a, s.text, qids, past_mod.isPast(q.q), st.settings().cap, ex);
                    if (found.block.len > 0) block = found.block;
                }
                const reply = if (q.think) try slide_ask.askThinkingAfter(s, &cx, block, q.q, j.b.stopper()) else try slide_ask.ask(s, &cx, block, q.q, answer_tokens, j.b.stopper());
                j.out[i] = reply.content;
            }
        };
        try side.each(asks.len, &Job{ .b = b, .a = a, .asks = asks, .out = out });
        return out;
    }

    /// The question the note answers, as its user would ask it, written by the untaught model ("" when it gives none).
    pub fn questionOf(b: *Backend, a: Allocator, fact: []const u8) ![]const u8 {
        var cx: errors.Cx = .{ .a = a };
        const ask = try std.fmt.allocPrint(a, question_prompt, .{fact});
        const r = try slide_ask.askBase(b.srv(), &cx, null, ask, 32, b.stopper());
        const q = std.mem.trim(u8, r.content, " \t\r\n\"*");
        return if (q.len > 0 and q.len < 200 and q[q.len - 1] == '?' and std.mem.indexOfScalar(u8, q, '\n') == null) q else "";
    }

    /// The note's own question asked about others the user knows and of the model (the learner's `others`).
    pub fn neighbours(_: *Backend, a: Allocator, question: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (probes_mod.swaps) |who| if (try probes_mod.swapSubject(a, question, who)) |q| try out.append(a, q);
        const theirs = try slide_route.others(a, question, null, &.{});
        if (theirs.len > 0) try out.append(a, theirs[theirs.len - 1]); // asked of the model itself
        for (theirs[0..theirs.len -| 1]) |q| try out.append(a, q); // others' things of the subject's kind, last
        return out.items;
    }

    /// A question that needs both notes (a yes/no comparison or a two-step one), written by the untaught model.
    pub fn pairQuestion(b: *Backend, a: Allocator, one: []const u8, two: []const u8) ![]const u8 {
        var cx: errors.Cx = .{ .a = a };
        const ask = try std.fmt.allocPrint(a, pair_prompt, .{ one, two });
        const r = try slide_ask.askBase(b.srv(), &cx, null, ask, 40, b.stopper());
        const q = std.mem.trim(u8, r.content, " \t\r\n\"*");
        return if (q.len > 0 and q.len < 200 and q[q.len - 1] == '?' and std.mem.indexOfScalar(u8, q, '\n') == null) q else "";
    }

    /// The current notes' texts (a word of one in a "don't know" reply is a value the reply gives).
    pub fn texts(b: *Backend, _: Allocator) ![]const []const u8 {
        return b.knownOf("").others;
    }

    /// A regression probe (two replies) or an alone ask (one), judged: a line of SNAPSHOT.promote-probes.jsonl.
    pub fn recordProbe(b: *Backend, r: promote.Record) void {
        pjson.appendProbe(b.arena, b.p.path, r);
        if (r.why.len > 0) log.line("notes promotion: {s} \"{s}\" of {s}: {s}", .{ r.kind, r.q, r.key, r.why });
    }

    pub fn agrees(b: *Backend, fact: []const u8, question: []const u8, ref: []const u8, reply: []const u8) bool {
        return agreesWith(fact, question, ref, reply, b.knownOf(fact));
    }

    /// The other current notes' texts, every note's subject and the fact's own: what the judge reads a reply against.
    fn knownOf(b: *Backend, fact: []const u8) judge.Known {
        const list = b.listed orelse (ops.list(b.p.store, b.arena, false) catch return .{});
        b.listed = list;
        var others: std.ArrayList([]const u8) = .empty;
        var subjects: std.ArrayList([]const u8) = .empty;
        var own: []const u8 = "";
        for (list) |v| {
            if (std.mem.eql(u8, v.text, fact)) own = v.subject else others.append(b.arena, v.text) catch return .{};
            subjects.append(b.arena, v.subject) catch return .{};
        }
        return .{ .others = others.items, .subjects = subjects.items, .subject = own };
    }

    /// Whether a control's changed reply still says nothing new, as the learner's own judge decides.
    pub fn same(b: *Backend, a: Allocator, question: []const u8, before: []const u8, reply: []const u8) !bool {
        var cx: errors.Cx = .{ .a = a };
        const v = try slide_ask.askBase(b.srv(), &cx, null, try std.fmt.allocPrint(a, prompts.same_prompt, .{ question, before, reply }), 4, b.stopper());
        return std.ascii.startsWithIgnoreCase(std.mem.trim(u8, v.content, " \t\r\n\"*"), "no");
    }

    pub fn persist(b: *Backend, s: *const promote.State) !void {
        var arena: std.heap.ArenaAllocator = .init(b.p.gpa);
        defer arena.deinit();
        try pjson.writeFile(arena.allocator(), b.p.path, try pjson.encode(s, arena.allocator()));
    }
};
