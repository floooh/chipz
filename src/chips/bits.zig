//! bit twiddling utils
const expect = @import("std").testing.expect;

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

//======================================================================================================================
test "mask" {
    try expect(mask(u64, &.{ 0, 1, 2, 3 }) == 15);
    const dbits: [8]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try expect(mask(u32, &dbits) == 255);
    const abits: [16]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try expect(mask(u32, &abits) == 65535);
}

test "setAddr" {
    const Pins = struct {
        A: [16]comptime_int,
    };
    const pins = Pins{
        .A = .{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
    };

    var bus: u64 = (4245 << 10);
    bus = setAddr(pins, bus, 0x1234);
    try expect(bus == (0x1234 << 8));

    bus = (1 << 24) | (0x4321 << 8) | (1 << 2);
    bus = setAddr(pins, bus, 0x1234);
    try expect(bus == (1 << 24) | (0x1234 << 8) | (1 << 2));
}

test "getAddr" {
    const Pins = struct {
        A: [16]comptime_int,
    };
    const pins = Pins{
        .A = .{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
    };

    const bus = (1 << 24) | (0x4321 << 8) | (1 << 2);
    const addr = getAddr(pins, bus);
    try expect(addr == 0x4321);
}

test "setData" {
    const Pins = struct {
        D: [8]comptime_int,
    };
    const pins = Pins{
        .D = .{ 24, 25, 26, 27, 28, 29, 30, 31 },
    };

    var bus: u64 = (1 << 32) | (0x56 << 24) | (0x1234 << 8);
    bus = setData(pins, bus, 0xAA);
    try expect(bus == (1 << 32) | (0xAA << 24) | (0x1234 << 8));
}

test "getData" {
    const Pins = struct {
        D: [8]comptime_int,
    };
    const pins = Pins{
        .D = .{ 24, 25, 26, 27, 28, 29, 30, 31 },
    };
    const bus: u64 = (1 << 32) | (0x56 << 24) | (0x1234 << 8);
    const data = getData(pins, bus);
    try expect(data == 0x56);
}