//! zlib's CRC-32 of a frame's payload, with the ARMv8 CRC32 instructions where the target has them (same polynomial).
const std = @import("std");
const builtin = @import("builtin");

/// Whether this build uses the CRC32 instructions; else the table code std.hash.Crc32 runs (about 0.5 GB/s on an M5).
pub const hardware = builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);

/// zlib.crc32(bytes): reflected polynomial 0xEDB88320, initial and final value 0xFFFFFFFF.
pub fn hash(bytes: []const u8) u32 {
    if (!hardware) return std.hash.Crc32.hash(bytes);
    return ~update(0xFFFF_FFFF, bytes);
}

fn update(start: u32, bytes: []const u8) u32 {
    var crc = start;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) crc = word(crc, std.mem.readInt(u64, bytes[i..][0..8], .little));
    while (i < bytes.len) : (i += 1) crc = byte(crc, bytes[i]);
    return crc;
}

inline fn word(crc: u32, v: u64) u32 {
    return asm ("crc32x %[out:w], %[crc:w], %[v:x]"
        : [out] "=r" (-> u32),
        : [crc] "r" (crc),
          [v] "r" (v),
    );
}

inline fn byte(crc: u32, v: u8) u32 {
    return asm ("crc32b %[out:w], %[crc:w], %[v:w]"
        : [out] "=r" (-> u32),
        : [crc] "r" (crc),
          [v] "r" (@as(u32, v)),
    );
}

test "the CRC equals std.hash.Crc32 (zlib's) at every length and offset, and the check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), hash("123456789"));
    var data: [301]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 11);
    for (0..9) |off| for (0..data.len - off) |n| {
        try std.testing.expectEqual(std.hash.Crc32.hash(data[off..][0..n]), hash(data[off..][0..n]));
    };
}
