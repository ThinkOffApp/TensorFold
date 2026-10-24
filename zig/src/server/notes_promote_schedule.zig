//! Small recovery retries do not start another full night before the configured interval or an explicit request.
pub const Action = enum { wait, recover, night };

pub fn next(now: i64, last_night: i64, last_recovery: i64, every: i64, asked: bool, pending: bool) Action {
    if (asked or now - last_night >= every) return .night;
    if (pending and now - last_recovery >= 5000) return .recover;
    return .wait;
}

test "promotion schedule: a failed night retries controls without repeating question generation every five seconds" {
    const t = @import("std").testing;
    var recovery: i64 = 1000;
    var nights: usize = 0;
    var small: usize = 0;
    var now: i64 = 1000;
    while (now < 601_000) : (now += 500) switch (next(now, 1000, recovery, 600_000, false, true)) {
        .wait => {},
        .night => nights += 1,
        .recover => {
            recovery = now;
            small += 1;
        },
    };
    try t.expectEqual(@as(usize, 0), nights);
    try t.expect(small > 0 and small <= 120);
    try t.expectEqual(Action.night, next(601_000, 1000, recovery, 600_000, false, true));
    try t.expectEqual(Action.night, next(6500, 1000, recovery, 600_000, true, true));
}
