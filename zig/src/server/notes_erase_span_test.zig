//! The erase's search span on a real model tokenizer (NVIDIA Nemotron 3.5 Lightning's tokenizer.json): it must lie
//! inside the tokens of a real chat prompt whose notes block holds the note, with any id and any label, while the
//! raw text's tokens (the first fix's search) do not for an escaped note. Skipped when the tokenizer is not on disk:
//! TF_NOTES_TOKENIZER_DIR names its folder, else the Hugging Face cache path on petrus's Macs is tried.
const std = @import("std");
const server = @import("root.zig");
const json = server.json;
const hf_text = @import("hf_text.zig");
const line = @import("notes/line.zig");
const places = @import("notes_erase_places.zig");
const cases = @import("notes_erase_cache_test.zig").cases;
const testing = std.testing;

const default_dir = "/Users/petrus/.cache/huggingface/hub/models--TensorFold--NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit/snapshots/d9d758fb83953437f7263256b0d96157e2a348b8";

/// The ids of a chat whose system message is a notes block with `lines`, rendered by the model's own template.
fn prompt(a: std.mem.Allocator, t: @import("model_text.zig").Text, lines: []const []const u8) ![]u32 {
    var block: std.ArrayList(u8) = .empty;
    try block.appendSlice(a, "What you know about the user, from earlier conversations.\nCurrent notes:");
    for (lines) |l| try block.print(a, "\n{s}", .{l});
    const messages = try std.fmt.allocPrint(a, "[{{\"role\": \"system\", \"content\": {s}}}, {{\"role\": \"user\", \"content\": \"What is my favourite colour?\"}}]", .{try json.quote(a, block.items, .{})});
    var problem: []const u8 = "";
    return t.renderIds(a, (try json.parseText(a, messages)).ok, .{}, &problem);
}

test "on Nemotron 3.5 Lightning's tokenizer the span of each note is inside every prompt that carried it, and the raw text's is not" {
    const dir = std.c.getenv("TF_NOTES_TOKENIZER_DIR") orelse default_dir;
    var probe: [1100]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&probe, "{s}/tokenizer.json", .{std.mem.sliceTo(dir, 0)}, 0);
    if (std.c.access(file, std.c.F_OK) != 0) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: []const u8 = "";
    const ht = try hf_text.HfText.load(testing.allocator, testing.io, std.mem.sliceTo(dir, 0), null, a, &problem);
    defer ht.deinit();
    const t = ht.text();
    const told = line.ordinalOf(2026, 10, 16) * line.tpd;
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        const span = (try places.spanOf(a, t, case.raw)) orelse return error.TestNoSpan;
        // the note as cached: current under one id, later superseded, later renumbered, between other lines
        const as_cached = try line.render(a, 31, case.raw, .none, .plain);
        const superseded = try line.render(a, 31, case.raw, .{ .superseded = .{ .by = 32, .told = told } }, .plain);
        const renumbered = try line.render(a, 30, case.raw, .none, .plain);
        const other = "[5] \"My dog has grey eyes.\"";
        const wraps = [_][]const []const u8{ &.{as_cached}, &.{ other, as_cached }, &.{ as_cached, other }, &.{ other, superseded, other }, &.{renumbered} };
        for (wraps) |w| {
            const ids = try prompt(a, t, w);
            try testing.expect(std.mem.indexOf(u32, ids, span) != null);
        }
        // the first fix's search: the raw text's tokens without the first and last; an escaped note's are not there
        const raw = try t.encode(a, case.raw, false);
        const old = raw[1 .. raw.len - 1];
        if (!std.mem.eql(u8, case.raw, case.rendered[1 .. case.rendered.len - 1]))
            try testing.expect(std.mem.indexOf(u32, try prompt(a, t, &.{as_cached}), old) == null);
    }
    // a note of two words gives no span: the erase cannot show its prompts gone
    try testing.expect((try places.spanOf(a, t, "Zanzibar, quixotically.")) == null);
}
