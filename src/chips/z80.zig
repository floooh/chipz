const std = @import("std");
const expect = std.testing.expect;
const bits = @import("bits.zig");
const tst = bits.tst;
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
    const HALT = P.HALT;
    const WAIT = P.WAIT;

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
                        0x40 => {
                            self.r[B] = self.r[B];
                            break :fetch;
                        }, // LD B,B
                        0x41 => {
                            self.r[B] = self.r[C];
                            break :fetch;
                        }, // LD B,C
                        0x42 => {
                            self.r[B] = self.r[D];
                            break :fetch;
                        }, // LD B,D
                        0x43 => {
                            self.r[B] = self.r[E];
                            break :fetch;
                        }, // LD B,E
                        0x44 => {
                            self.r[B] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD B,H
                        0x45 => {
                            self.r[B] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD B,L
                        0x46 => {
                            self.step = 0x300;
                            break :next;
                        }, // LD B,(HL)
                        0x47 => {
                            self.r[B] = self.r[A];
                            break :fetch;
                        }, // LD B,A
                        0x48 => {
                            self.r[C] = self.r[B];
                            break :fetch;
                        }, // LD C,B
                        0x49 => {
                            self.r[C] = self.r[C];
                            break :fetch;
                        }, // LD C,C
                        0x4A => {
                            self.r[C] = self.r[D];
                            break :fetch;
                        }, // LD C,D
                        0x4B => {
                            self.r[C] = self.r[E];
                            break :fetch;
                        }, // LD C,E
                        0x4C => {
                            self.r[C] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD C,H
                        0x4D => {
                            self.r[C] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD C,L
                        0x4E => {
                            self.step = 0x303;
                            break :next;
                        }, // LD C,(HL)
                        0x4F => {
                            self.r[C] = self.r[A];
                            break :fetch;
                        }, // LD C,A
                        0x50 => {
                            self.r[D] = self.r[B];
                            break :fetch;
                        }, // LD D,B
                        0x51 => {
                            self.r[D] = self.r[C];
                            break :fetch;
                        }, // LD D,C
                        0x52 => {
                            self.r[D] = self.r[D];
                            break :fetch;
                        }, // LD D,D
                        0x53 => {
                            self.r[D] = self.r[E];
                            break :fetch;
                        }, // LD D,E
                        0x54 => {
                            self.r[D] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD D,H
                        0x55 => {
                            self.r[D] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD D,L
                        0x56 => {
                            self.step = 0x306;
                            break :next;
                        }, // LD D,(HL)
                        0x57 => {
                            self.r[D] = self.r[A];
                            break :fetch;
                        }, // LD D,A
                        0x58 => {
                            self.r[E] = self.r[B];
                            break :fetch;
                        }, // LD E,B
                        0x59 => {
                            self.r[E] = self.r[C];
                            break :fetch;
                        }, // LD E,C
                        0x5A => {
                            self.r[E] = self.r[D];
                            break :fetch;
                        }, // LD E,D
                        0x5B => {
                            self.r[E] = self.r[E];
                            break :fetch;
                        }, // LD E,E
                        0x5C => {
                            self.r[E] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD E,H
                        0x5D => {
                            self.r[E] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD E,L
                        0x5E => {
                            self.step = 0x309;
                            break :next;
                        }, // LD E,(HL)
                        0x5F => {
                            self.r[E] = self.r[A];
                            break :fetch;
                        }, // LD E,A
                        0x60 => {
                            self.r[H + self.rixy] = self.r[B];
                            break :fetch;
                        }, // LD H,B
                        0x61 => {
                            self.r[H + self.rixy] = self.r[C];
                            break :fetch;
                        }, // LD H,C
                        0x62 => {
                            self.r[H + self.rixy] = self.r[D];
                            break :fetch;
                        }, // LD H,D
                        0x63 => {
                            self.r[H + self.rixy] = self.r[E];
                            break :fetch;
                        }, // LD H,E
                        0x64 => {
                            self.r[H + self.rixy] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD H,H
                        0x65 => {
                            self.r[H + self.rixy] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD H,L
                        0x66 => {
                            self.step = 0x30C;
                            break :next;
                        }, // LD H,(HL)
                        0x67 => {
                            self.r[H + self.rixy] = self.r[A];
                            break :fetch;
                        }, // LD H,A
                        0x68 => {
                            self.r[L + self.rixy] = self.r[B];
                            break :fetch;
                        }, // LD L,B
                        0x69 => {
                            self.r[L + self.rixy] = self.r[C];
                            break :fetch;
                        }, // LD L,C
                        0x6A => {
                            self.r[L + self.rixy] = self.r[D];
                            break :fetch;
                        }, // LD L,D
                        0x6B => {
                            self.r[L + self.rixy] = self.r[E];
                            break :fetch;
                        }, // LD L,E
                        0x6C => {
                            self.r[L + self.rixy] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD L,H
                        0x6D => {
                            self.r[L + self.rixy] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD L,L
                        0x6E => {
                            self.step = 0x30F;
                            break :next;
                        }, // LD L,(HL)
                        0x6F => {
                            self.r[L + self.rixy] = self.r[A];
                            break :fetch;
                        }, // LD L,A
                        0x70 => {
                            self.step = 0x312;
                            break :next;
                        }, // LD (HL),B
                        0x71 => {
                            self.step = 0x315;
                            break :next;
                        }, // LD (HL),C
                        0x72 => {
                            self.step = 0x318;
                            break :next;
                        }, // LD (HL),D
                        0x73 => {
                            self.step = 0x31B;
                            break :next;
                        }, // LD (HL),E
                        0x74 => {
                            self.step = 0x31E;
                            break :next;
                        }, // LD (HL),H
                        0x75 => {
                            self.step = 0x321;
                            break :next;
                        }, // LD (HL),L
                        0x76 => {
                            bus = self.halt(bus);
                            break :fetch;
                        }, // HALT
                        0x77 => {
                            self.step = 0x324;
                            break :next;
                        }, // LD (HL),A
                        0x78 => {
                            self.r[A] = self.r[B];
                            break :fetch;
                        }, // LD A,B
                        0x79 => {
                            self.r[A] = self.r[C];
                            break :fetch;
                        }, // LD A,C
                        0x7A => {
                            self.r[A] = self.r[D];
                            break :fetch;
                        }, // LD A,D
                        0x7B => {
                            self.r[A] = self.r[E];
                            break :fetch;
                        }, // LD A,E
                        0x7C => {
                            self.r[A] = self.r[H + self.rixy];
                            break :fetch;
                        }, // LD A,H
                        0x7D => {
                            self.r[A] = self.r[L + self.rixy];
                            break :fetch;
                        }, // LD A,L
                        0x7E => {
                            self.step = 0x327;
                            break :next;
                        }, // LD A,(HL)
                        0x7F => {
                            self.r[A] = self.r[A];
                            break :fetch;
                        }, // LD A,A
                        0x80 => {
                            self.add8(self.r[B]);
                            break :fetch;
                        }, // ADD B
                        0x81 => {
                            self.add8(self.r[C]);
                            break :fetch;
                        }, // ADD C
                        0x82 => {
                            self.add8(self.r[D]);
                            break :fetch;
                        }, // ADD D
                        0x83 => {
                            self.add8(self.r[E]);
                            break :fetch;
                        }, // ADD E
                        0x84 => {
                            self.add8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // ADD H
                        0x85 => {
                            self.add8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // ADD L
                        0x86 => {
                            self.step = 0x32A;
                            break :next;
                        }, // ADD (HL)
                        0x87 => {
                            self.add8(self.r[A]);
                            break :fetch;
                        }, // ADD A
                        0x88 => {
                            self.adc8(self.r[B]);
                            break :fetch;
                        }, // ADC B
                        0x89 => {
                            self.adc8(self.r[C]);
                            break :fetch;
                        }, // ADC C
                        0x8A => {
                            self.adc8(self.r[D]);
                            break :fetch;
                        }, // ADC D
                        0x8B => {
                            self.adc8(self.r[E]);
                            break :fetch;
                        }, // ADC E
                        0x8C => {
                            self.adc8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // ADC H
                        0x8D => {
                            self.adc8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // ADC L
                        0x8E => {
                            self.step = 0x32D;
                            break :next;
                        }, // ADC (HL)
                        0x8F => {
                            self.adc8(self.r[A]);
                            break :fetch;
                        }, // ADC A
                        0x90 => {
                            self.sub8(self.r[B]);
                            break :fetch;
                        }, // SUB B
                        0x91 => {
                            self.sub8(self.r[C]);
                            break :fetch;
                        }, // SUB C
                        0x92 => {
                            self.sub8(self.r[D]);
                            break :fetch;
                        }, // SUB D
                        0x93 => {
                            self.sub8(self.r[E]);
                            break :fetch;
                        }, // SUB E
                        0x94 => {
                            self.sub8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // SUB H
                        0x95 => {
                            self.sub8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // SUB L
                        0x96 => {
                            self.step = 0x330;
                            break :next;
                        }, // SUB (HL)
                        0x97 => {
                            self.sub8(self.r[A]);
                            break :fetch;
                        }, // SUB A
                        0x98 => {
                            self.sbc8(self.r[B]);
                            break :fetch;
                        }, // SBC B
                        0x99 => {
                            self.sbc8(self.r[C]);
                            break :fetch;
                        }, // SBC C
                        0x9A => {
                            self.sbc8(self.r[D]);
                            break :fetch;
                        }, // SBC D
                        0x9B => {
                            self.sbc8(self.r[E]);
                            break :fetch;
                        }, // SBC E
                        0x9C => {
                            self.sbc8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // SBC H
                        0x9D => {
                            self.sbc8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // SBC L
                        0x9E => {
                            self.step = 0x333;
                            break :next;
                        }, // SBC (HL)
                        0x9F => {
                            self.sbc8(self.r[A]);
                            break :fetch;
                        }, // SBC A
                        0xA0 => {
                            self.and8(self.r[B]);
                            break :fetch;
                        }, // AND B
                        0xA1 => {
                            self.and8(self.r[C]);
                            break :fetch;
                        }, // AND C
                        0xA2 => {
                            self.and8(self.r[D]);
                            break :fetch;
                        }, // AND D
                        0xA3 => {
                            self.and8(self.r[E]);
                            break :fetch;
                        }, // AND E
                        0xA4 => {
                            self.and8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // AND H
                        0xA5 => {
                            self.and8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // AND L
                        0xA6 => {
                            self.step = 0x336;
                            break :next;
                        }, // AND (HL)
                        0xA7 => {
                            self.and8(self.r[A]);
                            break :fetch;
                        }, // AND A
                        0xA8 => {
                            self.xor8(self.r[B]);
                            break :fetch;
                        }, // XOR B
                        0xA9 => {
                            self.xor8(self.r[C]);
                            break :fetch;
                        }, // XOR C
                        0xAA => {
                            self.xor8(self.r[D]);
                            break :fetch;
                        }, // XOR D
                        0xAB => {
                            self.xor8(self.r[E]);
                            break :fetch;
                        }, // XOR E
                        0xAC => {
                            self.xor8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // XOR H
                        0xAD => {
                            self.xor8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // XOR L
                        0xAE => {
                            self.step = 0x339;
                            break :next;
                        }, // XOR (HL)
                        0xAF => {
                            self.xor8(self.r[A]);
                            break :fetch;
                        }, // XOR A
                        0xB0 => {
                            self.or8(self.r[B]);
                            break :fetch;
                        }, // OR B
                        0xB1 => {
                            self.or8(self.r[C]);
                            break :fetch;
                        }, // OR C
                        0xB2 => {
                            self.or8(self.r[D]);
                            break :fetch;
                        }, // OR D
                        0xB3 => {
                            self.or8(self.r[E]);
                            break :fetch;
                        }, // OR E
                        0xB4 => {
                            self.or8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // OR H
                        0xB5 => {
                            self.or8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // OR L
                        0xB6 => {
                            self.step = 0x33C;
                            break :next;
                        }, // OR (HL)
                        0xB7 => {
                            self.or8(self.r[A]);
                            break :fetch;
                        }, // OR A
                        0xB8 => {
                            self.cp8(self.r[B]);
                            break :fetch;
                        }, // CP B
                        0xB9 => {
                            self.cp8(self.r[C]);
                            break :fetch;
                        }, // CP C
                        0xBA => {
                            self.cp8(self.r[D]);
                            break :fetch;
                        }, // CP D
                        0xBB => {
                            self.cp8(self.r[E]);
                            break :fetch;
                        }, // CP E
                        0xBC => {
                            self.cp8(self.r[H + self.rixy]);
                            break :fetch;
                        }, // CP H
                        0xBD => {
                            self.cp8(self.r[L + self.rixy]);
                            break :fetch;
                        }, // CP L
                        0xBE => {
                            self.step = 0x33F;
                            break :next;
                        }, // CP (HL)
                        0xBF => {
                            self.cp8(self.r[A]);
                            break :fetch;
                        }, // CP A
                        0x300 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x301;
                            break :next;
                        }, // LD B,(HL) (cont...)
                        0x301 => {
                            self.r[B] = gd(bus);
                            self.step = 0x302;
                            break :next;
                        },
                        0x302 => {
                            break :fetch;
                        },
                        0x303 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x304;
                            break :next;
                        }, // LD C,(HL) (cont...)
                        0x304 => {
                            self.r[C] = gd(bus);
                            self.step = 0x305;
                            break :next;
                        },
                        0x305 => {
                            break :fetch;
                        },
                        0x306 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x307;
                            break :next;
                        }, // LD D,(HL) (cont...)
                        0x307 => {
                            self.r[D] = gd(bus);
                            self.step = 0x308;
                            break :next;
                        },
                        0x308 => {
                            break :fetch;
                        },
                        0x309 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x30A;
                            break :next;
                        }, // LD E,(HL) (cont...)
                        0x30A => {
                            self.r[E] = gd(bus);
                            self.step = 0x30B;
                            break :next;
                        },
                        0x30B => {
                            break :fetch;
                        },
                        0x30C => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x30D;
                            break :next;
                        }, // LD H,(HL) (cont...)
                        0x30D => {
                            self.r[H] = gd(bus);
                            self.step = 0x30E;
                            break :next;
                        },
                        0x30E => {
                            break :fetch;
                        },
                        0x30F => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x310;
                            break :next;
                        }, // LD L,(HL) (cont...)
                        0x310 => {
                            self.r[L] = gd(bus);
                            self.step = 0x311;
                            break :next;
                        },
                        0x311 => {
                            break :fetch;
                        },
                        0x312 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[B]);
                            self.step = 0x313;
                            break :next;
                        }, // LD (HL),B (cont...)
                        0x313 => {
                            self.step = 0x314;
                            break :next;
                        },
                        0x314 => {
                            break :fetch;
                        },
                        0x315 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[C]);
                            self.step = 0x316;
                            break :next;
                        }, // LD (HL),C (cont...)
                        0x316 => {
                            self.step = 0x317;
                            break :next;
                        },
                        0x317 => {
                            break :fetch;
                        },
                        0x318 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[D]);
                            self.step = 0x319;
                            break :next;
                        }, // LD (HL),D (cont...)
                        0x319 => {
                            self.step = 0x31A;
                            break :next;
                        },
                        0x31A => {
                            break :fetch;
                        },
                        0x31B => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[E]);
                            self.step = 0x31C;
                            break :next;
                        }, // LD (HL),E (cont...)
                        0x31C => {
                            self.step = 0x31D;
                            break :next;
                        },
                        0x31D => {
                            break :fetch;
                        },
                        0x31E => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[H]);
                            self.step = 0x31F;
                            break :next;
                        }, // LD (HL),H (cont...)
                        0x31F => {
                            self.step = 0x320;
                            break :next;
                        },
                        0x320 => {
                            break :fetch;
                        },
                        0x321 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[L]);
                            self.step = 0x322;
                            break :next;
                        }, // LD (HL),L (cont...)
                        0x322 => {
                            self.step = 0x323;
                            break :next;
                        },
                        0x323 => {
                            break :fetch;
                        },
                        0x324 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mwrite(bus, self.addr(), self.r[A]);
                            self.step = 0x325;
                            break :next;
                        }, // LD (HL),A (cont...)
                        0x325 => {
                            self.step = 0x326;
                            break :next;
                        },
                        0x326 => {
                            break :fetch;
                        },
                        0x327 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x328;
                            break :next;
                        }, // LD A,(HL) (cont...)
                        0x328 => {
                            self.r[A] = gd(bus);
                            self.step = 0x329;
                            break :next;
                        },
                        0x329 => {
                            break :fetch;
                        },
                        0x32A => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x32B;
                            break :next;
                        }, // ADD (HL) (cont...)
                        0x32B => {
                            self.dlatch = gd(bus);
                            self.step = 0x32C;
                            break :next;
                        },
                        0x32C => {
                            self.add8(self.dlatch);
                            break :fetch;
                        },
                        0x32D => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x32E;
                            break :next;
                        }, // ADC (HL) (cont...)
                        0x32E => {
                            self.dlatch = gd(bus);
                            self.step = 0x32F;
                            break :next;
                        },
                        0x32F => {
                            self.adc8(self.dlatch);
                            break :fetch;
                        },
                        0x330 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x331;
                            break :next;
                        }, // SUB (HL) (cont...)
                        0x331 => {
                            self.dlatch = gd(bus);
                            self.step = 0x332;
                            break :next;
                        },
                        0x332 => {
                            self.sub8(self.dlatch);
                            break :fetch;
                        },
                        0x333 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x334;
                            break :next;
                        }, // SBC (HL) (cont...)
                        0x334 => {
                            self.dlatch = gd(bus);
                            self.step = 0x335;
                            break :next;
                        },
                        0x335 => {
                            self.sbc8(self.dlatch);
                            break :fetch;
                        },
                        0x336 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x337;
                            break :next;
                        }, // AND (HL) (cont...)
                        0x337 => {
                            self.dlatch = gd(bus);
                            self.step = 0x338;
                            break :next;
                        },
                        0x338 => {
                            self.and8(self.dlatch);
                            break :fetch;
                        },
                        0x339 => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x33A;
                            break :next;
                        }, // XOR (HL) (cont...)
                        0x33A => {
                            self.dlatch = gd(bus);
                            self.step = 0x33B;
                            break :next;
                        },
                        0x33B => {
                            self.xor8(self.dlatch);
                            break :fetch;
                        },
                        0x33C => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x33D;
                            break :next;
                        }, // OR (HL) (cont...)
                        0x33D => {
                            self.dlatch = gd(bus);
                            self.step = 0x33E;
                            break :next;
                        },
                        0x33E => {
                            self.or8(self.dlatch);
                            break :fetch;
                        },
                        0x33F => {
                            if (tst(bus, WAIT)) break :next;
                            bus = mread(bus, self.addr());
                            self.step = 0x340;
                            break :next;
                        }, // CP (HL) (cont...)
                        0x340 => {
                            self.dlatch = gd(bus);
                            self.step = 0x341;
                            break :next;
                        },
                        0x341 => {
                            self.cp8(self.dlatch);
                            break :fetch;
                        },
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
