//! #1594 step 2b's kept remote states: a state built on another machine's prefix, kept apart from the engine's own.
const std = @import("std");
const pc = @import("prompt_cache.zig");

/// The engine's own copy `e` just kept hides every remote entry at the same tokens: lookups see the exact one only.
pub fn retireTwins(s: *pc.Store, e: *const pc.Entry) void {
    for (s.entries.items) |o| if (o != e and o.remote and !o.expired and o.at == e.at and std.mem.eql(u32, o.tokens, e.tokens)) {
        o.expired = true; // reclaimed at the next safe host boundary, like any expired entry (a borrower keeps it)
    };
}
