//! The erase reply's "complete": false, with the place named, whenever a place outside the store may hold the note.
//! Each test turns one place on and shows it named, then off (or empty) and shows it gone: its own negative control.
const std = @import("std");
const server = @import("root.zig");
const json = server.json;
const rig = @import("notes_rig_test.zig");
const errors = @import("errors.zig");
const cortheon = @import("cortheon/cortheon.zig");
const tools = @import("cortheon/tools.zig");
const places = @import("notes_erase_places.zig");
const api = @import("engine_api");
const testing = std.testing;

test "prepared requests keep erase requests and prompt cache uncertain" {
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    r.srv.info.prompt_cache = true;
    r.srv.preparing.store(1, .release);
    const found = places.check(r.srv, .{ .asked = true, .ok = true });
    try testing.expectEqual(places.Status.may_hold, found.get(.requests));
    try testing.expectEqual(places.Status.may_hold, found.get(.prompt_cache));
    r.srv.preparing.store(0, .release);
    r.srv.prompt_holders.store(1, .release);
    const held = places.check(r.srv, .{ .asked = true, .ok = true });
    try testing.expectEqual(places.Status.may_hold, held.get(.requests));
    try testing.expectEqual(places.Status.may_hold, held.get(.prompt_cache));
    r.srv.prompt_holders.store(0, .release);
    const finished = places.check(r.srv, .{ .asked = true, .ok = true, .holders = true });
    try testing.expectEqual(places.Status.may_hold, finished.get(.requests));
    try testing.expectEqual(places.Status.may_hold, finished.get(.prompt_cache));
}

test "disabled disk writers do not prove earlier files empty" {
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    const found = places.check(r.srv, .{});
    for ([_]places.Place{ .learn_files, .compaction_memory, .request_log, .promotion }) |place| {
        try testing.expectEqual(places.Status.may_hold, found.get(place));
    }
}

/// Teaches a note, erases it and returns the erase reply.
fn teachAndErase(srv: *server.Server, a: std.mem.Allocator) !rig.Reply {
    const added = try rig.request(srv, a, "POST", "/v1/notes", "{\"text\": \"My favourite colour is green.\"}");
    try testing.expectEqual(@as(u16, 201), added.status);
    const id = added.value.get("id").?.int64().?;
    const erased = try rig.request(srv, a, "DELETE", try std.fmt.allocPrint(a, "/v1/notes/{d}?erase=true", .{id}), null);
    try testing.expectEqual(@as(u16, 200), erased.status);
    return erased;
}

fn named(reply: rig.Reply, place: places.Place) bool {
    for (reply.value.get("remaining_places").?.array) |v| if (std.mem.eql(u8, v.string, @tagName(place))) return true;
    return false;
}

/// The reply with `place` on: incomplete, the place named in both lists and its status may_hold.
fn expectNamed(reply: rig.Reply, place: places.Place) !void {
    errdefer std.debug.print("{s}\n", .{reply.body});
    try testing.expect(!reply.value.get("complete").?.bool);
    try testing.expectEqualStrings("pending", reply.value.get("state").?.string);
    try testing.expect(named(reply, place));
    var said = false;
    for (reply.value.get("remaining").?.array) |v| said = said or std.mem.eql(u8, v.string, place.why());
    try testing.expect(said);
    try testing.expectEqualStrings("may_hold", reply.value.get("places").?.get(@tagName(place)).?.string);
}

/// This place is clear when shown so; unsearched earlier-run disk files still keep the reply pending.
fn expectClear(reply: rig.Reply, place: places.Place, status: places.Status) !void {
    errdefer std.debug.print("{s}\n", .{reply.body});
    try testing.expect(!reply.value.get("complete").?.bool);
    try testing.expectEqualStrings("pending", reply.value.get("state").?.string);
    try testing.expectEqual(status == .may_hold, named(reply, place));
    try testing.expect(named(reply, .compaction_memory));
    try testing.expect(named(reply, .request_log));
    var expected: usize = 0;
    for (std.enums.values(places.Place)) |p| {
        const disk = p == .learn_files or p == .compaction_memory or p == .request_log or p == .promotion;
        const want = disk or (p == place and status == .may_hold);
        try testing.expectEqual(want, named(reply, p));
        expected += @intFromBool(want);
    }
    try testing.expectEqual(expected, reply.value.get("remaining_places").?.array.len);
    try testing.expectEqualStrings("empty", reply.value.get("places").?.get("requests").?.string);
    try testing.expectEqualStrings(@tagName(status), reply.value.get("places").?.get(@tagName(place)).?.string);
}

/// One place's on-then-off check on a fresh rig: `set(srv, on)` turns it on or off.
fn onThenOff(place: places.Place, off_status: places.Status, comptime set: fn (*server.Server, bool) anyerror!void) !void {
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectClear(try teachAndErase(r.srv, a), place, off_status); // the rig starts with every place off
    try set(r.srv, true);
    try expectNamed(try teachAndErase(r.srv, a), place);
    try set(r.srv, false);
    try expectClear(try teachAndErase(r.srv, a), place, off_status);
}

test "erase reply: the engine's prompt cache is named while it is on, and only then" {
    try onThenOff(.prompt_cache, .off, struct {
        fn set(srv: *server.Server, on: bool) !void {
            srv.info.prompt_cache = on;
        }
    }.set);
}

test "erase reply: --learn files remain uncertain when the writer is disabled" {
    try onThenOff(.learn_files, .may_hold, struct {
        fn set(srv: *server.Server, on: bool) !void {
            srv.config.learn = on;
        }
    }.set);
}

test "erase reply: stored Responses are named while one is stored, and not when the store is empty" {
    try onThenOff(.responses, .empty, struct {
        fn set(srv: *server.Server, on: bool) !void {
            if (!on) {
                try testing.expect(srv.store.delete(srv.io, "resp_quote"));
                return;
            }
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var cx: errors.Cx = .{ .a = arena.allocator() };
            const response = (try json.parseText(arena.allocator(), "{\"id\": \"resp_quote\", \"output\": []}")).ok;
            const said = (try json.parseText(arena.allocator(), "{\"role\": \"user\", \"content\": \"My favourite colour is green.\"}")).ok;
            try srv.store.put(srv.io, &cx, response, &.{said});
        }
    }.set);
}

const NoWeb = struct {
    fn search(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize) anyerror!tools.Found {
        return error.Offline;
    }
    fn fetch(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize, _: []const u8) anyerror!tools.Page {
        return error.Offline;
    }
    var dummy: u8 = 0;
    const web: tools.Web = .{ .ctx = &dummy, .search = search, .fetch = fetch };
};

test "erase reply: Cortheon's hidden rounds are named while one is kept, not when it keeps none or is off" {
    // on and holding a round: named; on and empty: not; off: not
    try onThenOff(.cortheon, .off, struct {
        fn set(srv: *server.Server, on: bool) !void {
            if (!on) {
                srv.cortheon.?.deinit();
                srv.cortheon = null;
                return;
            }
            srv.cortheon = try cortheon.State.initWith(testing.allocator, testing.io, NoWeb.web);
            srv.cortheon.?.memory.put(7, "[{\"role\": \"tool\", \"content\": \"My favourite colour is green.\"}]");
        }
    }.set);
    const r = try rig.Rig.init(testing.allocator);
    defer r.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    r.srv.cortheon = try cortheon.State.initWith(testing.allocator, testing.io, NoWeb.web);
    try expectClear(try teachAndErase(r.srv, arena.allocator()), .cortheon, .empty);
}

test "erase reply: compaction memory files remain uncertain when the writer is disabled" {
    try onThenOff(.compaction_memory, .may_hold, struct {
        fn set(srv: *server.Server, on: bool) !void {
            srv.config.compact_memory = if (on) "/tmp/tf-compact-memory" else null;
        }
    }.set);
}

test "erase reply: the request log remains uncertain when the writer is disabled" {
    try onThenOff(.request_log, .may_hold, struct {
        fn set(srv: *server.Server, on: bool) !void {
            srv.config.request_log = if (on) "/tmp/tf-request-log.jsonl" else null;
        }
    }.set);
}

test "erase reply: promotion records are named while --slide is on or its fact graph holds a fact, and only then" {
    try onThenOff(.promotion, .may_hold, struct {
        fn set(srv: *server.Server, on: bool) !void {
            srv.config.slide = on;
        }
    }.set);
    try onThenOff(.promotion, .may_hold, struct {
        fn set(srv: *server.Server, on: bool) !void {
            if (on) try testing.expect(srv.slide.add("My favourite colour is green.", "chat", 0) != 0) else srv.slide.clear();
        }
    }.set);
}

/// An engine whose status says `busy` requests are running.
const Busy = struct {
    busy: u32 = 0,
    fn engine(b: *Busy) api.Engine {
        return .{ .ctx = b, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn submit(_: *anyopaque, _: api.Id, _: *const api.Request, _: api.Sink) api.SubmitError!void {
        return error.Busy;
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(ctx: *anyopaque, out: *api.Status, _: []u32) void {
        const b: *Busy = @ptrCast(@alignCast(ctx));
        out.* = .{ .running = b.busy };
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    var it: Busy = .{};
};

test "erase reply: requests the engine is running are named while any runs, and not when it is idle" {
    try onThenOff(.requests, .empty, struct {
        fn set(srv: *server.Server, on: bool) !void {
            Busy.it.busy = if (on) 1 else 0;
            srv.engine = Busy.it.engine();
        }
    }.set);
}
