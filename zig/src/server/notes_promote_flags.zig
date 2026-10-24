//! Promotion's opt-in CLI controls, kept outside the common argument parser.
const std = @import("std");

pub const Options = struct {
    every_ms: ?i64 = null,
    hold: u32 = 1,
    alone: u32 = 2,
    regress: ?u32 = null,
    targeted: bool = true,
    thinking: bool = false,
};

pub fn duration(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    const unit: i64 = switch (text[text.len - 1]) {
        's' => 1000,
        'm' => 60_000,
        'h' => 3_600_000,
        '0'...'9' => 1000,
        else => return null,
    };
    const digits = if (std.ascii.isDigit(text[text.len - 1])) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(i64, digits, 10) catch return null;
    if (n < 1 or n > 366 * 24 * 3600) return null;
    return n * unit;
}

pub fn parse(o: *Options, name: []const u8, value: []const u8) error{BadValue}!bool {
    if (std.mem.eql(u8, name, "--notes-promote-every")) {
        o.every_ms = duration(value) orelse return error.BadValue;
    } else if (std.mem.eql(u8, name, "--notes-promote-hold")) {
        o.hold = try count(value, 1);
    } else if (std.mem.eql(u8, name, "--notes-promote-alone")) {
        o.alone = try count(value, 1);
    } else if (std.mem.eql(u8, name, "--notes-promote-regress")) {
        o.regress = if (std.mem.eql(u8, value, "all")) null else try count(value, 0);
    } else if (std.mem.eql(u8, name, "--notes-promote-targeted")) {
        o.targeted = std.mem.eql(u8, value, "on");
    } else if (std.mem.eql(u8, name, "--notes-promote-thinking")) {
        o.thinking = std.mem.eql(u8, value, "on");
    } else return false;
    return true;
}

fn count(value: []const u8, min: u32) error{BadValue}!u32 {
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, value, " "), 10) catch return error.BadValue;
    return if (n >= min) n else error.BadValue;
}

pub fn native(comptime Flag: type) [6]Flag {
    return .{
        .{ .name = "--notes-promote-every", .native = true },
        .{ .name = "--notes-promote-hold", .native = true },
        .{ .name = "--notes-promote-alone", .native = true },
        .{ .name = "--notes-promote-regress", .native = true },
        .{ .name = "--notes-promote-targeted", .choices = &.{ "on", "off" }, .native = true },
        .{ .name = "--notes-promote-thinking", .choices = &.{ "on", "off" }, .native = true },
    };
}

pub const usage = " [--notes-promote-every DURATION] [--notes-promote-hold N] [--notes-promote-alone N] [--notes-promote-regress {all,N}] [--notes-promote-targeted {on,off}] [--notes-promote-thinking {on,off}]";
pub const help =
    "  --notes-promote-every DURATION  opt in to periodic promotion with --notes and --slide; 600, 600s, 10m or 24h (off by default)\n" ++
    "  --notes-promote-hold N  nights a retrieved note stays unchanged before teaching, from 1 (default: 1)\n" ++
    "  --notes-promote-alone N  consecutive nights answering without its note before prompt exclusion, from 1 (default: 2)\n" ++
    "  --notes-promote-regress {all,N}  current notes checked for regression each night (default: all)\n" ++
    "  --notes-promote-targeted {on,off}  include neighbour, pair and untold probes (default: on)\n" ++
    "  --notes-promote-thinking {on,off}  also probe with thinking on (default: off)\n";
