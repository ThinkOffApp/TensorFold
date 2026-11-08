//! #1594 step 2b, the producer's side: a handoff request's prompt state saved by its family for another machine.
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

/// A handoff stream cuts once, before the prompt's last token (whose row stays pending), and exports there; no cache.
pub fn exporting(h: *const LaneHost, job: *Job, reuse: *lanes.stream.Reuse) bool {
    if (job.request.handoff == null or h.exporter == null) return false;
    job.cut = .{@intCast(job.request.prompt.len - 1)};
    if (reuse.at >= job.cut[0]) reuse.* = .{}; // a restore at the cut leaves no chunk ending there, so no export
    reuse.marks = &job.cut;
    reuse.hook = .{ .ptr = job, .at = exportAt };
    return true;
}

fn exportAt(ptr: *anyopaque, s: *lanes.Stream, at: u32) void {
    const job: *Job = @ptrCast(@alignCast(ptr));
    const x = job.host.exporter orelse return;
    const h = job.request.handoff orelse return;
    if (job.exported or at != job.cut[0]) return;
    job.exported = true;
    const saved = x.snapshots.vtable.save(x.snapshots.ptr, s, at) catch |err| return x.failed(x.ptr, h, @errorName(err));
    x.exported(x.ptr, h, job.request.prompt[0..at], saved);
}

/// A handoff whose pass ended (or never ran) without its state: the decoder hears so rather than waiting it out.
pub fn unexported(job: *Job) void {
    const h = job.request.handoff orelse return;
    const x = job.host.exporter orelse return;
    if (job.exported or (job.started and !job.stream.finished and job.prefilled == null)) return; // still under way
    job.exported = true;
    x.failed(x.ptr, h, "the prompt pass ended before its state was saved");
}
