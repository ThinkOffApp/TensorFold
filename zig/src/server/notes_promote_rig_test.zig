//! Promotion in a running server: in-weights notes leave every chat block, blocks count as use, off changes nothing.
const std = @import("std");
const json = @import("json.zig");
const rig = @import("notes_rig_test.zig");
const promote = @import("notes/promote.zig");
const pjson = @import("notes/promote_json.zig");
const notes_promote = @import("notes_promote.zig");
const testing = std.testing;

const ask = "{\"messages\": [{\"role\": \"user\", \"content\": \"What colour is my car?\"}], \"notes\": true, \"notes_echo\": true, \"notes_write\": false, \"max_tokens\": 1}";

fn ids(v: json.Value) ![]const i64 {
    const n = v.get("notes") orelse return error.NoNotes;
    const xs = (n.get("ids") orelse return error.NoNotes).items() orelse return error.NoNotes;
    const out = try testing.allocator.alloc(i64, xs.len);
    for (xs, out) |x, *o| o.* = x.int64() orelse return error.NoNotes;
    return out;
}

fn block(v: json.Value) []const u8 {
    const n = v.get("notes") orelse return "";
    return n.strField("block") orelse "";
}

test "promotion rig: an in-weights note leaves the chat block, its block counts as use, and off is as before" {
    _ = &notes_promote.Promoter.runNight; // the night's server side compiles with the rest
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    const off = try rig.request(r.srv, a, "POST", "/v1/chat/completions", ask);
    try testing.expectEqual(@as(u16, 200), off.status);
    const before = try ids(off.value);
    defer testing.allocator.free(before);
    try testing.expect(before.len >= 2);
    try testing.expectEqual(@as(u16, 404), (try rig.request(r.srv, a, "GET", "/v1/promotion", null)).status);
    // what a client gets when it leaves that note out itself (the promoter off)
    const client = try rig.request(r.srv, a, "POST", "/v1/chat/completions", try std.fmt.allocPrint(a, "{{\"messages\": [{{\"role\": \"user\", \"content\": \"What colour is my car?\"}}], \"notes\": true, \"notes_echo\": true, \"notes_write\": false, \"notes_exclude\": [{d}], \"max_tokens\": 1}}", .{before[0]}));
    const client_ids = try ids(client.value);
    defer testing.allocator.free(client_ids);
    // a state whose first retrieved note is in weights, on disk beside the snapshot, read at the promoter's start
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    const key = try std.fmt.allocPrint(a, "s{d}", .{before[0]});
    try st.facts.append(st.alloc(), .{ .key = key, .text = "x", .status = .in_weights, .alone = 2 });
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    var owned = true;
    defer if (owned) p.deinit();
    r.srv.promote = p;
    defer r.srv.promote = null;
    const on = try rig.request(r.srv, a, "POST", "/v1/chat/completions", ask);
    const with = try ids(on.value);
    defer testing.allocator.free(with);
    try testing.expect(std.mem.indexOfScalar(i64, with, before[0]) == null);
    try testing.expectEqualSlices(i64, client_ids, with); // as if the client had left it out
    try testing.expectEqualStrings(block(client.value), block(on.value));
    try testing.expect(p.retrieved.contains(try std.fmt.allocPrint(a, "s{d}", .{with[0]})));
    try testing.expect(!p.retrieved.contains(key)); // left out: not in this block
    const got = try rig.request(r.srv, a, "GET", "/v1/promotion", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings("in_weights", (got.value.get("state").?.get("facts").?.items().?)[0].strField("status").?);
    // a client's own exclusions are kept beside the server's
    const both = try rig.request(r.srv, a, "POST", "/v1/chat/completions", try std.fmt.allocPrint(a, "{{\"messages\": [{{\"role\": \"user\", \"content\": \"What colour is my car?\"}}], \"notes\": true, \"notes_write\": false, \"notes_exclude\": [{d}], \"max_tokens\": 1}}", .{before[1]}));
    const both_ids = try ids(both.value);
    defer testing.allocator.free(both_ids);
    try testing.expect(std.mem.indexOfScalar(i64, both_ids, before[0]) == null and std.mem.indexOfScalar(i64, both_ids, before[1]) == null);
    // off again: the same block as before, byte for byte
    r.srv.promote = null;
    p.deinit();
    owned = false;
    const again = try rig.request(r.srv, a, "POST", "/v1/chat/completions", ask);
    const back = try ids(again.value);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(i64, before, back);
    try testing.expectEqualStrings(block(off.value), block(again.value));
    try testing.expect(block(off.value).len > 0);
}

test "promotion rig: a note written after a night is keyed by its write, and an erase's renumbering is followed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    const w1 = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My boat is green.\", \"subject\": \"my boat\"}");
    try testing.expectEqual(@as(u16, 201), w1.status);
    const w2 = try rig.request(r.srv, a, "POST", "/v1/notes", "{\"text\": \"My kite is orange.\", \"subject\": \"my kite\"}");
    const kite: i64 = w2.value.get("id").?.int64().?;
    const kite_source = w2.value.strField("source").?;
    var st = promote.State.init(testing.allocator, .{});
    defer st.deinit();
    try st.facts.append(st.alloc(), .{ .key = kite_source, .text = "My kite is orange.", .status = .in_weights, .alone = 2 });
    try pjson.writeFile(a, try std.fmt.allocPrint(a, "{s}.promote", .{r.snap}), try pjson.encode(&st, a));
    var why: []const u8 = "";
    const p = try notes_promote.Promoter.init(testing.allocator, testing.io, r.srv, r.store(), r.snap, .{ .every_ms = 600_000 }, &why);
    defer p.deinit();
    r.srv.promote = p;
    const kite_ask = "{\"messages\": [{\"role\": \"user\", \"content\": \"What colour is my kite?\"}], \"notes\": true, \"notes_write\": false, \"max_tokens\": 1}";
    const k1 = try ids((try rig.request(r.srv, a, "POST", "/v1/chat/completions", kite_ask)).value);
    defer testing.allocator.free(k1);
    try testing.expect(std.mem.indexOfScalar(i64, k1, kite) == null);
    // the boat's write erased: the kite's note moves down one id, and is still the one left out
    const boat: i64 = w1.value.get("id").?.int64().?;
    const er = try rig.request(r.srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{boat}), null);
    try testing.expectEqual(@as(u16, 200), er.status);
    const k2 = try ids((try rig.request(r.srv, a, "POST", "/v1/chat/completions", kite_ask)).value);
    defer testing.allocator.free(k2);
    try testing.expect(std.mem.indexOfScalar(i64, k2, kite - 1) == null);
    // control: without the promoter the kite's note is in the block
    r.srv.promote = null;
    const k3 = try ids((try rig.request(r.srv, a, "POST", "/v1/chat/completions", kite_ask)).value);
    defer testing.allocator.free(k3);
    try testing.expect(std.mem.indexOfScalar(i64, k3, kite - 1) != null);
}
