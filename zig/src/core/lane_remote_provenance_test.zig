//! #1594 step 2b on the real lane host, continued: which copy a stream stands on, what it lets go, what its reply says.
const std = @import("std");
const pc = @import("prompt_cache.zig");
const fixture = @import("lane_remote_test.zig");
const Peer = fixture.Peer;
const Exp = fixture.Exp;
const Kept = fixture.Kept;
const runWith = fixture.runWith;
const unborrowed = fixture.unborrowed;
const six = fixture.six;
const id = fixture.id;
const t = std.testing;

var none: u8 = 0;

/// A prompt cache over Kept's copies, as lane_remote_test.zig's tests make one.
fn cache() pc.Store {
    return pc.Store.init(t.allocator, .{ .ptr = &none, .vtable = &.{ .bytes = Kept.bytes, .save = Kept.save, .restore = Kept.restore, .drop = Kept.drop } }, .{ .min_prompt = 0 }, 1 << 20);
}

/// Where the state a lookup finds stands, and whether it is remote.
const Found = struct { at: u32, remote: bool };

fn found(store: *pc.Store, prompt: []const u32) ?Found {
    const e = store.find(prompt, &.{}, &.{}) orelse return null;
    return .{ .at = e.at, .remote = e.remote };
}

test "handoff: a repeat whose lookup finds its exact cut resumes below it on a remote state, and the stream stays remote" {
    var store = cache();
    defer store.deinit();
    store.keep_remote = true;
    try t.expect(store.keep(&six, 3, null, &.{}, &.{})); // built on another machine's prefix, before the cut
    store.keep_remote = false;
    try t.expect(store.keep(&six, 5, null, &.{}, &.{})); // the engine's own at the cut, which the lookup finds first
    var peer: Peer = .{ .at = 0 };
    var e: Exp = .{};
    const seen = try runWith(&peer, &.{ .prompt = &six, .max_tokens = 1, .handoff = id }, &e, &store);
    try t.expect(seen.restoring and seen.remote); // the remote state's provenance, not the exact cut's
    try t.expectEqual(@as(u32, 3), seen.at);
    try t.expectEqual(@as(?usize, 5), e.tokens);
    try t.expectEqual(@as(?u32, 3), seen.remote_prefix); // so its reply is outside the exactness contract
    try t.expectEqual(@as(?Found, .{ .at = 5, .remote = false }), found(&store, &six)); // and served the pass's keep
    try t.expectEqual(@as(u64, 2), store.counts.kept);
    try unborrowed(&store);
}
