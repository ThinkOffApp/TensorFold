//! The fact graph beside the pocket: kept at a mark, put back by a rewind, and let go of neurons once they are zeroed.
const std = @import("std");
const api = @import("engine_api");
const slide_graph = @import("slide_graph.zig");
const Graph = slide_graph.Graph;
const State = slide_graph.State;
const Allocator = std.mem.Allocator;

/// A fact as a mark found it: its state, its neurons and its message.
pub const Was = struct { id: u32, state: State, neurons: []const api.Neuron, message: []const u8 };

/// The graph as a mark found it: every fact then, and the next id (facts from it on came after the mark).
pub const Kept = struct { facts: []const Was, next: u32 };

/// Each fact's state, neurons and message now (slices the graph keeps while it lives), and the next id.
pub fn keep(g: *Graph, a: Allocator) !Kept {
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const out = try a.alloc(Was, g.facts.items.len);
    for (g.facts.items, out) |f, *w| w.* = .{ .id = f.id, .state = f.state, .neurons = f.neurons, .message = f.message };
    return .{ .facts = out, .next = g.next };
}

/// The facts as `k` kept them; those added since are taken back (missed, no neurons), `why` their message.
pub fn rewound(g: *Graph, k: Kept, why: []const u8) void {
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const message = g.arena.allocator().dupe(u8, why) catch "";
    for (g.facts.items) |*f| {
        if (f.id >= k.next) {
            f.state = .missed;
            f.phase = null;
            f.neurons = &.{};
            f.message = message;
            continue;
        }
        for (k.facts) |w| if (w.id == f.id) {
            f.state = w.state;
            f.neurons = w.neurons;
            f.message = w.message;
        };
    }
    g.save();
}

/// Neurons zeroed and saved: no fact lists them any more, and a fact that lost some says so (it keeps its state).
pub fn zeroed(g: *Graph, gone: []const api.Neuron) void {
    if (gone.len == 0) return;
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const a = g.arena.allocator();
    for (g.facts.items) |*f| {
        var left: std.ArrayList(api.Neuron) = .empty;
        for (f.neurons) |x| if (!has(gone, x)) left.append(a, x) catch return;
        if (left.items.len == f.neurons.len) continue;
        f.neurons = left.items;
        f.message = "zeroed: its neurons were taken out of the pocket";
    }
    g.save();
}

fn has(ns: []const api.Neuron, n: api.Neuron) bool {
    for (ns) |x| if (x.layer == n.layer and x.neuron == n.neuron) return true;
    return false;
}
