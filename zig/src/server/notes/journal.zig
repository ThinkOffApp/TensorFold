//! The notes' journal next to the snapshot: each write one JSON line, on disk before its reply, replayed at startup.
const std = @import("std");
const builtin = @import("builtin");
const json = @import("../json.zig");
const write = @import("write.zig");
const tmp_file = @import("journal_tmp.zig");
const Record = write.Record;
const Value = json.Value;
const Allocator = std.mem.Allocator;

pub const format = "tf-notes-journal/1";

pub const OpenError = error{ OutOfMemory, JournalIo, BadJournal, OtherSnapshot, Locked };
pub const IoError = error{ OutOfMemory, JournalIo };
/// JournalPoisoned: an append failed and so did putting the file back; it may hold part of a record until a restart.
pub const AppendError = IoError || error{JournalPoisoned};

/// Tests only: an append's Nth write, truncate or sync fails (from 0); a failing write puts down half its bytes.
pub const Faults = struct {
    write: ?u32 = null,
    truncate: ?u32 = null,
    sync: ?u32 = null,
    writes: u32 = 0,
    truncates: u32 = 0,
    syncs: u32 = 0,

    fn hit(at: ?u32, count: *u32) bool {
        const n = count.*;
        count.* += 1;
        return at != null and at.? == n;
    }
};

/// One snapshot's journal: its path, the open file (after the first write or a replay), and its size.
pub const Journal = struct {
    gpa: Allocator,
    path: [:0]u8,
    snapshot_sha: [64]u8,
    fd: c_int = -1,
    size: u64 = 0,
    truncated: u64 = 0, // bytes of a torn last line cut at open
    next_source: u64 = 1, // the header's: an erase rewrites it, so an erased write's source is never used again
    stale: usize = 0, // temporary files of a rewrite that died before its rename, removed at open (lock held)
    hook: ?*const fn (ctx: *anyopaque, tmp: [:0]const u8) void = null, // tests: between a rewrite's sync and rename
    faults: ?*Faults = null, // tests: an append's write, truncate or sync made to fail
    poisoned: bool = false, // an append and its rollback both failed: no more appends until a restart cuts the tail
    hook_ctx: *anyopaque = undefined,

    pub fn deinit(j: *Journal) void {
        if (j.fd >= 0) _ = std.c.close(j.fd);
        j.gpa.free(j.path);
    }

    /// The journal at `path`, read when it exists: its records (strings owned by `a`), checked against the snapshot.
    pub fn open(gpa: Allocator, a: Allocator, path: []const u8, snapshot_sha: [64]u8, records: *std.ArrayList(Record), problem: *[]const u8) OpenError!Journal {
        var j: Journal = .{ .gpa = gpa, .path = try gpa.dupeSentinel(u8, path, 0), .snapshot_sha = snapshot_sha };
        errdefer j.deinit();
        const fd = std.c.open(j.path, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) {
            if (std.c.errno(fd) == .NOENT) return j; // no write yet: the file comes with the first one
            problem.* = "the notes journal exists but cannot be opened for reading and writing";
            return error.JournalIo;
        }
        j.fd = fd;
        if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
            problem.* = "another process holds the notes journal: one server per snapshot";
            return error.Locked;
        }
        // ours now: a temporary file left by a rewrite that never reached its rename is stale (the journal holds all)
        j.stale = try tmp_file.cleanStale(a, path);
        const text = try readAll(a, fd, problem); // in `a`: the records' strings are slices of it
        var end = text.len;
        if (end > 0 and text[end - 1] != '\n') {
            // a write cut short by a crash: it never had a reply, so it goes
            end = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| nl + 1 else 0;
            j.truncated = text.len - end;
            if (std.c.ftruncate(fd, @intCast(end)) != 0 or !fullSync(fd)) {
                problem.* = "the notes journal ends in a torn line that cannot be cut";
                return error.JournalIo;
            }
        }
        j.size = end;
        var lines = std.mem.splitScalar(u8, text[0..end], '\n');
        const first = lines.next() orelse "";
        if (end == 0) {
            problem.* = "the notes journal is empty (no header)";
            return error.BadJournal;
        }
        j.next_source = try checkHeader(a, first, snapshot_sha, problem);
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const v = switch (try json.parse(a, line)) {
                .ok => |x| x,
                .err => {
                    problem.* = "a line of the notes journal is not JSON";
                    return error.BadJournal;
                },
            };
            try records.append(a, decode(v) orelse {
                problem.* = "a line of the notes journal is not a write";
                return error.BadJournal;
            });
        }
        return j;
    }

    /// Appends one record and syncs it to the drive; on any failure the file is cut back to what it was.
    pub fn append(j: *Journal, a: Allocator, r: Record) AppendError!void {
        if (j.poisoned) return error.JournalPoisoned;
        if (j.fd < 0) try j.create(a);
        const line = try encode(a, r);
        defer a.free(line);
        if (j.put(line, j.size) and j.sync()) {
            j.size += line.len;
            return;
        }
        // not whole: cut back to the last record and sync; failing that the file may hold part of it (startup cuts it)
        if (!j.cut(j.size) or !j.sync()) {
            j.poisoned = true;
            return error.JournalPoisoned;
        }
        return error.JournalIo;
    }

    fn put(j: *Journal, data: []const u8, at: u64) bool {
        if (j.faults) |f| if (Faults.hit(f.write, &f.writes)) {
            _ = writeAll(j.fd, data[0 .. data.len / 2], at);
            return false;
        };
        return writeAll(j.fd, data, at);
    }

    fn cut(j: *Journal, len: u64) bool {
        if (j.faults) |f| if (Faults.hit(f.truncate, &f.truncates)) return false;
        return std.c.ftruncate(j.fd, @intCast(len)) == 0;
    }

    fn sync(j: *Journal) bool {
        if (j.faults) |f| if (Faults.hit(f.sync, &f.syncs)) return false;
        return fullSync(j.fd);
    }

    /// The journal as `records` alone (an erase): written whole to a new file of our own, synced, renamed over it.
    pub fn rewrite(j: *Journal, a: Allocator, records: []const Record, next_source: u64) IoError!void {
        const t = try tmp_file.create(a, j.path);
        defer a.free(t.path);
        var ok = false;
        defer if (!ok) tmp_file.removeOwn(t);
        const fd = t.fd;
        const head = try header(a, j.snapshot_sha, next_source);
        defer a.free(head);
        var size: u64 = 0;
        if (!writeAll(fd, head, size)) return error.JournalIo;
        size += head.len;
        for (records) |r| {
            const line = try encode(a, r);
            defer a.free(line);
            if (!writeAll(fd, line, size)) return error.JournalIo;
            size += line.len;
        }
        if (!fullSync(fd)) return error.JournalIo;
        if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return error.JournalIo;
        if (j.hook) |h| h(j.hook_ctx, t.path);
        if (std.c.rename(t.path, j.path) != 0) return error.JournalIo;
        ok = true;
        syncDir(j.path);
        if (j.fd >= 0) _ = std.c.close(j.fd);
        j.fd = fd;
        j.size = size;
        j.next_source = next_source;
    }

    /// The file with its header, made at the first write.
    fn create(j: *Journal, a: Allocator) IoError!void {
        const fd = std.c.open(j.path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.JournalIo;
        if (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) {
            _ = std.c.close(fd);
            return error.JournalIo;
        }
        const head = try header(a, j.snapshot_sha, j.next_source);
        defer a.free(head);
        if (!writeAll(fd, head, 0) or !fullSync(fd)) {
            _ = std.c.close(fd);
            _ = std.c.unlink(j.path);
            return error.JournalIo;
        }
        syncDir(j.path);
        j.fd = fd;
        j.size = head.len;
    }
};

fn header(a: Allocator, sha: [64]u8, next_source: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "{{\"format\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"next_source\":{d}}}\n", .{ format, &sha, next_source });
}

/// The header checked against the snapshot; its next_source.
fn checkHeader(a: Allocator, line: []const u8, sha: [64]u8, problem: *[]const u8) OpenError!u64 {
    const v = switch (try json.parse(a, line)) {
        .ok => |x| x,
        .err => {
            problem.* = "the notes journal's first line is not its header";
            return error.BadJournal;
        },
    };
    if (!std.mem.eql(u8, v.strField("format") orelse "", format)) {
        problem.* = "the notes journal's header names another format";
        return error.BadJournal;
    }
    if (!std.mem.eql(u8, v.strField("snapshot_sha256") orelse "", &sha)) {
        problem.* = "the notes journal was written over another snapshot (its snapshot_sha256 differs)";
        return error.OtherSnapshot;
    }
    const next = (v.get("next_source") orelse return 1).int64() orelse return 1;
    return @intCast(@max(next, 1));
}

/// A record as one journal line: fixed keys, the text as UTF-8 (not escaped), a newline.
pub fn encode(a: Allocator, r: Record) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "{{\"op\":\"{s}\",\"source\":", .{@tagName(r.op)});
    try str(a, &out, r.source);
    try out.print(a, ",\"told\":{d},\"subject\":", .{r.told});
    try str(a, &out, r.subject);
    try out.appendSlice(a, ",\"attribute\":");
    try str(a, &out, r.attribute);
    switch (r.target) {
        .none => try out.appendSlice(a, ",\"target\":null"),
        .note => |n| try out.print(a, ",\"target\":{{\"note\":{d}}}", .{n}),
        .source => |s| {
            try out.appendSlice(a, ",\"target\":{\"source\":");
            try str(a, &out, s);
            try out.append(a, '}');
        },
    }
    try out.appendSlice(a, ",\"text\":");
    try str(a, &out, r.text);
    try out.appendSlice(a, "}\n");
    return out.toOwnedSlice(a);
}

fn str(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const q = try json.quote(a, s, .{ .ascii = false });
    defer a.free(q);
    try out.appendSlice(a, q);
}

/// A journal line read back, or null when it is not one encode() writes.
pub fn decode(v: Value) ?Record {
    const op = std.meta.stringToEnum(write.Op, v.strField("op") orelse return null) orelse return null;
    const told = (v.get("told") orelse return null).int64() orelse return null;
    var target: write.Target = .none;
    if (v.field("target")) |t| {
        if (t.field("note")) |n| {
            target = .{ .note = std.math.cast(u32, n.int64() orelse return null) orelse return null };
        } else target = .{ .source = t.strField("source") orelse return null };
    }
    if ((op == .add) != (target == .none)) return null;
    return .{ .op = op, .source = v.strField("source") orelse return null, .told = told, .subject = v.strField("subject") orelse return null, .attribute = v.strField("attribute") orelse return null, .target = target, .text = v.strField("text") orelse return null };
}

fn readAll(gpa: Allocator, fd: c_int, problem: *[]const u8) OpenError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [65536]u8 = undefined;
    var at: i64 = 0;
    while (true) {
        const n = std.c.pread(fd, &buf, buf.len, at);
        if (n < 0) {
            problem.* = "the notes journal cannot be read";
            return error.JournalIo;
        }
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
        at += n;
    }
    return out.toOwnedSlice(gpa);
}

fn writeAll(fd: c_int, data: []const u8, at: u64) bool {
    var done: usize = 0;
    while (done < data.len) {
        const n = std.c.pwrite(fd, data[done..].ptr, data.len - done, @intCast(at + done));
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}

/// The file's bytes on the drive itself: F_FULLFSYNC on Apple systems (plain fsync stops at the drive's cache).
pub fn fullSync(fd: c_int) bool {
    if (builtin.os.tag.isDarwin()) {
        if (std.c.fcntl(fd, std.c.F.FULLFSYNC) == 0) return true;
    }
    return std.c.fsync(fd) == 0;
}

/// The directory entry of a created or renamed file synced too.
fn syncDir(path: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const dir = std.fs.path.dirname(path) orelse ".";
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    const fd = std.c.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.fsync(fd);
}
