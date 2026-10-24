//! Physical night controls precede graph/teacher publication; failures keep new lessons fenced until recovery.
const std = @import("std");
const api = @import("engine_api");
const slide = @import("slide.zig");
const graph = @import("slide_graph_marks.zig");
const teacher = @import("slide_teacher.zig");
const Server = @import("server.zig").Server;
const Allocator = std.mem.Allocator;

pub const Mark = struct { graph: graph.Kept, teacher: teacher.Kept, rewound: *bool };

pub fn mark(srv: *Server, a: Allocator) ?Mark {
    const g = graph.keep(&srv.slide, a) catch return null;
    const t = srv.teacher.keepNow(srv.io, a) catch return null;
    const done = a.create(bool) catch return null;
    done.* = false;
    switch (slide.run(srv, a, &.{ .mark = true }, 0)) {
        .failed, .refused => return null,
        else => return .{ .graph = g, .teacher = t, .rewound = done },
    }
}

pub fn rewind(srv: *Server, a: Allocator, m: Mark, why: []const u8) bool {
    srv.promotion_pending.store(true, .release);
    srv.slide.saving(folder(srv));
    const began = slide.now(srv);
    if (!m.rewound.*) {
        if (failure(slide.run(srv, a, &.{ .rewind = true }, 0))) |message| return completed(srv, began, message);
        m.rewound.* = true;
    }
    graph.rewound(&srv.slide, m.graph, why) catch |e| return completed(srv, began, @errorName(e));
    srv.teacher.putBack(srv.io, m.teacher) catch |e| return completed(srv, began, @errorName(e));
    return completed(srv, began, null);
}

pub fn retire(srv: *Server, a: Allocator, neurons: []const api.Neuron) bool {
    if (neurons.len == 0) return true;
    srv.promotion_pending.store(true, .release);
    srv.slide.saving(folder(srv));
    const began = slide.now(srv);
    if (failure(slide.run(srv, a, &.{ .retire = neurons }, 0))) |message| return completed(srv, began, message);
    if (failure(slide.run(srv, a, &.{ .save = true }, 0))) |message| return completed(srv, began, message);
    graph.zeroed(&srv.slide, neurons) catch |e| return completed(srv, began, @errorName(e));
    return completed(srv, began, null);
}

fn failure(out: slide.Outcome) ?[]const u8 {
    return switch (out) {
        .failed => |message| message,
        .refused => "the engine could not take the promotion control",
        else => null,
    };
}

fn completed(srv: *Server, began: i64, why: ?[]const u8) bool {
    srv.slide.saveEnded(folder(srv), slide.seconds(srv, began), why);
    return why == null;
}

/// The owning promotion transaction calls this only after the matching state file is committed.
pub fn acknowledged(srv: *Server) void {
    srv.promotion_pending.store(false, .release);
}

fn folder(srv: *Server) ?[]const u8 {
    return if (srv.config.model_dir.len == 0) null else srv.config.model_dir;
}
