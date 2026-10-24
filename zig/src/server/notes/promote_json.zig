//! Promotion state JSON and diagnostic probe records.
const std = @import("std");
const libc = @import("sys").c;
const json = @import("json");
const promote = @import("promote.zig");
const journal = @import("journal.zig");
const tmp = @import("journal_tmp.zig");
const Value = json.Value;
const Allocator = std.mem.Allocator;
const State = promote.State;
const Neuron = promote.Neuron;

pub const format = "tf-notes-promote/1";

fn int(a: Allocator, n: anytype) !Value {
    return json.intValue(a, n);
}

fn neurons(a: Allocator, ns: []const Neuron) !Value {
    const out = try a.alloc(Value, ns.len);
    for (ns, out) |n, *v| {
        const t = try a.alloc(Value, 3);
        t[0] = try int(a, n.layer);
        t[1] = try int(a, n.neuron);
        t[2] = .{ .string = @tagName(n.key) };
        v.* = .{ .array = t };
    }
    return .{ .array = out };
}

/// The state as a JSON value (the report and the file).
pub fn value(s: *const State, a: Allocator) !Value {
    const o = try json.newObject(a);
    try o.put(a, "format", .{ .string = format });
    try o.put(a, "hold", try int(a, s.settings.hold));
    try o.put(a, "alone", try int(a, s.settings.alone));
    try o.put(a, "tolerance", try int(a, s.settings.tolerance));
    try o.put(a, "nights_done", try int(a, s.nights_done));
    try o.put(a, "rebuild_next", .{ .bool = s.rebuild_next });
    if (s.open) |op| {
        const x = try json.newObject(a);
        try x.put(a, "night", try int(a, op.night));
        try x.put(a, "teaching", .{ .string = op.teaching });
        try x.put(a, "placed", try neurons(a, op.placed));
        try o.put(a, "open", .{ .object = x });
    } else try o.put(a, "open", .null);
    try o.put(a, "pocket", try neurons(a, s.pocket));
    const facts = try a.alloc(Value, s.facts.items.len);
    for (s.facts.items, facts) |f, *v| {
        const x = try json.newObject(a);
        try x.put(a, "key", .{ .string = f.key });
        try x.put(a, "text", .{ .string = f.text });
        try x.put(a, "erased", .{ .bool = f.erased });
        try x.put(a, "pair_reset_by", .{ .string = f.pair_reset_by });
        try x.put(a, "told", try int(a, f.told));
        try x.put(a, "status", .{ .string = @tagName(f.status) });
        try x.put(a, "since", try int(a, f.since));
        try x.put(a, "retrieved", .{ .bool = f.retrieved });
        try x.put(a, "alone", try int(a, f.alone));
        try x.put(a, "night", try int(a, f.night));
        try x.put(a, "neurons", try neurons(a, f.neurons));
        const ps = try a.alloc(Value, f.probes.len);
        for (f.probes, ps) |p, *pv| {
            const y = try json.newObject(a);
            try y.put(a, "q", .{ .string = p.q });
            try y.put(a, "ref", .{ .string = p.ref });
            pv.* = .{ .object = y };
        }
        try x.put(a, "probes", .{ .array = ps });
        try x.put(a, "why", .{ .string = f.why });
        try x.put(a, "retries", try int(a, f.retries));
        if (f.ask) |p| {
            const y = try json.newObject(a);
            try y.put(a, "q", .{ .string = p.q });
            try y.put(a, "ref", .{ .string = p.ref });
            try x.put(a, "ask", .{ .object = y });
        } else try x.put(a, "ask", .null);
        const nb = try a.alloc(Value, f.neighbours.len);
        for (f.neighbours, nb) |q, *slot| slot.* = .{ .string = q };
        try x.put(a, "neighbours", .{ .array = nb });
        if (f.pair) |p| {
            const y = try json.newObject(a);
            try y.put(a, "q", .{ .string = p.q });
            try y.put(a, "ref", .{ .string = p.ref });
            try y.put(a, "text", .{ .string = p.text });
            const keys = try a.alloc(Value, p.keys.len);
            for (p.keys, keys) |key, *slot| slot.* = .{ .string = key };
            try y.put(a, "keys", .{ .array = keys });
            try x.put(a, "pair", .{ .object = y });
        } else try x.put(a, "pair", .null);
        v.* = .{ .object = x };
    }
    try o.put(a, "facts", .{ .array = facts });
    const nights = try a.alloc(Value, s.nights.items.len);
    for (s.nights.items, nights) |n, *v| {
        const x = try json.newObject(a);
        const info = @typeInfo(promote.NightLog).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            const fv = @field(n, name);
            try x.put(a, name, switch (T) {
                []const u8 => .{ .string = fv },
                f64 => .{ .float = fv },
                else => try int(a, fv),
            });
        }
        v.* = .{ .object = x };
    }
    try o.put(a, "nights", .{ .array = nights });
    return .{ .object = o };
}

pub fn encode(s: *const State, a: Allocator) ![]u8 {
    return json.stringify(a, try value(s, a), .{});
}

pub const LoadError = error{ OutOfMemory, BadState };

fn uint(comptime T: type, v: ?Value) LoadError!T {
    const x = v orelse return error.BadState;
    return std.math.cast(T, x.int64() orelse return error.BadState) orelse error.BadState;
}

fn str(sa: Allocator, v: ?Value) LoadError![]const u8 {
    const x = v orelse return error.BadState;
    return sa.dupe(u8, x.str() orelse return error.BadState);
}

fn readNeurons(sa: Allocator, v: ?Value) LoadError![]const Neuron {
    const xs = (v orelse return error.BadState).items() orelse return error.BadState;
    const out = try sa.alloc(Neuron, xs.len);
    for (xs, out) |x, *n| {
        const t = x.items() orelse return error.BadState;
        if (t.len != 3) return error.BadState;
        n.* = .{ .layer = try uint(u16, t[0]), .neuron = try uint(u16, t[1]), .key = std.meta.stringToEnum(promote.NeuronKey, t[2].str() orelse "") orelse return error.BadState };
    }
    return out;
}

/// The state a file holds; one that stopped mid-night comes back marked to rebuild, its placed neurons in the pocket.
pub fn decode(gpa: Allocator, bytes: []const u8, settings: promote.Settings) LoadError!State {
    var s = State.init(gpa, settings);
    errdefer s.deinit();
    const sa = s.alloc();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const v = switch (try json.parse(scratch.allocator(), bytes)) {
        .ok => |x| x,
        .err => return error.BadState,
    };
    if (!std.mem.eql(u8, v.strField("format") orelse "", format)) return error.BadState;
    s.nights_done = try uint(u32, v.field("nights_done"));
    s.rebuild_next = if (v.field("rebuild_next")) |b| b == .bool and b.bool else false;
    s.pocket = try readNeurons(sa, v.field("pocket"));
    if (v.field("open")) |op| s.open = .{ .night = try uint(u32, op.field("night")), .teaching = try str(sa, op.field("teaching")), .placed = try readNeurons(sa, op.field("placed")) };
    for ((v.field("facts") orelse return error.BadState).items() orelse return error.BadState) |x| {
        var f: promote.Fact = .{ .key = try str(sa, x.field("key")), .text = try str(sa, x.field("text")) };
        f.erased = if (x.field("erased")) |b| b == .bool and b.bool else false;
        if (x.field("pair_reset_by")) |key| f.pair_reset_by = try str(sa, key);
        f.told = (x.field("told") orelse return error.BadState).int64() orelse return error.BadState;
        f.status = std.meta.stringToEnum(promote.Status, x.strField("status") orelse "") orelse return error.BadState;
        f.since = try uint(u32, x.field("since"));
        f.retrieved = if (x.field("retrieved")) |b| b == .bool and b.bool else false;
        f.alone = try uint(u32, x.field("alone"));
        f.night = try uint(u32, x.field("night"));
        f.neurons = try readNeurons(sa, x.field("neurons"));
        const ps = (x.field("probes") orelse return error.BadState).items() orelse return error.BadState;
        const probes = try sa.alloc(promote.Probe, ps.len);
        for (ps, probes) |p, *o| o.* = .{ .q = try str(sa, p.field("q")), .ref = try str(sa, p.field("ref")) };
        f.probes = probes;
        f.why = try str(sa, x.field("why"));
        if (x.field("retries")) |r| f.retries = try uint(u32, r); // absent in a file from before retries
        if (x.field("ask")) |p| f.ask = .{ .q = try str(sa, p.field("q")), .ref = try str(sa, p.field("ref")) };
        if (x.field("neighbours")) |nb| if (nb.items()) |xs| {
            const out = try sa.alloc([]const u8, xs.len);
            for (xs, out) |q, *o| o.* = try str(sa, q);
            f.neighbours = out;
        };
        if (x.field("pair")) |p| {
            var pair: promote.Pair = .{ .q = try str(sa, p.field("q")), .ref = try str(sa, p.field("ref")), .text = try str(sa, p.field("text")) };
            if (p.field("keys")) |ks| {
                const xs = ks.items() orelse return error.BadState;
                const keys = try sa.alloc([]const u8, xs.len);
                for (xs, keys) |key, *slot| slot.* = try str(sa, key);
                pair.keys = keys;
            }
            f.pair = pair;
        }
        try s.facts.append(sa, f);
    }
    for ((v.field("nights") orelse return error.BadState).items() orelse return error.BadState) |x| {
        var n: promote.NightLog = .{};
        const info = @typeInfo(promote.NightLog).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            // a field a file from an earlier build lacks keeps its default
            if (x.field(name) != null) @field(n, name) = switch (T) {
                []const u8 => try str(sa, x.field(name)),
                f64 => (x.field(name) orelse return error.BadState).float64() orelse return error.BadState,
                i64 => (x.field(name) orelse return error.BadState).int64() orelse return error.BadState,
                else => try uint(T, x.field(name)),
            };
        }
        try s.nights.append(sa, n);
    }
    if (s.open) |op| {
        s.rebuild_next = true; // the weights may hold neurons this state never kept: zero them all and teach again
        var all: std.ArrayList(Neuron) = .empty;
        try all.appendSlice(sa, s.pocket);
        for (op.placed) |n| if (!promote.has(all.items, n)) try all.append(sa, n);
        s.pocket = all.items;
    }
    return s;
}

pub const WriteError = error{ OutOfMemory, PromoteIo };

/// Tests only: the next state's publication fails at this stage, then returns to normal.
pub const WriteFault = enum { none, write, file_sync, rename, folder_sync };
pub var write_fault: WriteFault = .none;

/// Sync the temporary file, replace the state atomically, and report file or folder sync failure.
pub fn writeFile(a: Allocator, path: []const u8, bytes: []const u8) WriteError!void {
    const fault = if (@import("builtin").is_test) write_fault else .none;
    if (@import("builtin").is_test) write_fault = .none;
    const target = try a.dupeSentinel(u8, path, 0);
    defer a.free(target);
    const dir = try a.dupeSentinel(u8, std.fs.path.dirname(path) orelse ".", 0);
    defer a.free(dir);
    const t = tmp.create(a, path) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.PromoteIo;
    defer a.free(t.path);
    defer tmp.removeOwn(t);
    var off: usize = 0;
    while (off < bytes.len) {
        const count = if (fault == .write) @max(@as(usize, 1), (bytes.len - off) / 2) else bytes.len - off;
        const n = libc.write(t.fd, bytes[off..].ptr, count);
        if (n <= 0 or fault == .write) return error.PromoteIo;
        off += @intCast(n);
    }
    if (fault == .file_sync or !journal.fullSync(t.fd, null)) return error.PromoteIo;
    if (fault == .rename or libc.rename(t.path, target) != 0) return error.PromoteIo;
    const dfd = libc.open(dir, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(libc.mode_t, 0));
    if (dfd < 0) return error.PromoteIo;
    defer _ = libc.close(dfd);
    if (fault == .folder_sync or !journal.fullSync(dfd, null)) return error.PromoteIo;
}

pub const probe_format = "tf-notes-probe-hashes/1";

/// Append a probe's hashes and opaque ids; older plaintext lines in this file still require erase disclosure.
pub fn appendProbe(a: Allocator, state_path: []const u8, r: promote.Record) void {
    const line = probeLine(a, r) catch return;
    defer a.free(line);
    const path = std.fmt.allocPrintSentinel(a, "{s}-probes.jsonl", .{state_path}, 0) catch return;
    defer a.free(path);
    const fd = libc.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(libc.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = libc.close(fd);
    var off: usize = 0;
    while (off < line.len) {
        const n = libc.write(fd, line[off..].ptr, line.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
    _ = libc.write(fd, "\n", 1);
}

pub fn hashText(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn putHash(o: *json.Object, a: Allocator, comptime name: []const u8, text: []const u8) !void {
    const hash = hashText(text);
    try o.put(a, name ++ "_sha256", .{ .string = try a.dupe(u8, &hash) });
}

/// A disk probe record keeps verdicts and hashes; its question, references and replies remain only in the live judge.
pub fn probeLine(a: Allocator, r: promote.Record) ![]u8 {
    const o = try json.newObject(a);
    try o.put(a, "format", .{ .string = probe_format });
    try o.put(a, "night", try int(a, r.night));
    try o.put(a, "kind", .{ .string = r.kind });
    if (r.key.len > 0) try o.put(a, "key", .{ .string = r.key });
    try putHash(o, a, "q", r.q);
    if (r.exclude) |ids| {
        const xs = try a.alloc(Value, ids.len);
        for (ids, xs) |id, *x| x.* = try int(a, id);
        try o.put(a, "exclude", .{ .array = xs });
    }
    if (r.round > 0) try o.put(a, "round", try int(a, r.round));
    inline for (.{ "before", "after", "reply" }) |field| if (@field(r, field)) |text| try putHash(o, a, field, text);
    if (r.ref.len > 0) try putHash(o, a, "ref", r.ref);
    try o.put(a, "ok", .{ .bool = r.ok });
    if (r.why.len > 0) try putHash(o, a, "why", r.why);
    if (r.thinking) try o.put(a, "thinking", .{ .bool = true });
    return json.stringify(a, .{ .object = o }, .{});
}
