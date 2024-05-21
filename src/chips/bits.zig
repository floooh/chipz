//! bit twiddling utils

/// create mask of set bits from a slice of bit positions (useful for data or address bus bits)
pub inline fn mask(comptime T: type, comptime bits: []const comptime_int) T {
    comptime {
        var res: T = 0;
        for (bits) |bit| {
            res |= (1 << bit);
        }
        return res;
    }
}

/// set address bus pins
pub inline fn setAddr(comptime pins: anytype, bus: anytype, addr: u16) @TypeOf(bus) {
    const Bus = @TypeOf(bus);
    const m = comptime mask(Bus, &pins.A);
    return (bus & ~m) | (@as(Bus, addr) << pins.A[0]);
}

/// get address bus pins
pub inline fn getAddr(comptime pins: anytype, bus: anytype) u16 {
    return @truncate(bus >> pins.A[0]);
}

/// set data bus pins
pub inline fn setData(comptime pins: anytype, bus: anytype, data: u8) @TypeOf(bus) {
    const Bus = @TypeOf(bus);
    const m = comptime mask(Bus, &pins.D);
    return (bus & ~m) | (@as(Bus, data) << pins.D[0]);
}

/// get data bus pins
pub inline fn getData(comptime pins: anytype, bus: anytype) u8 {
    return @truncate(bus >> pins.D[0]);
}
