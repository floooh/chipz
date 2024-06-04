//! bit twiddling utils
const expect = @import("std").testing.expect;

/// create mask of set bits from a slice of bit positions (useful for data or address bus bits)
pub inline fn mask(comptime bits: []const comptime_int) comptime_int {
    comptime {
        var res = 0;
        for (bits) |b| {
            res |= (1 << b);
        }
        return res;
    }
}

pub inline fn bit(comptime b: comptime_int) comptime_int {
    return 1 << b;
}

// test if single bit is set
pub inline fn tst(bus: anytype, comptime b: comptime_int) bool {
    return 0 != (bus & comptime bit(b));
}

//==============================================================================
// ████████ ███████ ███████ ████████ ███████
//    ██    ██      ██         ██    ██
//    ██    █████   ███████    ██    ███████
//    ██    ██           ██    ██         ██
//    ██    ███████ ███████    ██    ███████
//==============================================================================

test "mask" {
    try expect(mask(&.{ 0, 1, 2, 3 }) == 15);
    const dbits: [8]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try expect(mask(&dbits) == 255);
    const abits: [16]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try expect(mask(&abits) == 65535);
}

test "bit" {
    try expect(bit(31) == 1 << 31);
    try expect(bit(2) == 4);
}
