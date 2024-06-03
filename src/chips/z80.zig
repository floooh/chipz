const std = @import("std");
const expect = std.testing.expect;
const bits = @import("bits.zig");
const bit = bits.bit;
const mask = bits.mask;
const setAddr = bits.setAddr;
const getAddr = bits.getAddr;
const setData = bits.setData;
const getData = bits.getData;

/// map chip pin names to bit positions
pub const Pins = struct {
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

/// a default pin declaration (mainly useful for testing)
pub const DefaultPins = Pins{
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

// flag bits
pub const CF = 1 << 0;
pub const NF = 1 << 1;
pub const VF = 1 << 2;
pub const PF = VF;
pub const XF = 1 << 3;
pub const HF = 1 << 4;
pub const YF = 1 << 5;
pub const ZF = 1 << 6;
pub const SF = 1 << 7;

pub fn Z80(comptime P: Pins, comptime Bus: anytype) type {
    const M1 = P.M1;
    const HALT = P.HALT;

    return struct {
        const Self = @This();

        // current switch-case step
        step: u16 = 0,
        // program counter
        pc: u16 = 0,
        // 8/16 bit register bank
        r: [NumRegs]u8 = [_]u8{0xFF} ** NumRegs,
        // merged I and R register
        ir: u16 = 0,
        // shadow register bank
        af2: u16 = 0xFFFF,
        bc2: u16 = 0xFFFF,
        de2: u16 = 0xFFFF,
        hl2: u16 = 0xFFFF,

        // current d offset (in IX/IX+d)
        d: i8 = 0,

        // interrupt mode (0, 1 or 2)
        im: u2 = 0,

        // interrupt enable flags
        iff1: bool = false,
        iff2: bool = false,

        pub fn prefetch(self: *Self, addr: u16) void {
            self.pc = addr;
            self.step = 0;
        }

        fn halt(self: *Self, bus: Bus) Bus {
            self.pc -%= 1;
            return bus | bit(HALT);
        }

        inline fn trn8(v: anytype) u8 {
            return @as(u8, @truncate(v));
        }

        inline fn szFlags(val: u9) u8 {
            const v8 = trn8(val);
            return if (v8 != 0) (v8 & SF) else ZF;
        }

        inline fn szyxchFlags(acc: u9, val: u8, res: u9) u8 {
            return szFlags(res) | trn8((res & (YF | XF)) | ((res >> 8) & CF) | ((acc ^ val ^ res) & HF));
        }

        inline fn addFlags(acc: u9, val: u8, res: u9) u8 {
            return szyxchFlags(acc, val, res) | trn8((((val ^ acc ^ 0x80) & (val ^ res)) >> 5) & VF);
        }

        inline fn subFlags(acc: u9, val: u8, res: u9) u8 {
            return NF | szyxchFlags(acc, val, res) | trn8((((val ^ acc) & (res ^ acc)) >> 5) & VF);
        }

        inline fn cpFlags(acc: u9, val: u8, res: u9) u8 {
            return NF | szFlags(res) | trn8((val & (YF | XF)) | ((res >> 8) & CF) | ((acc ^ val ^ res) & HF) | ((((val ^ acc) & (res ^ acc)) >> 5) & VF));
        }

        inline fn szpFlags(val: u8) u8 {
            return szFlags(val) | (((@popCount(val) << 2) & PF) ^ PF) | (val & (YF | XF));
        }

        fn add8(self: *Self, val: u8) void {
            const acc: u9 = self.r[A];
            const res: u9 = acc + val;
            self.r[F] = addFlags(acc, val, res);
            self.r[A] = @truncate(res);
        }

        fn adc8(self: *Self, val: u8) void {
            const acc: u9 = self.r[A];
            const res: u9 = acc + val + (self.r[F] & CF);
            self.r[F] = addFlags(acc, val, res);
            self.r[A] = @truncate(res);
        }

        fn sub8(self: *Self, val: u8) void {
            const acc: u9 = self.r[A];
            const res: u9 = acc -% val;
            self.r[F] = subFlags(acc, val, res);
            self.r[A] = @truncate(res);
        }

        fn sbc8(self: *Self, val: u8) void {
            const acc: u9 = self.r[A];
            const res: u9 = acc -% val -% (self.r[F] & CF);
            self.r[F] = subFlags(acc, val, res);
            self.r[A] = @truncate(res);
        }

        fn and8(self: *Self, val: u8) void {
            self.r[A] &= val;
            self.r[F] = szpFlags(self.r[A]) | HF;
        }

        fn xor8(self: *Self, val: u8) void {
            self.r[A] ^= val;
            self.r[F] = szpFlags(self.r[A]);
        }

        fn or8(self: *Self, val: u8) void {
            self.r[A] |= val;
            self.r[F] = szpFlags(self.r[A]);
        }

        fn cp8(self: *Self, val: u8) void {
            const acc: u9 = self.r[A];
            const res: u9 = acc -% val;
            self.r[F] = cpFlags(acc, val, res);
        }

        pub fn tick(self: *Self, bus: Bus) Bus {
            next: {
                fetch: {
                    switch (self.step) {
                        // BEGIN CODEGEN
                        // END CODEGEN
                    }
                }
            }
            return bus;
        }
    };
}

//==============================================================================
// ████████ ███████ ███████ ████████ ███████
//    ██    ██      ██         ██    ██
//    ██    █████   ███████    ██    ███████
//    ██    ██           ██    ██         ██
//    ██    ███████ ███████    ██    ███████
//==============================================================================

test "init" {
    const cpu = Z80(DefaultPins, u64){};
    try expect(cpu.af2 == 0xFFFF);
}

test "tick" {
    var cpu = Z80(DefaultPins, u64){};
    const bus = cpu.tick(0);
    try expect(bus == (1 << 24) | (1 << 30));
}

test "halt" {
    const HALT = bit(DefaultPins.HALT);
    var cpu = Z80(DefaultPins, u64){};
    const bus = cpu.halt(0);
    try expect(cpu.pc == 0xFFFF);
    try expect(bus == HALT);
}

test "szFlags" {
    const Cpu = Z80(DefaultPins, u64);
    try expect(Cpu.szFlags(0) == ZF);
    try expect(Cpu.szFlags(0x40) == 0);
    try expect(Cpu.szFlags(0x84) == SF);
}

test "add8" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.add8(1);
    try expect(cpu.r[A] == 0);
    try expect((cpu.r[F] & ZF) == ZF);
}
