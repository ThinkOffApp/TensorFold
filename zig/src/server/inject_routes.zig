//! POST /v1/chat/completions/{id}/inject: context a client adds to its own running reply, read between two rounds.
const std = @import("std");
const api = @import("engine_api");
const json = @import("json");
const errors = @import("errors.zig");
const http_body = @import("http_body.zig");
const prompt = @import("prompt.zig");
const routes = @import("routes.zig");
const Server = @import("server.zig").Server;
const Conn = @import("http_conn.zig").Conn;
const Value = json.Value;
const Cx = errors.Cx;
const Allocator = std.mem.Allocator;

const head = "/v1/chat/completions/";
const tail = "/inject";

/// The reply id in `/v1/chat/completions/{id}/inject`, or null for any other path.
pub fn route(path: []const u8) ?[]const u8 {
    if (path.len <= head.len + tail.len or !std.mem.startsWith(u8, path, head) or !std.mem.endsWith(u8, path, tail)) return null;
    const id = path[head.len .. path.len - tail.len];
    return if (std.mem.indexOfScalar(u8, id, '/') == null) id else null;
}

/// A running reply that takes injected context (its request's ``inject_room``): its queue, and whether it still thinks.
pub const Live = struct {
    inject: api.Inject,
    think_end: ?u32 = null, // the token that closes its think block (null: none to close)
    answering: std.atomic.Value(bool) = .init(true), // past its think block: a reopened turn starts without thinking

    /// The reply's own token `t` landed (the request's thread).
    pub fn saw(l: *Live, t: u32) void {
        if (l.think_end) |end| if (t == end) l.answering.store(true, .release);
    }
};

/// The running replies that take injected context, by the id their clients got.
pub const Table = struct {
    mutex: std.Io.Mutex = .init,
    live: std.StringHashMapUnmanaged(*Live) = .empty,

    pub fn add(t: *Table, srv: *Server, id: []const u8, l: *Live) Allocator.Error!void {
        t.mutex.lockUncancelable(srv.io);
        defer t.mutex.unlock(srv.io);
        try t.live.put(srv.gpa, id, l);
    }

    /// Before the reply's request frees `l`: a push from here on finds no reply.
    pub fn remove(t: *Table, srv: *Server, id: []const u8) void {
        t.mutex.lockUncancelable(srv.io);
        defer t.mutex.unlock(srv.io);
        _ = t.live.remove(id);
    }

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.live.deinit(gpa);
    }
};

/// Pushes the body's context into reply `id`: ``messages`` in its template's wrapper, or ``text`` exactly as given.
pub fn post(srv: *Server, conn: *Conn, a: Allocator, id: []const u8) void {
    var cx: Cx = .{ .a = a };
    var code: u16 = 400;
    const n = readAndPush(srv, &cx, conn, id, &code) catch |e| {
        if (e == error.OutOfMemory) cx.message = "out of memory";
        return fail(conn, a, if (cx.kind == .server) 500 else code, cx.message);
    };
    const o = json.newObject(a) catch return;
    o.put(a, "id", .{ .string = id }) catch return;
    o.put(a, "object", .{ .string = "chat.completion.inject" }) catch return;
    o.put(a, "injected_tokens", json.intValue(a, n) catch return) catch return;
    routes.sendValue(conn, a, 200, .{ .object = o });
}

fn readAndPush(srv: *Server, cx: *Cx, conn: *Conn, id: []const u8, code: *u16) errors.Refused!usize {
    return push(srv, cx, id, try http_body.readJson(conn, cx), code);
}

/// The route's body pushed into reply `id`: the tokens it queued, or a refusal with its HTTP status in `code`.
pub fn push(srv: *Server, cx: *Cx, id: []const u8, body: Value, code: *u16) errors.Refused!usize {
    if (body != .object) return cx.refuse("the body must be a JSON object");
    const thinking = blk: {
        srv.injects.mutex.lockUncancelable(srv.io);
        defer srv.injects.mutex.unlock(srv.io);
        const l = srv.injects.live.get(id) orelse return missing(cx, id, code);
        break :blk !l.answering.load(.acquire);
    };
    const ids = if (body.get("text")) |t| text: {
        if (t != .string or t.string.len == 0) return cx.refuse("text must be a nonempty string");
        break :text srv.text.encode(cx.a, t.string, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Template => return cx.refuse("the tokenizer cannot encode this text"),
        };
    } else try prompt.injectIds(srv, cx, body.get("messages") orelse .null, thinking);
    srv.injects.mutex.lockUncancelable(srv.io);
    defer srv.injects.mutex.unlock(srv.io);
    const l = srv.injects.live.get(id) orelse return missing(cx, id, code);
    l.inject.push(ids) catch |e| switch (e) {
        error.Ended => return missing(cx, id, code),
        error.NoRoom => {
            code.* = 409;
            return cx.fail(.request, "{s} has room for {d} more injected tokens, not {d}: raise its inject_room", .{ id, l.inject.room - l.inject.pushed, ids.len });
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return ids.len;
}

fn missing(cx: *Cx, id: []const u8, code: *u16) errors.Refused {
    code.* = 404;
    return cx.fail(.request, "no running reply {s} takes injected context (it ended, or asked for no inject_room)", .{id});
}

fn fail(conn: *Conn, a: Allocator, code: u16, message: []const u8) void {
    const o = json.newObject(a) catch return;
    o.put(a, "message", .{ .string = message }) catch return;
    o.put(a, "type", .{ .string = "invalid_request_error" }) catch return;
    const wrapped = json.newObject(a) catch return;
    wrapped.put(a, "error", .{ .object = o }) catch return;
    routes.sendValue(conn, a, code, .{ .object = wrapped });
}

test "the inject route names its reply, and no other path" {
    try std.testing.expectEqualStrings("chatcmpl-ab12", route("/v1/chat/completions/chatcmpl-ab12/inject").?);
    try std.testing.expect(route("/v1/chat/completions") == null);
    try std.testing.expect(route("/v1/chat/completions/inject") == null);
    try std.testing.expect(route("/v1/chat/completions/a/b/inject") == null);
    try std.testing.expect(route("/v1/completions/cmpl-1/inject") == null);
}
