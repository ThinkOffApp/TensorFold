//! Serialize learning-fence release with the Notes DELETE intent transition.
const std = @import("std");
const np = @import("notes_promote.zig");

pub const Gate = struct {
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    calls: usize = 0,
    pause_after: usize = 0,
};

pub fn acknowledge(p: *np.Promoter) bool {
    if (@import("builtin").is_test) if (p.ack_gate) |gate| {
        const call = gate.calls;
        gate.calls += 1;
        if (call == gate.pause_after) {
            gate.entered.set(p.io);
            gate.release.waitUncancelable(p.io);
        }
    };
    p.srv.notes_mutex.lockUncancelable(p.io);
    defer p.srv.notes_mutex.unlock(p.io);
    return held(p);
}

/// The caller holds notes_mutex; cleanup uses this entry point without recursively locking.
pub fn held(p: *np.Promoter) bool {
    if (blockedHeld(p)) {
        p.srv.promotion_pending.store(true, .release);
        return false;
    }
    @import("slide_night.zig").acknowledged(p.srv);
    return true;
}

/// The caller holds Notes and learning locks (or is initializing before workers start).
pub fn blockedHeld(p: *np.Promoter) bool {
    // erasing is set under Notes before learning.tryLock, and cleared there only after every intent is checked.
    // Journal records may still await non-promotion cleanup after owned addresses have safely been retired.
    return p.erasing.load(.acquire) or p.rewind_pending;
}
