//! The engine API module's tests: the lane host's, the prompt caches', the idle keepalive's and the originals'.
test {
    _ = @import("lane_host.zig");
    _ = @import("lane_host_test.zig");
    _ = @import("prompt_cache.zig");
    _ = @import("prompt_radix.zig");
    _ = @import("prompt_imprint.zig");
    _ = @import("keepalive.zig");
    _ = @import("originals_test.zig");
    _ = @import("inject.zig");
}
