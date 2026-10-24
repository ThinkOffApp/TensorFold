//! Failed take-out controls retain graph addresses so promotion can recover every still-live neuron.
const std = @import("std");
const slide = @import("slide.zig");
const Server = @import("server.zig").Server;

pub fn take(srv: *Server, a: std.mem.Allocator, id: u32, undo: bool) bool {
    const result = slide.run(srv, a, &.{ .drop = !undo, .undo = undo }, 0);
    switch (result) {
        .failed, .refused => {
            srv.slide.mutex.lockUncancelable(srv.io);
            const owned = if (srv.slide.find(id)) |f| f.promotion_key.len > 0 else false;
            srv.slide.mutex.unlock(srv.io);
            if (owned) srv.promotion_pending.store(true, .release);
            return false;
        },
        else => {},
    }
    srv.slide.placed(id, &.{});
    return true;
}
