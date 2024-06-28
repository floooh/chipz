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
