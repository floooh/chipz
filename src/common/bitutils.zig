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

/// return bit mask for a single bit position
pub inline fn mask(comptime T: anytype, comptime b: comptime_int) T {
    return 1 << b;
}

/// test multiple pins against a mask
pub inline fn pins(bus: anytype, m: comptime_int, p: comptime_int) bool {
    return (bus & m) == p;
}

/// test if all pins are set
pub inline fn pinsAll(bus: anytype, p: comptime_int) bool {
    return (bus & p) == p;
}

/// test if any pins are set
pub inline fn pinsAny(bus: anytype, p: comptime_int) bool {
    return (bus & p) != 0;
}
