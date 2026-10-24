//! Promotion's HTTP fixture uses the current Storage, index and stable-ID journal implementation.
const std = @import("std");
const server = @import("root.zig");
const Storage = @import("notes/storage.zig").Storage;
const index = @import("notes/index.zig");
const Bytes = @import("notes_storage_bytes_test.zig").Bytes;
const live = @import("notes_lookup_rig_test.zig");
const t = std.testing;
pub const snapshot = @embedFile("notes/testdata/l6_bytes_snapshot.json");
pub const writes_json = @embedFile("notes/testdata/l6_bytes_writes.json");
pub const cases_json = @embedFile("notes/testdata/l6_bytes_cases.json");
pub const Echo = @import("notes_storage_http_test.zig").Echo;
pub const Kind = live.Kind;
pub const kinds = live.kinds;
pub const Reply = live.Reply;

pub const Rig = struct {
    tmp: t.TmpDir,
    snap: []u8,
    text: Bytes = .{},
    engine: Echo = .{},
    srv: *server.Server,
    gpa: std.mem.Allocator,
    kind: index.Kind,

    pub fn init(gpa: std.mem.Allocator) !*Rig {
        return initWith(gpa, .{});
    }
    pub fn initWith(gpa: std.mem.Allocator, k: Kind) !*Rig {
        const r = try t.allocator.create(Rig);
        errdefer t.allocator.destroy(r);
        r.* = .{ .tmp = t.tmpDir(.{}), .snap = undefined, .srv = undefined, .gpa = gpa, .kind = k.kind };
        errdefer r.tmp.cleanup();
        try r.tmp.dir.writeFile(t.io, .{ .sub_path = "snap.json", .data = snapshot });
        r.snap = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/snap.json", .{r.tmp.sub_path});
        errdefer t.allocator.free(r.snap);
        r.srv = try server.Server.init(t.allocator, t.io, r.engine.engine(), r.text.text(), .{
            .served_name = "m",
            .model_ids = &.{"m"},
            .enable_thinking = false,
            .use_drafts = false,
        }, null);
        errdefer r.srv.deinit();
        try r.open();
        return r;
    }
    fn open(r: *Rig) !void {
        var why: []const u8 = "";
        r.srv.notes = try Storage.openKind(r.gpa, t.io, r.snap, r.text.text(), "", r.kind, &why);
        try r.srv.notes.?.beginRun(t.allocator, .{});
    }
    pub fn restart(r: *Rig) !void {
        if (r.srv.notes) |s| s.deinit();
        r.srv.notes = null;
        try r.open();
    }
    pub fn store(r: *Rig) *Storage {
        return r.srv.notes.?;
    }
    pub fn deinit(r: *Rig) void {
        r.srv.deinit();
        t.allocator.free(r.snap);
        r.tmp.cleanup();
        t.allocator.destroy(r);
    }
};

pub fn request(srv: *server.Server, a: std.mem.Allocator, method: []const u8, path: []const u8, body: ?[]const u8) !Reply {
    return live.request(srv, a, method, path, body orelse "");
}
