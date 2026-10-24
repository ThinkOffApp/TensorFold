//! Conversations record promotion provenance so erasure preserves unrelated scripts and fact chains.
const std = @import("std");
const Graph = @import("slide_graph.zig").Graph;
const Turn = @import("slide_talks.zig").Turn;
const Allocator = std.mem.Allocator;

fn includes(keys: []const []const u8, key: []const u8) bool {
    for (keys) |x| if (std.mem.eql(u8, x, key)) return true;
    return false;
}

/// Called under the graph mutex; a generated script can quote any live or currently learning promotion fact.
pub fn keep(g: *Graph, name: []const u8, turns: []const Turn) !void {
    const a = g.arena.allocator();
    var keys: std.ArrayList([]const u8) = .empty;
    for (g.facts.items) |f| if (f.promotion_key.len > 0 and (f.neurons.len > 0 or f.state == .learning)) {
        if (!includes(keys.items, f.promotion_key)) try keys.append(a, f.promotion_key);
    };
    try g.talks.keepOwned(g.gpa, a, name, turns, keys.items);
}

/// Drop only scripts with affected provenance, returning the owned questions whose teacher facts must go too.
pub fn scrub(g: *Graph, keys: []const []const u8) ![]const []const u8 {
    var questions: std.ArrayList([]const u8) = .empty;
    const a: Allocator = g.arena.allocator();
    for (g.facts.items) |f| if (f.promotion_key.len > 0 and includes(keys, f.promotion_key)) {
        try questions.appendSlice(a, f.questions);
        for (f.answers) |answer| try questions.append(a, answer.question);
    };
    var i: usize = 0;
    while (i < g.talks.list.items.len) {
        const affected = for (g.talks.list.items[i].promotion_keys) |key| {
            if (includes(keys, key)) break true;
        } else false;
        if (affected) _ = g.talks.list.orderedRemove(i) else i += 1;
    }
    return questions.items;
}
