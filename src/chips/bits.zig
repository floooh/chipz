//! bit twiddling utils
const expect = @import("std").testing.expect;

/// create mask of set bits from a slice of bit positions (useful for data or address bus bits)
pub inline fn maskm(comptime T: anytype, comptime bits: []const comptime_int) T {
    comptime {
        var res = 0;
        for (bits) |b| {
            res |= (1 << b);
        }
        return res;
    }
}

pub inline fn mask(comptime T: anytype, comptime b: comptime_int) T {
    return 1 << b;
}

pub inline fn clr(bus: anytype, comptime m: @TypeOf(bus)) @TypeOf(bus) {
    return bus & ~m;
}

//==============================================================================
// ████████ ███████ ███████ ████████ ███████
//    ██    ██      ██         ██    ██
//    ██    █████   ███████    ██    ███████
//    ██    ██           ██    ██         ██
//    ██    ███████ ███████    ██    ███████
//==============================================================================

test "maskm" {
    try expect(maskm(u64, &.{ 0, 1, 2, 3 }) == 15);
    const dbits: [8]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try expect(maskm(u64, &dbits) == 255);
    const abits: [16]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try expect(maskm(u64, &abits) == 65535);
}

test "mask" {
    try expect(mask(u64, 31) == 1 << 31);
    try expect(mask(u64, 2) == 4);
}
