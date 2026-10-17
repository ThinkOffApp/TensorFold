//! A lane host's injected context: a running reply's queued tokens join its stream between rounds, never delivered.
const std = @import("std");
const api = @import("engine_api.zig");
const LaneHost = @import("lane_host.zig").LaneHost;
const Job = LaneHost.Job;

/// Cache rows a request holds past max_tokens for injected context; none under a grammar, which takes none.
pub fn room(r: *const api.Request) u32 {
    const i = r.inject orelse return 0;
    return if (r.structure != null) 0 else i.room;
}

/// Context waits for the job's stream: a lone driver hands the stream to the lane core for it.
pub fn waits(job: *const Job) bool {
    const i = job.request.inject orelse return false;
    return i.waiting();
}

/// Before a round: each decoding stream's waiting context goes in as a prompt pass, its own tokens so far sent first.
pub fn take(h: *LaneHost) !void {
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(h.gpa);
    for (h.admitted.items) |job| {
        const i = job.request.inject orelse continue;
        if (!i.waiting() or !job.started) continue;
        const s = &job.stream;
        // a prompt still going in or a forced close under way keeps it waiting; a grammar's reply never takes it
        if (s.finished or s.pending == null or s.force.items.len > 0 or s.grammar != null) continue;
        try h.core.settle(s);
        if (s.finished) continue; // the step in flight ended the reply: the round's delivery ends the job
        h.send(job);
        got.clearRetainingCapacity();
        try i.take(h.gpa, &got, @intCast(job.delivered - i.count()));
        if (got.items.len == 0) continue;
        const before = job.delivered;
        h.core.extend(s, got.items) catch |e| {
            s.finished = true; // this reply fails alone: the others' rounds go on
            s.reason = .@"error";
            s.problem = @errorName(e);
            job.delivered = s.emitted().len; // context that went in is never sent as the reply's
            continue;
        };
        job.delivered = before + got.items.len; // the reply's next token is its first after the context
    }
}
