const std = @import("std");
const expect = std.testing.expect;

const Self = @This();

const Pins = struct {
    D: [8]comptime_int,
    A: [16]comptime_int,
    M1: comptime_int,
    MREQ: comptime_int,
    IORQ: comptime_int,
    RD: comptime_int,
    WR: comptime_int,
    RFSH: comptime_int,
    HALT: comptime_int,
    WAIT: comptime_int,
    INT: comptime_int,
    NMI: comptime_int,
    RESET: comptime_int,
    BUSRQ: comptime_int,
    BUSAK: comptime_int,
};

const DefaultPins = Pins{
    .D = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .A = .{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
    .M1 = 24,
    .MREQ = 25,
    .IORQ = 26,
    .RD = 27,
    .WR = 28,
    .RFSH = 29,
    .HALT = 30,
    .WAIT = 31,
    .INT = 32,
    .NMI = 33,
    .RESET = 34,
    .BUSRQ = 35,
    .BUSAK = 36,
};

// indices into register bank
pub const F = 0;
pub const A = 1;
pub const C = 2;
pub const B = 3;
pub const E = 4;
pub const D = 5;
pub const L = 6;
pub const H = 7;
pub const IXL = 8;
pub const IXH = 9;
pub const IYL = 10;
pub const IYH = 11;
pub const WZL = 12;
pub const WZH = 13;
pub const SPL = 14;
pub const SPH = 15;
pub const NumRegs = 16;

// current switch-case step
step: u16,

// program counter
pc: u16,

// 8/16 bit register bank
r: [NumRegs]u8,

// merged I and R register
ir: u16,

// shadow register bank
af2: u16,
bc2: u16,
de2: u16,
hl2: u16,

// interrupt mode (0, 1 or 2)
im: u2,

// interrupt enable flags
iff1: bool,
iff2: bool,

/// initialize a Z80 instance, return
pub fn init() Self {
    return .{
        .step = 0,
        .r = [_]u8{0xFF} ** NumRegs,
        .af2 = 0xFFFF,
        .bc2 = 0xFFFF,
        .de2 = 0xFFFF,
        .hl2 = 0xFFFF,
        .pc = 0,
        .ir = 0,
        .im = 0,
        .iff1 = false,
        .iff2 = false,
    };
}

/// start execution at a new address, return pin mask
pub fn prefetch(self: *Self, addr: u16) void {
    self.pc = addr;
    // start at the overlapped cycle of the NOP instruction
    self.step = 0;
}

/// execute one tick
pub fn tick(self: *Self, comptime P: anytype, comptime Bus: anytype, bus: Bus) Bus {
    _ = self;
    const m1 = (1 << P.M1);
    const halt = (1 << P.HALT);
    //>CODEGEN
    // => code generated stuff will go here
    //<CODEGEN
    return bus | m1 | halt;
}

test "init" {
    const z80 = Self.init();
    try expect(z80.af2 == 0xFFFF);
}

test "tick" {
    var z80 = Self.init();
    const bus = z80.tick(DefaultPins, u64, 0);
    try expect(bus == (1 << 24) | (1 << 30));
}
