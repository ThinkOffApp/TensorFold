//! #1594 step 2b, the producer's side: a handoff request's prompt state saved by its family for another machine.
const std = @import("std");
const lanes = @import("lanes");
const api = @import("engine_api.zig");
const pc = @import("prompt_cache.zig");
const LaneHost = @import("lane_host.zig").LaneHost;
const Job = @import("lane_job.zig").Job;
const Request = api.Request;

/// kv_transfer_params.mcdma_handoff on a completion request: its prompt state exported under `id` for another machine.
pub const Handoff = struct { id: [16]u8, export_from: u64 = 0 };

/// A producer's exports: the family saves a handoff stream's state at its mark, and the exporter records it.
pub const Exporter = struct {
    ptr: *anyopaque,
    snapshots: pc.Snapshots,
    /// `saved` (now the exporter's) is the state after `tokens`, the prompt but its last token; recorded under `h`.
    exported: *const fn (ptr: *anyopaque, h: Handoff, tokens: []const u32, saved: pc.Saved) void,
    /// No state will come for `h`: the decoder is told why.
    failed: *const fn (ptr: *anyopaque, h: Handoff, why: []const u8) void,
};

/// A handoff request needs an exporter, and a prompt with a token past its mark.
pub fn exportable(h: *const LaneHost, r: *const Request) bool {
    if (r.handoff == null) return true;
    return h.exporter != null and r.prompt.len >= 2 and r.images.len == 0 and !r.promptOnly();
}

/// A handoff stream cuts before the prompt's last token (its row stays pending) and exports there; its marks keep.
pub fn exporting(h: *const LaneHost, job: *Job, reuse: *lanes.stream.Reuse) bool {
    if (job.request.handoff == null or h.exporter == null) return false;
    job.cut = .{@intCast(job.request.prompt.len - 1)};
    if (reuse.at >= job.cut[0]) reuse.* = .{}; // a restore at the cut leaves no chunk ending there, so no export
    reuse.marks = handoffMarks(h, job, reuse.marks, reuse.at);
    reuse.hook = .{ .ptr = job, .at = exportAt };
    return true;
}

/// The store's marks past the restore and before the cut, and a planned store's last grid row there; then the cut.
fn handoffMarks(h: *const LaneHost, job: *Job, planned: []const u32, from: u32) []const u32 {
    const cut = job.cut[0];
    const grid: u32 = if (h.cache) |store| (if (store.rules.planned) store.rules.grid else 0) else 0;
    const row: u32 = if (grid > 0) cut - cut % grid else 0; // a chat's next turn resumes here (the cut is off the grid)
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(h.gpa);
    for (planned) |m| if (m > from and m < cut) list.append(h.gpa, m) catch return &job.cut;
    if (row > from and row < cut and std.mem.indexOfScalar(u32, list.items, row) == null) list.append(h.gpa, row) catch return &job.cut;
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    const marks = h.gpa.alloc(u32, list.items.len + 1) catch return &job.cut;
    @memcpy(marks[0..list.items.len], list.items);
    marks[list.items.len] = cut;
    h.gpa.free(job.marks);
    job.marks = marks;
    return marks;
}

fn exportAt(ptr: *anyopaque, s: *lanes.Stream, at: u32) void {
    const job: *Job = @ptrCast(@alignCast(ptr));
    if (at != job.cut[0]) return Job.kept(ptr, s, at); // one of the store's marks: kept as for any request
    const x = job.host.exporter orelse return;
    const h = job.request.handoff orelse return;
    if (job.exported) return;
    job.exported = true;
    const saved = x.snapshots.vtable.save(x.snapshots.ptr, s, at) catch |err| return x.failed(x.ptr, h, @errorName(err));
    x.exported(x.ptr, h, job.request.prompt[0..at], saved);
    if (job.host.cache) |store| if (store.usable(at, job.request.chunks)) Job.kept(ptr, s, at); // only a resumable cut
}

/// A handoff whose pass ended (or never ran) without its state: the decoder hears so rather than waiting it out.
pub fn unexported(job: *Job) void {
    const h = job.request.handoff orelse return;
    const x = job.host.exporter orelse return;
    if (job.exported or (job.started and !job.stream.finished and job.prefilled == null)) return; // still under way
    job.exported = true;
    x.failed(x.ptr, h, "the prompt pass ended before its state was saved");
}
