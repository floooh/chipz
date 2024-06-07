const std = @import("std");
const bits = @import("bits.zig");
const tst = bits.tst;
const bit = bits.bit;
const mask = bits.mask;
const clr = bits.clr;

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
    const MREQ = P.MREQ;
    const IORQ = P.IORQ;
    const RD = P.RD;
    const WR = P.WR;
    const HALT = P.HALT;
    const WAIT = P.WAIT;
    const RFSH = P.RFSH;

    return struct {
        const Self = @This();

        // current switch-case step
        step: u16 = 0,
        // program counter
        pc: u16 = 0,
        // latch for data bus content
        dlatch: u8 = 0,
        // current opcode
        opcode: u8 = 0,
        // index to add to H,L to reach H/L, IXH/IXL, IYH/IYL
        rixy: u8 = 0,
        // true when one of the prefixes is active
        prefix_active: bool = false,
        // effective address: HL, IX+d, IY+d
        addr: u16 = 0,
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

        pub fn opdone(self: *const Self, bus: Bus) bool {
            const m = mask(&.{ M1, RD });
            return (!self.prefix_active) and ((bus & m) == m);
        }

        inline fn get16(self: *const Self, comptime lo: comptime_int) u16 {
            // NOTE: this should result in a single 16-bit read
            return (@as(u16, self.r[lo + 1]) << 8) | self.r[lo];
        }

        inline fn set16(self: *Self, comptime lo: comptime_int, val: u16) void {
            // NOTE: this should result in a single 16-bit write
            self.r[lo] = @truncate(val);
            self.r[lo + 1] = @truncate(val >> 8);
        }

        pub inline fn BC(self: *const Self) u16 {
            return self.get16(C);
        }

        pub inline fn setBC(self: *Self, bc: u16) void {
            self.set16(C, bc);
        }

        pub inline fn DE(self: *const Self) u16 {
            return self.get16(E);
        }

        pub inline fn setDE(self: *Self, de: u16) void {
            self.set16(E, de);
        }

        pub inline fn HL(self: *const Self) u16 {
            return self.get16(L);
        }

        pub inline fn setHL(self: *Self, hl: u16) void {
            self.set16(L, hl);
        }

        pub inline fn IX(self: *const Self) u16 {
            return self.get16(IXL);
        }

        pub inline fn setIX(self: *Self, ix: u16) void {
            self.set16(IXL, ix);
        }

        pub inline fn IY(self: *const Self) u16 {
            return self.get16(IYL);
        }

        pub inline fn setIY(self: *Self, iy: u16) void {
            self.set16(IYL, iy);
        }

        pub inline fn WZ(self: *const Self) u16 {
            return self.get16(WZL);
        }

        pub inline fn setWZ(self: *Self, wz: u16) void {
            self.set16(WZL, wz);
        }

        pub inline fn SP(self: *const Self) u16 {
            return self.get16(SPL);
        }

        pub inline fn setSP(self: *Self, sp: u16) void {
            self.set16(SPL, sp);
        }

        pub inline fn setAddr(bus: Bus, addr: u16) Bus {
            const m: Bus = comptime mask(&P.A);
            return (bus & ~m) | (@as(Bus, addr) << P.A[0]);
        }

        pub inline fn getAddr(bus: Bus) u16 {
            return @truncate(bus >> P.A[0]);
        }

        inline fn setAddrData(bus: Bus, addr: u16, data: u8) Bus {
            const m: Bus = comptime (mask(&P.A) | mask(&P.D));
            return (bus & ~m) | (@as(Bus, addr) << P.A[0]) | (@as(Bus, data) << P.D[0]);
        }

        pub inline fn getData(bus: Bus) u8 {
            return @truncate(bus >> P.D[0]);
        }
        const gd = getData;

        pub inline fn setData(bus: Bus, data: u8) Bus {
            const m: Bus = comptime mask(&P.D);
            return (bus & ~m) | (@as(Bus, data) << P.D[0]);
        }

        inline fn mrd(bus: Bus, addr: u16) Bus {
            return setAddr(bus, addr) | comptime mask(&.{ MREQ, RD });
        }

        inline fn mwr(bus: Bus, addr: u16, data: u8) Bus {
            return setAddrData(bus, addr, data) | comptime mask(&.{ MREQ, WR });
        }

        inline fn wait(bus: Bus) bool {
            return tst(bus, WAIT);
        }

        inline fn fetch(self: *Self, bus: Bus) Bus {
            self.rixy = 0;
            self.prefix_active = false;
            // FIXME: check int bits
            self.step = M1_T2;
            const out_bus = setAddr(bus, self.pc) | comptime mask(&.{ M1, MREQ, RD });
            self.pc +%= 1;
            return out_bus;
        }

        inline fn refresh(self: *Self, bus: Bus) Bus {
            const out_bus = setAddr(bus, self.ir) | comptime mask(&.{MREQ | RFSH});
            var r = self.ir & 0x00FF;
            r = (r & 0x80) | ((r +% 1) & 0x7F);
            self.ir = (self.ir & 0xFF00) | r;
            return out_bus;
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

        fn halt(self: *Self, bus: Bus) Bus {
            self.pc -%= 1;
            return bus | bit(HALT);
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

        // BEGIN CONSTS
        const M1_T2: u16 = 0x35D;
        const M1_T3: u16 = 0x35E;
        const M1_T4: u16 = 0x35F;
        // END CONSTS

        // zig fmt: off
        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = clr(in_bus, &.{ M1, MREQ, IORQ, RD, WR, RFSH });
            next: {
                switch (self.step) {
                    // fetch machine cycle
                    M1_T2 => {
                        if (wait(bus)) break :next;
                        self.opcode = gd(bus);
                        self.step = M1_T3;
                        break :next;
                    },
                    M1_T3 => {
                        bus = self.refresh(bus);
                        self.step = M1_T4;
                        break :next;
                    },
                    M1_T4 => {
                        self.step = self.opcode;
                        self.addr = self.HL();
                        break :next;
                    },
                    // BEGIN DECODE
                    // NOP
                    0x0 => {
                    },
                    // LD B,n
                    0x6 => {
                        self.step = 0x300;
                        break :next;
                    },
                    // LD C,n
                    0xE => {
                        self.step = 0x303;
                        break :next;
                    },
                    // LD D,n
                    0x16 => {
                        self.step = 0x306;
                        break :next;
                    },
                    // LD E,n
                    0x1E => {
                        self.step = 0x309;
                        break :next;
                    },
                    // LD H,n
                    0x26 => {
                        self.step = 0x30C;
                        break :next;
                    },
                    // LD L,n
                    0x2E => {
                        self.step = 0x30F;
                        break :next;
                    },
                    // LD (HL),n
                    0x36 => {
                        self.step = 0x312;
                        break :next;
                    },
                    // LD A,n
                    0x3E => {
                        self.step = 0x318;
                        break :next;
                    },
                    // LD B,B
                    0x40 => {
                        self.r[B] = self.r[B];
                    },
                    // LD B,C
                    0x41 => {
                        self.r[B] = self.r[C];
                    },
                    // LD B,D
                    0x42 => {
                        self.r[B] = self.r[D];
                    },
                    // LD B,E
                    0x43 => {
                        self.r[B] = self.r[E];
                    },
                    // LD B,H
                    0x44 => {
                        self.r[B] = self.r[H + self.rixy];
                    },
                    // LD B,L
                    0x45 => {
                        self.r[B] = self.r[L + self.rixy];
                    },
                    // LD B,(HL)
                    0x46 => {
                        self.step = 0x31B;
                        break :next;
                    },
                    // LD B,A
                    0x47 => {
                        self.r[B] = self.r[A];
                    },
                    // LD C,B
                    0x48 => {
                        self.r[C] = self.r[B];
                    },
                    // LD C,C
                    0x49 => {
                        self.r[C] = self.r[C];
                    },
                    // LD C,D
                    0x4A => {
                        self.r[C] = self.r[D];
                    },
                    // LD C,E
                    0x4B => {
                        self.r[C] = self.r[E];
                    },
                    // LD C,H
                    0x4C => {
                        self.r[C] = self.r[H + self.rixy];
                    },
                    // LD C,L
                    0x4D => {
                        self.r[C] = self.r[L + self.rixy];
                    },
                    // LD C,(HL)
                    0x4E => {
                        self.step = 0x31E;
                        break :next;
                    },
                    // LD C,A
                    0x4F => {
                        self.r[C] = self.r[A];
                    },
                    // LD D,B
                    0x50 => {
                        self.r[D] = self.r[B];
                    },
                    // LD D,C
                    0x51 => {
                        self.r[D] = self.r[C];
                    },
                    // LD D,D
                    0x52 => {
                        self.r[D] = self.r[D];
                    },
                    // LD D,E
                    0x53 => {
                        self.r[D] = self.r[E];
                    },
                    // LD D,H
                    0x54 => {
                        self.r[D] = self.r[H + self.rixy];
                    },
                    // LD D,L
                    0x55 => {
                        self.r[D] = self.r[L + self.rixy];
                    },
                    // LD D,(HL)
                    0x56 => {
                        self.step = 0x321;
                        break :next;
                    },
                    // LD D,A
                    0x57 => {
                        self.r[D] = self.r[A];
                    },
                    // LD E,B
                    0x58 => {
                        self.r[E] = self.r[B];
                    },
                    // LD E,C
                    0x59 => {
                        self.r[E] = self.r[C];
                    },
                    // LD E,D
                    0x5A => {
                        self.r[E] = self.r[D];
                    },
                    // LD E,E
                    0x5B => {
                        self.r[E] = self.r[E];
                    },
                    // LD E,H
                    0x5C => {
                        self.r[E] = self.r[H + self.rixy];
                    },
                    // LD E,L
                    0x5D => {
                        self.r[E] = self.r[L + self.rixy];
                    },
                    // LD E,(HL)
                    0x5E => {
                        self.step = 0x324;
                        break :next;
                    },
                    // LD E,A
                    0x5F => {
                        self.r[E] = self.r[A];
                    },
                    // LD H,B
                    0x60 => {
                        self.r[H + self.rixy] = self.r[B];
                    },
                    // LD H,C
                    0x61 => {
                        self.r[H + self.rixy] = self.r[C];
                    },
                    // LD H,D
                    0x62 => {
                        self.r[H + self.rixy] = self.r[D];
                    },
                    // LD H,E
                    0x63 => {
                        self.r[H + self.rixy] = self.r[E];
                    },
                    // LD H,H
                    0x64 => {
                        self.r[H + self.rixy] = self.r[H + self.rixy];
                    },
                    // LD H,L
                    0x65 => {
                        self.r[H + self.rixy] = self.r[L + self.rixy];
                    },
                    // LD H,(HL)
                    0x66 => {
                        self.step = 0x327;
                        break :next;
                    },
                    // LD H,A
                    0x67 => {
                        self.r[H + self.rixy] = self.r[A];
                    },
                    // LD L,B
                    0x68 => {
                        self.r[L + self.rixy] = self.r[B];
                    },
                    // LD L,C
                    0x69 => {
                        self.r[L + self.rixy] = self.r[C];
                    },
                    // LD L,D
                    0x6A => {
                        self.r[L + self.rixy] = self.r[D];
                    },
                    // LD L,E
                    0x6B => {
                        self.r[L + self.rixy] = self.r[E];
                    },
                    // LD L,H
                    0x6C => {
                        self.r[L + self.rixy] = self.r[H + self.rixy];
                    },
                    // LD L,L
                    0x6D => {
                        self.r[L + self.rixy] = self.r[L + self.rixy];
                    },
                    // LD L,(HL)
                    0x6E => {
                        self.step = 0x32A;
                        break :next;
                    },
                    // LD L,A
                    0x6F => {
                        self.r[L + self.rixy] = self.r[A];
                    },
                    // LD (HL),B
                    0x70 => {
                        self.step = 0x32D;
                        break :next;
                    },
                    // LD (HL),C
                    0x71 => {
                        self.step = 0x330;
                        break :next;
                    },
                    // LD (HL),D
                    0x72 => {
                        self.step = 0x333;
                        break :next;
                    },
                    // LD (HL),E
                    0x73 => {
                        self.step = 0x336;
                        break :next;
                    },
                    // LD (HL),H
                    0x74 => {
                        self.step = 0x339;
                        break :next;
                    },
                    // LD (HL),L
                    0x75 => {
                        self.step = 0x33C;
                        break :next;
                    },
                    // HALT
                    0x76 => {
                        bus = self.halt(bus);
                    },
                    // LD (HL),A
                    0x77 => {
                        self.step = 0x33F;
                        break :next;
                    },
                    // LD A,B
                    0x78 => {
                        self.r[A] = self.r[B];
                    },
                    // LD A,C
                    0x79 => {
                        self.r[A] = self.r[C];
                    },
                    // LD A,D
                    0x7A => {
                        self.r[A] = self.r[D];
                    },
                    // LD A,E
                    0x7B => {
                        self.r[A] = self.r[E];
                    },
                    // LD A,H
                    0x7C => {
                        self.r[A] = self.r[H + self.rixy];
                    },
                    // LD A,L
                    0x7D => {
                        self.r[A] = self.r[L + self.rixy];
                    },
                    // LD A,(HL)
                    0x7E => {
                        self.step = 0x342;
                        break :next;
                    },
                    // LD A,A
                    0x7F => {
                        self.r[A] = self.r[A];
                    },
                    // ADD B
                    0x80 => {
                        self.add8(self.r[B]);
                    },
                    // ADD C
                    0x81 => {
                        self.add8(self.r[C]);
                    },
                    // ADD D
                    0x82 => {
                        self.add8(self.r[D]);
                    },
                    // ADD E
                    0x83 => {
                        self.add8(self.r[E]);
                    },
                    // ADD H
                    0x84 => {
                        self.add8(self.r[H + self.rixy]);
                    },
                    // ADD L
                    0x85 => {
                        self.add8(self.r[L + self.rixy]);
                    },
                    // ADD (HL)
                    0x86 => {
                        self.step = 0x345;
                        break :next;
                    },
                    // ADD A
                    0x87 => {
                        self.add8(self.r[A]);
                    },
                    // ADC B
                    0x88 => {
                        self.adc8(self.r[B]);
                    },
                    // ADC C
                    0x89 => {
                        self.adc8(self.r[C]);
                    },
                    // ADC D
                    0x8A => {
                        self.adc8(self.r[D]);
                    },
                    // ADC E
                    0x8B => {
                        self.adc8(self.r[E]);
                    },
                    // ADC H
                    0x8C => {
                        self.adc8(self.r[H + self.rixy]);
                    },
                    // ADC L
                    0x8D => {
                        self.adc8(self.r[L + self.rixy]);
                    },
                    // ADC (HL)
                    0x8E => {
                        self.step = 0x348;
                        break :next;
                    },
                    // ADC A
                    0x8F => {
                        self.adc8(self.r[A]);
                    },
                    // SUB B
                    0x90 => {
                        self.sub8(self.r[B]);
                    },
                    // SUB C
                    0x91 => {
                        self.sub8(self.r[C]);
                    },
                    // SUB D
                    0x92 => {
                        self.sub8(self.r[D]);
                    },
                    // SUB E
                    0x93 => {
                        self.sub8(self.r[E]);
                    },
                    // SUB H
                    0x94 => {
                        self.sub8(self.r[H + self.rixy]);
                    },
                    // SUB L
                    0x95 => {
                        self.sub8(self.r[L + self.rixy]);
                    },
                    // SUB (HL)
                    0x96 => {
                        self.step = 0x34B;
                        break :next;
                    },
                    // SUB A
                    0x97 => {
                        self.sub8(self.r[A]);
                    },
                    // SBC B
                    0x98 => {
                        self.sbc8(self.r[B]);
                    },
                    // SBC C
                    0x99 => {
                        self.sbc8(self.r[C]);
                    },
                    // SBC D
                    0x9A => {
                        self.sbc8(self.r[D]);
                    },
                    // SBC E
                    0x9B => {
                        self.sbc8(self.r[E]);
                    },
                    // SBC H
                    0x9C => {
                        self.sbc8(self.r[H + self.rixy]);
                    },
                    // SBC L
                    0x9D => {
                        self.sbc8(self.r[L + self.rixy]);
                    },
                    // SBC (HL)
                    0x9E => {
                        self.step = 0x34E;
                        break :next;
                    },
                    // SBC A
                    0x9F => {
                        self.sbc8(self.r[A]);
                    },
                    // AND B
                    0xA0 => {
                        self.and8(self.r[B]);
                    },
                    // AND C
                    0xA1 => {
                        self.and8(self.r[C]);
                    },
                    // AND D
                    0xA2 => {
                        self.and8(self.r[D]);
                    },
                    // AND E
                    0xA3 => {
                        self.and8(self.r[E]);
                    },
                    // AND H
                    0xA4 => {
                        self.and8(self.r[H + self.rixy]);
                    },
                    // AND L
                    0xA5 => {
                        self.and8(self.r[L + self.rixy]);
                    },
                    // AND (HL)
                    0xA6 => {
                        self.step = 0x351;
                        break :next;
                    },
                    // AND A
                    0xA7 => {
                        self.and8(self.r[A]);
                    },
                    // XOR B
                    0xA8 => {
                        self.xor8(self.r[B]);
                    },
                    // XOR C
                    0xA9 => {
                        self.xor8(self.r[C]);
                    },
                    // XOR D
                    0xAA => {
                        self.xor8(self.r[D]);
                    },
                    // XOR E
                    0xAB => {
                        self.xor8(self.r[E]);
                    },
                    // XOR H
                    0xAC => {
                        self.xor8(self.r[H + self.rixy]);
                    },
                    // XOR L
                    0xAD => {
                        self.xor8(self.r[L + self.rixy]);
                    },
                    // XOR (HL)
                    0xAE => {
                        self.step = 0x354;
                        break :next;
                    },
                    // XOR A
                    0xAF => {
                        self.xor8(self.r[A]);
                    },
                    // OR B
                    0xB0 => {
                        self.or8(self.r[B]);
                    },
                    // OR C
                    0xB1 => {
                        self.or8(self.r[C]);
                    },
                    // OR D
                    0xB2 => {
                        self.or8(self.r[D]);
                    },
                    // OR E
                    0xB3 => {
                        self.or8(self.r[E]);
                    },
                    // OR H
                    0xB4 => {
                        self.or8(self.r[H + self.rixy]);
                    },
                    // OR L
                    0xB5 => {
                        self.or8(self.r[L + self.rixy]);
                    },
                    // OR (HL)
                    0xB6 => {
                        self.step = 0x357;
                        break :next;
                    },
                    // OR A
                    0xB7 => {
                        self.or8(self.r[A]);
                    },
                    // CP B
                    0xB8 => {
                        self.cp8(self.r[B]);
                    },
                    // CP C
                    0xB9 => {
                        self.cp8(self.r[C]);
                    },
                    // CP D
                    0xBA => {
                        self.cp8(self.r[D]);
                    },
                    // CP E
                    0xBB => {
                        self.cp8(self.r[E]);
                    },
                    // CP H
                    0xBC => {
                        self.cp8(self.r[H + self.rixy]);
                    },
                    // CP L
                    0xBD => {
                        self.cp8(self.r[L + self.rixy]);
                    },
                    // CP (HL)
                    0xBE => {
                        self.step = 0x35A;
                        break :next;
                    },
                    // CP A
                    0xBF => {
                        self.cp8(self.r[A]);
                    },
                    // LD B,n (contined...)
                    0x300 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x301;
                        break :next;
                    },
                    0x301 => {
                        self.r[B] = gd(bus);
                        self.step = 0x302;
                        break :next;
                    },
                    0x302 => {
                    },
                    // LD C,n (contined...)
                    0x303 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x304;
                        break :next;
                    },
                    0x304 => {
                        self.r[C] = gd(bus);
                        self.step = 0x305;
                        break :next;
                    },
                    0x305 => {
                    },
                    // LD D,n (contined...)
                    0x306 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x307;
                        break :next;
                    },
                    0x307 => {
                        self.r[D] = gd(bus);
                        self.step = 0x308;
                        break :next;
                    },
                    0x308 => {
                    },
                    // LD E,n (contined...)
                    0x309 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x30A;
                        break :next;
                    },
                    0x30A => {
                        self.r[E] = gd(bus);
                        self.step = 0x30B;
                        break :next;
                    },
                    0x30B => {
                    },
                    // LD H,n (contined...)
                    0x30C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x30D;
                        break :next;
                    },
                    0x30D => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x30E;
                        break :next;
                    },
                    0x30E => {
                    },
                    // LD L,n (contined...)
                    0x30F => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x310;
                        break :next;
                    },
                    0x310 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x311;
                        break :next;
                    },
                    0x311 => {
                    },
                    // LD (HL),n (contined...)
                    0x312 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%=1;
                        self.step = 0x313;
                        break :next;
                    },
                    0x313 => {
                        self.dlatch = gd(bus);
                        self.step = 0x314;
                        break :next;
                    },
                    0x314 => {
                        self.step = 0x315;
                        break :next;
                    },
                    0x315 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x316;
                        break :next;
                    },
                    0x316 => {
                        self.step = 0x317;
                        break :next;
                    },
                    0x317 => {
                    },
                    // LD A,n (contined...)
                    0x318 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x319;
                        break :next;
                    },
                    0x319 => {
                        self.r[A] = gd(bus);
                        self.step = 0x31A;
                        break :next;
                    },
                    0x31A => {
                    },
                    // LD B,(HL) (contined...)
                    0x31B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x31C;
                        break :next;
                    },
                    0x31C => {
                        self.r[B] = gd(bus);
                        self.step = 0x31D;
                        break :next;
                    },
                    0x31D => {
                    },
                    // LD C,(HL) (contined...)
                    0x31E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x31F;
                        break :next;
                    },
                    0x31F => {
                        self.r[C] = gd(bus);
                        self.step = 0x320;
                        break :next;
                    },
                    0x320 => {
                    },
                    // LD D,(HL) (contined...)
                    0x321 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x322;
                        break :next;
                    },
                    0x322 => {
                        self.r[D] = gd(bus);
                        self.step = 0x323;
                        break :next;
                    },
                    0x323 => {
                    },
                    // LD E,(HL) (contined...)
                    0x324 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x325;
                        break :next;
                    },
                    0x325 => {
                        self.r[E] = gd(bus);
                        self.step = 0x326;
                        break :next;
                    },
                    0x326 => {
                    },
                    // LD H,(HL) (contined...)
                    0x327 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x328;
                        break :next;
                    },
                    0x328 => {
                        self.r[H] = gd(bus);
                        self.step = 0x329;
                        break :next;
                    },
                    0x329 => {
                    },
                    // LD L,(HL) (contined...)
                    0x32A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x32B;
                        break :next;
                    },
                    0x32B => {
                        self.r[L] = gd(bus);
                        self.step = 0x32C;
                        break :next;
                    },
                    0x32C => {
                    },
                    // LD (HL),B (contined...)
                    0x32D => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[B]);
                        self.step = 0x32E;
                        break :next;
                    },
                    0x32E => {
                        self.step = 0x32F;
                        break :next;
                    },
                    0x32F => {
                    },
                    // LD (HL),C (contined...)
                    0x330 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[C]);
                        self.step = 0x331;
                        break :next;
                    },
                    0x331 => {
                        self.step = 0x332;
                        break :next;
                    },
                    0x332 => {
                    },
                    // LD (HL),D (contined...)
                    0x333 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[D]);
                        self.step = 0x334;
                        break :next;
                    },
                    0x334 => {
                        self.step = 0x335;
                        break :next;
                    },
                    0x335 => {
                    },
                    // LD (HL),E (contined...)
                    0x336 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[E]);
                        self.step = 0x337;
                        break :next;
                    },
                    0x337 => {
                        self.step = 0x338;
                        break :next;
                    },
                    0x338 => {
                    },
                    // LD (HL),H (contined...)
                    0x339 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[H]);
                        self.step = 0x33A;
                        break :next;
                    },
                    0x33A => {
                        self.step = 0x33B;
                        break :next;
                    },
                    0x33B => {
                    },
                    // LD (HL),L (contined...)
                    0x33C => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[L]);
                        self.step = 0x33D;
                        break :next;
                    },
                    0x33D => {
                        self.step = 0x33E;
                        break :next;
                    },
                    0x33E => {
                    },
                    // LD (HL),A (contined...)
                    0x33F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[A]);
                        self.step = 0x340;
                        break :next;
                    },
                    0x340 => {
                        self.step = 0x341;
                        break :next;
                    },
                    0x341 => {
                    },
                    // LD A,(HL) (contined...)
                    0x342 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x343;
                        break :next;
                    },
                    0x343 => {
                        self.r[A] = gd(bus);
                        self.step = 0x344;
                        break :next;
                    },
                    0x344 => {
                    },
                    // ADD (HL) (contined...)
                    0x345 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x346;
                        break :next;
                    },
                    0x346 => {
                        self.dlatch = gd(bus);
                        self.step = 0x347;
                        break :next;
                    },
                    0x347 => {
                        self.add8(self.dlatch);
                    },
                    // ADC (HL) (contined...)
                    0x348 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x349;
                        break :next;
                    },
                    0x349 => {
                        self.dlatch = gd(bus);
                        self.step = 0x34A;
                        break :next;
                    },
                    0x34A => {
                        self.adc8(self.dlatch);
                    },
                    // SUB (HL) (contined...)
                    0x34B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x34C;
                        break :next;
                    },
                    0x34C => {
                        self.dlatch = gd(bus);
                        self.step = 0x34D;
                        break :next;
                    },
                    0x34D => {
                        self.sub8(self.dlatch);
                    },
                    // SBC (HL) (contined...)
                    0x34E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x34F;
                        break :next;
                    },
                    0x34F => {
                        self.dlatch = gd(bus);
                        self.step = 0x350;
                        break :next;
                    },
                    0x350 => {
                        self.sbc8(self.dlatch);
                    },
                    // AND (HL) (contined...)
                    0x351 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x352;
                        break :next;
                    },
                    0x352 => {
                        self.dlatch = gd(bus);
                        self.step = 0x353;
                        break :next;
                    },
                    0x353 => {
                        self.and8(self.dlatch);
                    },
                    // XOR (HL) (contined...)
                    0x354 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x355;
                        break :next;
                    },
                    0x355 => {
                        self.dlatch = gd(bus);
                        self.step = 0x356;
                        break :next;
                    },
                    0x356 => {
                        self.xor8(self.dlatch);
                    },
                    // OR (HL) (contined...)
                    0x357 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x358;
                        break :next;
                    },
                    0x358 => {
                        self.dlatch = gd(bus);
                        self.step = 0x359;
                        break :next;
                    },
                    0x359 => {
                        self.or8(self.dlatch);
                    },
                    // CP (HL) (contined...)
                    0x35A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x35B;
                        break :next;
                    },
                    0x35B => {
                        self.dlatch = gd(bus);
                        self.step = 0x35C;
                        break :next;
                    },
                    0x35C => {
                        self.cp8(self.dlatch);
                    },
                    // END DECODE
                    else => unreachable,
                }
                bus = self.fetch(bus);
            }
            // FIXME: track NMI rising edge
            return bus;
        }
        // zig fmt: on
    };
}

//==============================================================================
// ████████ ███████ ███████ ████████ ███████
//    ██    ██      ██         ██    ██
//    ██    █████   ███████    ██    ███████
//    ██    ██           ██    ██         ██
//    ██    ███████ ███████    ██    ███████
//==============================================================================
const expect = std.testing.expect;

test "init" {
    const cpu = Z80(DefaultPins, u64){};
    try expect(cpu.af2 == 0xFFFF);
}

test "tick" {
    const M1 = DefaultPins.M1;
    const MREQ = DefaultPins.MREQ;
    const RD = DefaultPins.RD;
    var cpu = Z80(DefaultPins, u64){};
    const bus = cpu.tick(0);
    try expect(bus == mask(&.{ M1, MREQ, RD }));
}

test "bc" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setBC(0x2345);
    try expect(cpu.r[C] == 0x45);
    try expect(cpu.r[B] == 0x23);
    try expect(cpu.BC() == 0x2345);
}

test "de" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setDE(0x3456);
    try expect(cpu.r[E] == 0x56);
    try expect(cpu.r[D] == 0x34);
    try expect(cpu.DE() == 0x3456);
}

test "hl" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setHL(0x1234);
    try expect(cpu.r[L] == 0x34);
    try expect(cpu.r[H] == 0x12);
    try expect(cpu.HL() == 0x1234);
}

test "ix" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setIX(0x4567);
    try expect(cpu.r[IXL] == 0x67);
    try expect(cpu.r[IXH] == 0x45);
    try expect(cpu.IX() == 0x4567);
}

test "iy" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setIY(0x5678);
    try expect(cpu.r[IYL] == 0x78);
    try expect(cpu.r[IYH] == 0x56);
    try expect(cpu.IY() == 0x5678);
}

test "wz" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setWZ(0x6789);
    try expect(cpu.r[WZL] == 0x89);
    try expect(cpu.r[WZH] == 0x67);
    try expect(cpu.WZ() == 0x6789);
}

test "sp" {
    var cpu = Z80(DefaultPins, u64){};
    cpu.setSP(0x789A);
    try expect(cpu.r[SPL] == 0x9A);
    try expect(cpu.r[SPH] == 0x78);
    try expect(cpu.SP() == 0x789A);
}

test "setAddr" {
    const CPU = Z80(DefaultPins, u64);
    var bus: u64 = 0;
    bus = CPU.setAddr(bus, 0x1234);
    try expect(bus == 0x1234 << 8);
}

test "getAddr" {
    const CPU = Z80(DefaultPins, u64);
    var bus: u64 = 0;
    bus = CPU.setAddr(bus, 0x1234);
    try expect(CPU.getAddr(bus) == 0x1234);
}

test "setAddrData" {
    const CPU = Z80(DefaultPins, u64);
    var bus: u64 = 0;
    bus = CPU.setAddrData(bus, 0x1234, 0x56);
    try expect(bus == 0x123456);
}

test "setData" {
    const CPU = Z80(DefaultPins, u64);
    var bus: u64 = 0;
    bus = CPU.setData(bus, 0x56);
    try expect(bus == 0x56);
}

test "getData" {
    const CPU = Z80(DefaultPins, u64);
    var bus: u64 = 0;
    bus = CPU.setAddrData(bus, 0x1234, 0x56);
    try expect(CPU.getData(bus) == 0x56);
}

test "mrd" {
    const P = DefaultPins;
    const CPU = Z80(P, u64);
    try expect(CPU.mrd(0, 0x1234) == (0x123400 | bit(P.MREQ) | bit(P.RD)));
}

test "mwr" {
    const P = DefaultPins;
    const CPU = Z80(P, u64);
    try expect(CPU.mwr(0, 0x1234, 0x56) == (0x123456 | bit(P.MREQ) | bit(P.WR)));
}

test "wait" {
    const P = DefaultPins;
    const CPU = Z80(P, u64);
    try expect(CPU.wait(0) == false);
    try expect(CPU.wait(bit(P.WAIT)) == true);
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
