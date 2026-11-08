//! #1594 step 2b: asks the GB10's server to prefill a prompt under a handoff id, as MCDMA's decoders ask vLLM.
const std = @import("std");
const fabric = @import("tensorfold").fabric;

/// A completion request of one token with `kv_transfer_params.mcdma_handoff`, to `url` (…/v1/completions), over HTTP.
pub const Http = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    model: []const u8,
    closing: ?*const std.atomic.Value(bool) = null, // the server stops: an exchange under way is cut off

    pub fn trigger(h: *Http) fabric.prefill_source.Trigger {
        return .{ .ptr = h, .start_fn = start };
    }

    /// The exchange, bounded by `deadline` (the GB10 prefills the tokens first), or until closing.
    fn start(ptr: *anyopaque, handoff: [16]u8, tokens: []const u32) anyerror!void {
        const h: *Http = @ptrCast(@alignCast(ptr));
        const body = try request(h.gpa, h.model, handoff, tokens);
        defer h.gpa.free(body);
        var x: Exchange = .{ .h = h, .body = body };
        const deadline = fabric.words.nowNs() + seconds(tokens.len) * std.time.ns_per_s;
        var future = h.io.concurrent(Exchange.run, .{&x}) catch return error.TriggerUnavailable;
        while (!x.done.load(.acquire)) {
            const closing = if (h.closing) |c| c.load(.acquire) else false;
            if (closing or fabric.words.nowNs() >= deadline) {
                future.cancel(h.io);
                return if (closing) error.TriggerClosed else error.TriggerTimedOut;
            }
            h.io.sleep(.fromMilliseconds(1), .awake) catch {
                future.cancel(h.io);
                return error.TriggerTimedOut;
            };
        }
        future.await(h.io);
        return x.result;
    }
};

/// TF_PREFILL_TIMEOUT_S, else 60 s and a second per 400 tokens: a GB10 prefilling at 1,000 tok/s at 64k, slower beyond.
fn seconds(tokens: usize) u64 {
    if (std.c.getenv("TF_PREFILL_TIMEOUT_S")) |v| return std.fmt.parseInt(u64, std.mem.span(v), 10) catch 60 + tokens / 400;
    return 60 + tokens / 400;
}

/// One HTTP exchange on its own task, so `start` can give up on it.
const Exchange = struct {
    h: *Http,
    body: []u8,
    done: std.atomic.Value(bool) = .init(false),
    result: anyerror!void = {},

    fn run(x: *Exchange) void {
        defer x.done.store(true, .release);
        x.result = x.exchange();
    }

    fn exchange(x: *Exchange) !void {
        const h = x.h;
        var client: std.http.Client = .{ .allocator = h.gpa, .io = h.io };
        defer client.deinit();
        const uri = try std.Uri.parse(h.url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.TriggerNotHttp; // a LAN peer, no TLS
        var req = try client.request(.POST, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .accept_encoding = .{ .override = "identity" }, .content_type = .{ .override = "application/json" } },
        });
        defer req.deinit();
        try req.sendBodyComplete(x.body);
        var resp = try req.receiveHead(&.{});
        if (resp.head.status.class() != .success) {
            std.log.warn("remote prefill: the GB10 answered HTTP {d}", .{@backingInt(resp.head.status)});
            return error.TriggerRefused;
        }
        var transfer: [16 << 10]u8 = undefined;
        const r = resp.reader(&transfer);
        const reply = try r.allocRemaining(h.gpa, .limited(1 << 20));
        h.gpa.free(reply);
    }
};

/// The request's JSON: the prefix's ids, one greedy token and the handoff MCDMA reads (no model field: the default).
pub fn request(gpa: std.mem.Allocator, model: []const u8, handoff: [16]u8, tokens: []const u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    if (model.len > 0) try w.print("{{\"model\": {f}, \"prompt\": [", .{std.json.fmt(model, .{})}) else try w.writeAll("{\"prompt\": [");
    for (tokens, 0..) |t, i| try w.print("{s}{d}", .{ if (i == 0) "" else ", ", t });
    try w.print("], \"max_tokens\": 1, \"temperature\": 0, \"kv_transfer_params\": {{\"mcdma_handoff\": {{\"id\": \"{x}\", \"export_from\": 0}}}}}}", .{&handoff});
    return out.toOwnedSlice();
}

test "the trigger's request names the prefix's ids, one token, and the handoff as 32 hex digits" {
    const gpa = std.testing.allocator;
    var id: [16]u8 = undefined;
    for (&id, 0..) |*b, i| b.* = @intCast(i * 17);
    const got = try request(gpa, "Qwen3.8-27B", id, &.{ 5, 6, 7 });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{\"model\": \"Qwen3.8-27B\", \"prompt\": [5, 6, 7], \"max_tokens\": 1, \"temperature\": 0, \"kv_transfer_params\": {\"mcdma_handoff\": {\"id\": \"00112233445566778899aabbccddeeff\", \"export_from\": 0}}}", got);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, got, .{});
    defer parsed.deinit();
    const bare = try request(gpa, "", id, &.{9});
    defer gpa.free(bare);
    try std.testing.expect(std.mem.startsWith(u8, bare, "{\"prompt\": [9], "));
}
