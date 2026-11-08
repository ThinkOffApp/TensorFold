//! #1594 step 2b: a prompt prefix another machine filled, handed to its stream in place of a kept state.
const std = @import("std");
const api = @import("engine_api.zig");
const pc = @import("prompt_cache.zig");
const lanes = @import("lanes");
const LaneHost = @import("lane_host.zig").LaneHost;
const Job = @import("lane_job.zig").Job;

/// A family's remote prefill (fabric/prefill_source.zig behind it): opt-in, and outside the exactness contract.
pub const Source = struct {
    ptr: *anyopaque,
    /// Fill a prefix of `prompt` into new storage on the caller's thread; null leaves the whole prompt to this engine.
    fill: *const fn (ptr: *anyopaque, prompt: []const u32) anyerror!?Filled,
    /// Free the storage `fill` returned.
    drop: *const fn (ptr: *anyopaque, saved: pc.Saved) void,
};

/// The family's state after `at` prompt tokens, computed by another machine: never kept, never the engine's own.
pub const Filled = struct { saved: pc.Saved, at: u32 };

/// serve --prefill-from URL (the GB10 server) and --mcdma-link NAME (mcdma-rpcd's connect link): both, or neither.
pub const Flags = struct {
    url: ?[]const u8 = null,
    link: ?[]const u8 = null,

    pub fn on(f: Flags) bool {
        return f.url != null or f.link != null;
    }
};

/// Whether a request may take a remote prefix: text a stream decodes, with nothing that needs the engine's own rows.
fn eligible(r: *const Request) bool {
    return !r.promptOnly() and !r.background and r.images.len == 0 and r.prompt_logprobs == null and !r.untaught and r.embedding == null;
}

const Request = api.Request;

/// A request's remote prefix, filled before its job is queued; a failed fill leaves the prompt to this engine.
pub fn take(h: *const LaneHost, r: *const Request) ?Filled {
    const source = h.remote orelse return null;
    if (!eligible(r)) return null;
    const got = source.fill(source.ptr, r.prompt) catch |err| {
        std.log.warn("remote prefill failed ({s}); the prompt is prefilled here", .{@errorName(err)});
        return null;
    };
    const f = got orelse return null;
    if (f.at == 0 or f.at >= r.prompt.len) { // at least one prompt row stays here: its logits draw the first token
        source.drop(source.ptr, f.saved);
        return null;
    }
    return f;
}

/// Frees a prefix no job took.
pub fn release(h: *const LaneHost, f: ?Filled) void {
    const got = f orelse return;
    if (h.remote) |source| source.drop(source.ptr, got.saved);
}

/// The stream restores the remote prefix unless the cache holds at least as much; a cache entry it beats is released.
pub fn use(h: *LaneHost, job: *Job, reuse: *lanes.stream.Reuse) void {
    const f = job.remote orelse return;
    if (reuse.saved != null and reuse.at >= f.at) return drop(job);
    if (job.entry) |e| if (h.cache) |store| store.release(e);
    job.entry = null;
    reuse.* = .{ .saved = f.saved, .at = f.at, .remote = true }; // no marks and no hook: nothing after it is kept
}

/// The prefix is restored (or never will be): its storage goes.
pub fn drop(job: *Job) void {
    const f = job.remote orelse return;
    job.remote = null;
    if (job.started and job.stream.reuse.saved == f.saved) job.stream.reuse.saved = null;
    if (job.host.remote) |source| source.drop(source.ptr, f.saved);
}

/// Prompt tokens the engine's own cache supplied: a remote prefix is not one.
pub fn cachedOwn(job: *const Job) u32 {
    return if (job.stream.reuse.remote) 0 else job.stream.cached;
}
