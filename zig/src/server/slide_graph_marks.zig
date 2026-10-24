//! A night's graph checkpoint follows physical rollback and reports persistence failures for retry.
const std = @import("std");
const api = @import("engine_api");
const graph = @import("slide_graph.zig");
const talks = @import("slide_talks.zig");
const Allocator = std.mem.Allocator;

pub const Kept = struct { facts: []graph.Fact, talks: []talks.Talk, next: u32 };

pub fn keep(g: *graph.Graph, a: Allocator) !Kept {
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const out = try a.dupe(graph.Fact, g.facts.items);
    for (out) |*f| f.neurons = try a.dupe(api.Neuron, f.neurons);
    return .{ .facts = out, .talks = try a.dupe(talks.Talk, g.talks.list.items), .next = g.next };
}

/// Later facts stay visible as missed; IDs never move backwards, and failed persistence restores the whole graph.
pub fn rewound(g: *graph.Graph, k: Kept, why: []const u8) !void {
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const was = try g.gpa.dupe(graph.Fact, g.facts.items);
    defer g.gpa.free(was);
    const old_talks = try g.gpa.dupe(talks.Talk, g.talks.list.items);
    defer g.gpa.free(old_talks);
    try g.talks.list.ensureTotalCapacity(g.gpa, @max(old_talks.len, k.talks.len));
    const a = g.arena.allocator();
    const message = try a.dupe(u8, why);
    const restored = try a.dupe(graph.Fact, k.facts);
    for (restored) |*f| f.neurons = try a.dupe(api.Neuron, f.neurons);
    errdefer {
        @memcpy(g.facts.items, was);
        g.talks.list.clearRetainingCapacity();
        g.talks.list.appendSliceAssumeCapacity(old_talks);
    }
    for (g.facts.items) |*f| {
        if (f.id >= k.next) {
            f.state = .missed;
            f.phase = null;
            f.neurons = &.{};
            f.message = message;
        } else for (restored) |old| if (old.id == f.id) {
            f.* = old;
            break;
        };
    }
    g.talks.list.clearRetainingCapacity();
    g.talks.list.appendSliceAssumeCapacity(k.talks);
    try g.persist();
}

pub fn zeroed(g: *graph.Graph, gone: []const api.Neuron) !void {
    if (gone.len == 0) return;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const was = try g.gpa.dupe(graph.Fact, g.facts.items);
    defer g.gpa.free(was);
    errdefer @memcpy(g.facts.items, was);
    const a = g.arena.allocator();
    for (g.facts.items) |*f| {
        var left: std.ArrayList(api.Neuron) = .empty;
        for (f.neurons) |x| if (!has(gone, x)) try left.append(a, x);
        if (left.items.len == f.neurons.len) continue;
        f.neurons = left.items;
        f.message = "zeroed: its neurons were taken out of the pocket";
    }
    try g.persist();
}

fn has(ns: []const api.Neuron, n: api.Neuron) bool {
    for (ns) |x| if (x.layer == n.layer and x.neuron == n.neuron) return true;
    return false;
}
