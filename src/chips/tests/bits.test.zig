const expect = @import("std").testing.expect;
const bits = @import("../bits.zig");

test "mask" {
    try expect(bits.mask(u64, &.{ 0, 1, 2, 3 }) == 15);
    const dbits: [8]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try expect(bits.mask(u32, &dbits) == 255);
    const abits: [16]comptime_int = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try expect(bits.mask(u32, &abits) == 65535);
}

test "setAddr" {
    const Pins = struct {
        A: [16]comptime_int,
    };
    const pins = Pins{
        .A = .{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
    };

    var bus: u64 = (4245 << 10);
    bus = bits.setAddr(pins, bus, 0x1234);
    try expect(bus == (0x1234 << 8));

    bus = (1 << 24) | (0x4321 << 8) | (1 << 2);
    bus = bits.setAddr(pins, bus, 0x1234);
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
    const addr = bits.getAddr(pins, bus);
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
    bus = bits.setData(pins, bus, 0xAA);
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
    const data = bits.getData(pins, bus);
    try expect(data == 0x56);
}
