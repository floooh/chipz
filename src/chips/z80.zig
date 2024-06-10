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

// lookup table for (HL)/(IX+d)/(IY+d) ops
// FIXME: pack and align?
// zig fmt: off
const indirect_table = init: {
    var initial_value: [256]bool = undefined;
    for(0..256) |i| {
        initial_value[i] = switch (i) {
            0x34, 0x35, 0x36,
            0x46, 0x4E,
            0x56, 0x5E,
            0x66, 0x6E,
            0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x77, 0x7E,
            0x86, 0x8E,
            0x96, 0x9E,
            0xA6, 0xAE,
            0xB6, 0xBE => true,
            else => false,
        };
    }
    break :init initial_value;
};
// zig fmt: on

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

        inline fn skipZero(self: *Self, val: u8, steps: u16) bool {
            if (val == 0) {
                self.step += steps;
                return true;
            } else {
                return false;
            }
        }

        // NOTE: the skipCC funcs are a bit unintuitive, because they skip
        // when the condition is NOT fulfilled
        inline fn skipNZ(self: *Self, steps: u16) bool {
            if ((self.r[F] & ZF) == 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
        }

        inline fn skipZ(self: *Self, steps: u16) bool {
            if ((self.r[F] & ZF) != 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
        }

        inline fn skipNC(self: *Self, steps: u16) bool {
            if ((self.r[F] & CF) == 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
        }

        inline fn skipC(self: *Self, steps: u16) bool {
            if ((self.r[F] & CF) != 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
        }

        inline fn skipPO(self: *Self, steps: u16) bool {
            if ((self.r[F] & PF) == 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
        }

        inline fn skipPE(self: *Self, steps: u16) bool {
            if ((self.r[F] & PF) != 0) {
                return false;
            } else {
                self.steps += steps;
                return true;
            }
        }

        inline fn skipP(self: *Self, steps: u16) bool {
            if ((self.r[F] & SF) == 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
        }

        inline fn skipM(self: *Self, steps: u16) bool {
            if ((self.r[F] & SF) != 0) {
                return false;
            } else {
                self.step += steps;
                return true;
            }
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

        pub inline fn AF(self: *const Self) u16 {
            return self.get16(F);
        }

        pub inline fn setAF(self: *Self, af: u16) void {
            self.set16(F, af);
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

        pub inline fn HLIXY(self: *const Self) u16 {
            return (@as(u16, self.r[H + self.rixy]) << 8) | self.r[L + self.rixy];
        }

        pub inline fn setHLIXY(self: *Self, val: u16) void {
            self.r[L + self.rixy] = @truncate(val);
            self.r[H + self.rixy] = @truncate(val >> 8);
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

        inline fn dimm8(val: u8) u16 {
            return @bitCast(@as(i16, @as(i8, @bitCast(val))));
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

        inline fn fetchDD(self: *Self, bus: Bus) Bus {
            self.rixy = 2;
            self.prefix_active = true;
            self.step = DDFD_M1_T2;
            const out_bus = setAddr(bus, self.pc) | comptime mask(&.{ M1, MREQ, RD });
            self.pc +%= 1;
            return out_bus;
        }

        inline fn fetchFD(self: *Self, bus: Bus) Bus {
            self.rixy = 4;
            self.prefix_active = true;
            self.step = DDFD_M1_T2;
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

        fn inc8(self: *Self, val: u8) u8 {
            const res = val +% 1;
            var f: u8 = szFlags(res) | (res & (XF | YF)) | ((res ^ val) & HF);
            f |= (((val ^ res) & res) >> 5) & VF;
            self.r[F] = f | (self.r[F] & CF);
            return res;
        }

        fn dec8(self: *Self, val: u8) u8 {
            const res = val -% 1;
            var f: u8 = NF | szFlags(res) | (res & (XF | YF)) | ((res ^ val) & HF);
            f |= (((val ^ res) & val) >> 5) & VF;
            self.r[F] = f | (self.r[F] & CF);
            return res;
        }

        fn rlca(self: *Self) void {
            const a = self.r[A];
            const r = (a << 1) | (a >> 7);
            const f = self.r[F];
            self.r[F] = ((a >> 7) & CF) | (f & (SF | ZF | PF)) | (r & (YF | XF));
            self.r[A] = r;
        }

        fn rrca(self: *Self) void {
            const a = self.r[A];
            const r = (a >> 1) | (a << 7);
            const f = self.r[F];
            self.r[F] = (a & CF) | (f & (SF | ZF | PF)) | (r & (YF | XF));
            self.r[A] = r;
        }

        fn rla(self: *Self) void {
            const a = self.r[A];
            const f = self.r[F];
            const r = (a << 1) | (f & CF);
            self.r[F] = ((a >> 7) & CF) | (f & (SF | ZF | PF)) | (r & (YF | XF));
            self.r[A] = r;
        }

        fn rra(self: *Self) void {
            const a = self.r[A];
            const f = self.r[F];
            const r = (a >> 1) | ((f & CF) << 7);
            self.r[F] = (a & CF) | (f & (SF | ZF | PF)) | (r & (YF | XF));
            self.r[A] = r;
        }

        fn daa(self: *Self) void {
            const a = self.r[A];
            var v = a;
            var f = self.r[F];
            if (0 != (f & NF)) {
                if (((a & 0xF) > 0x9) or (0 != (f & HF))) {
                    v -%= 0x06;
                }
                if ((a > 0x99) or (0 != (f & CF))) {
                    v -%= 0x60;
                }
            } else {
                if (((a & 0xF) > 0x9) or (0 != (f & HF))) {
                    v +%= 0x06;
                }
                if ((a > 0x99) or (0 != (f & CF))) {
                    v +%= 0x60;
                }
            }
            f &= CF | NF;
            f |= if (a > 0x99) CF else 0;
            f |= (a ^ v) & HF;
            f |= szpFlags(v);
            self.r[A] = v;
            self.r[F] = f;
        }

        fn cpl(self: *Self) void {
            const a = self.r[A] ^ 0xFF;
            const f = self.r[F];
            self.r[A] = a;
            self.r[F] = HF | NF | (f & (SF | ZF | PF | CF)) | (a & (YF | XF));
        }

        fn scf(self: *Self) void {
            const a = self.r[A];
            const f = self.r[F];
            self.r[F] = CF | (f & (SF | ZF | PF | CF)) | (a & (YF | XF));
        }

        fn ccf(self: *Self) void {
            const a = self.r[A];
            const f = self.r[F];
            self.r[F] = (((f & CF) << 4) | (f & (SF | ZF | PF | CF)) | (a & (YF | XF))) ^ CF;
        }

        fn exafaf2(self: *Self) void {
            const tmp: u16 = self.af2;
            self.af2 = self.AF();
            self.setAF(tmp);
        }

        fn exdehl(self: *Self) void {
            const de = self.DE();
            const hl = self.HL();
            self.setDE(hl);
            self.setHL(de);
        }

        fn exx(self: *Self) void {
            const t0 = self.BC();
            const t1 = self.DE();
            const t2 = self.HL();
            self.setBC(self.bc2);
            self.setDE(self.de2);
            self.setHL(self.hl2);
            self.bc2 = t0;
            self.de2 = t1;
            self.hl2 = t2;
        }

        // BEGIN CONSTS
        const M1_T2: u16 = 0x45B;
        const M1_T3: u16 = 0x45C;
        const M1_T4: u16 = 0x45D;
        const DDFD_M1_T2: u16 = 0x45E;
        const DDFD_M1_T3: u16 = 0x45F;
        const DDFD_M1_T4: u16 = 0x460;
        const DDFD_D_T1: u16 = 0x461;
        const DDFD_D_T2: u16 = 0x462;
        const DDFD_D_T3: u16 = 0x463;
        const DDFD_D_T4: u16 = 0x464;
        const DDFD_D_T5: u16 = 0x465;
        const DDFD_D_T6: u16 = 0x466;
        const DDFD_D_T7: u16 = 0x467;
        const DDFD_D_T8: u16 = 0x468;
        const DDFD_LDHLN_WR_T1: u16 = 0x469;
        const DDFD_LDHLN_WR_T2: u16 = 0x46A;
        const DDFD_LDHLN_WR_T3: u16 = 0x46B;
        const DDFD_LDHLN_OVERLAPPED: u16 = 0x46C;
        // END CONSTS

        // zig fmt: off
        pub fn tick(self: *Self, in_bus: Bus) Bus {
            @setEvalBranchQuota(4096);
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
                    // special fetch machine cycle for DD/FD prefixed ops
                    DDFD_M1_T2 => {
                        if (wait(bus)) break :next;
                        self.opcode = gd(bus);
                        self.step = DDFD_M1_T3;
                        break :next;
                    },
                    DDFD_M1_T3 => {
                        bus = self.refresh(bus);
                        self.step = DDFD_M1_T4;
                        break :next;
                    },
                    DDFD_M1_T4 => {
                        self.step = if (indirect_table[self.opcode]) DDFD_D_T1 else self.opcode;
                        // should we move this into DDFD_D_T1?
                        self.addr = (@as(u16, self.r[H + self.rixy]) << 8) | self.r[L + self.rixy];
                        break :next;
                    },
                    // fallthrough for (IX/IY+d) d-offset loading
                    DDFD_D_T1 => {
                        self.step = DDFD_D_T2;
                        break :next;
                    },
                    DDFD_D_T2 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = DDFD_D_T3;
                        break :next;
                    },
                    DDFD_D_T3 => {
                        self.addr +%= dimm8(gd(bus));
                        self.setWZ(self.addr);
                        self.step = DDFD_D_T4;
                        break :next;
                    },
                    DDFD_D_T4 => {
                        self.step = DDFD_D_T5;
                        break :next;
                    },
                    DDFD_D_T5 => {
                        // special case LD (IX/IY+d),n: load n
                        if (self.opcode == 0x36) {
                            if (wait(bus)) break :next;
                            bus = mrd(bus, self.pc);
                            self.pc +%= 1;
                        }
                        self.step = DDFD_D_T6;
                        break :next;
                    },
                    DDFD_D_T6 => {
                        // special case LD (IX/IY+d),n: load n
                        if (self.opcode == 0x36) {
                            self.dlatch = gd(bus);
                        }
                        self.step = DDFD_D_T7;
                        break :next;
                    },
                    DDFD_D_T7 => {
                        self.step = DDFD_D_T8;
                        break :next;
                    },
                    DDFD_D_T8 => {
                        // special case LD (IX/IY+d),n
                        if (self.opcode == 0x36) {
                            self.step = DDFD_LDHLN_WR_T1;
                        } else {
                            self.step = self.opcode;
                        }
                        break :next;
                    },
                    DDFD_LDHLN_WR_T1 => {
                        // special case LD (IX/IY+d),n write mcycle
                        self.step = DDFD_LDHLN_WR_T2;
                        break :next;
                    },
                    DDFD_LDHLN_WR_T2 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = DDFD_LDHLN_WR_T3;
                        break :next;
                    },
                    DDFD_LDHLN_WR_T3 => {
                        self.step = DDFD_LDHLN_OVERLAPPED;
                        break: next;
                    },
                    DDFD_LDHLN_OVERLAPPED => {
                    },
                    // BEGIN DECODE
                    // NOP
                    0x0 => {
                    },
                    // LD BC,nn
                    0x1 => {
                        self.step = 0x300;
                        break :next;
                    },
                    // LD (BC),A
                    0x2 => {
                        self.step = 0x306;
                        break :next;
                    },
                    // INC BC
                    0x3 => {
                        self.setBC(self.BC() +% 1);
                        self.step = 0x309;
                        break :next;
                    },
                    // INC B
                    0x4 => {
                        self.r[B]=self.inc8(self.r[B]);
                    },
                    // DEC B
                    0x5 => {
                        self.r[B]=self.dec8(self.r[B]);
                    },
                    // LD B,n
                    0x6 => {
                        self.step = 0x30B;
                        break :next;
                    },
                    // RLCA
                    0x7 => {
                        self.rlca();
                    },
                    // EX AF,AF'
                    0x8 => {
                        self.exafaf2();
                    },
                    // LD A,(BC)
                    0xA => {
                        self.step = 0x30E;
                        break :next;
                    },
                    // DEC BC
                    0xB => {
                        self.setBC(self.BC() -% 1);
                        self.step = 0x311;
                        break :next;
                    },
                    // INC C
                    0xC => {
                        self.r[C]=self.inc8(self.r[C]);
                    },
                    // DEC C
                    0xD => {
                        self.r[C]=self.dec8(self.r[C]);
                    },
                    // LD C,n
                    0xE => {
                        self.step = 0x313;
                        break :next;
                    },
                    // RRCA
                    0xF => {
                        self.rrca();
                    },
                    // DJNZ
                    0x10 => {
                        self.r[B] -%= 1;
                        self.step = 0x316;
                        break :next;
                    },
                    // LD DE,nn
                    0x11 => {
                        self.step = 0x31F;
                        break :next;
                    },
                    // LD (DE),A
                    0x12 => {
                        self.step = 0x325;
                        break :next;
                    },
                    // INC DE
                    0x13 => {
                        self.setDE(self.DE() +% 1);
                        self.step = 0x328;
                        break :next;
                    },
                    // INC D
                    0x14 => {
                        self.r[D]=self.inc8(self.r[D]);
                    },
                    // DEC D
                    0x15 => {
                        self.r[D]=self.dec8(self.r[D]);
                    },
                    // LD D,n
                    0x16 => {
                        self.step = 0x32A;
                        break :next;
                    },
                    // RLA
                    0x17 => {
                        self.rla();
                    },
                    // JR d
                    0x18 => {
                        self.step = 0x32D;
                        break :next;
                    },
                    // LD A,(DE)
                    0x1A => {
                        self.step = 0x335;
                        break :next;
                    },
                    // DEC DE
                    0x1B => {
                        self.setDE(self.DE() -% 1);
                        self.step = 0x338;
                        break :next;
                    },
                    // INC E
                    0x1C => {
                        self.r[E]=self.inc8(self.r[E]);
                    },
                    // DEC E
                    0x1D => {
                        self.r[E]=self.dec8(self.r[E]);
                    },
                    // LD E,n
                    0x1E => {
                        self.step = 0x33A;
                        break :next;
                    },
                    // RRA
                    0x1F => {
                        self.rra();
                    },
                    // JR NZ,d
                    0x20 => {
                        self.step = 0x33D;
                        break :next;
                    },
                    // LD HL,nn
                    0x21 => {
                        self.step = 0x345;
                        break :next;
                    },
                    // LD (HL),nn
                    0x22 => {
                        self.step = 0x34B;
                        break :next;
                    },
                    // INC HL
                    0x23 => {
                        self.setHLIXY(self.HLIXY() +% 1);
                        self.step = 0x357;
                        break :next;
                    },
                    // INC H
                    0x24 => {
                        self.r[H + self.rixy]=self.inc8(self.r[H + self.rixy]);
                    },
                    // DEC H
                    0x25 => {
                        self.r[H + self.rixy]=self.dec8(self.r[H + self.rixy]);
                    },
                    // LD H,n
                    0x26 => {
                        self.step = 0x359;
                        break :next;
                    },
                    // DDA
                    0x27 => {
                        self.daa();
                    },
                    // JR Z,d
                    0x28 => {
                        self.step = 0x35C;
                        break :next;
                    },
                    // LD HL,(nn)
                    0x2A => {
                        self.step = 0x364;
                        break :next;
                    },
                    // DEC HL
                    0x2B => {
                        self.setHLIXY(self.HLIXY() -% 1);
                        self.step = 0x370;
                        break :next;
                    },
                    // INC L
                    0x2C => {
                        self.r[L + self.rixy]=self.inc8(self.r[L + self.rixy]);
                    },
                    // DEC L
                    0x2D => {
                        self.r[L + self.rixy]=self.dec8(self.r[L + self.rixy]);
                    },
                    // LD L,n
                    0x2E => {
                        self.step = 0x372;
                        break :next;
                    },
                    // CPL
                    0x2F => {
                        self.cpl();
                    },
                    // JR NC,d
                    0x30 => {
                        self.step = 0x375;
                        break :next;
                    },
                    // LD SP,nn
                    0x31 => {
                        self.step = 0x37D;
                        break :next;
                    },
                    // LD (HL),A
                    0x32 => {
                        self.step = 0x383;
                        break :next;
                    },
                    // INC SP
                    0x33 => {
                        self.setSP(self.SP() +% 1);
                        self.step = 0x38C;
                        break :next;
                    },
                    // INC (HL)
                    0x34 => {
                        self.step = 0x38E;
                        break :next;
                    },
                    // DEC (HL)
                    0x35 => {
                        self.step = 0x395;
                        break :next;
                    },
                    // LD (HL),n
                    0x36 => {
                        self.step = 0x39C;
                        break :next;
                    },
                    // SCF
                    0x37 => {
                        self.scf();
                    },
                    // JR C,d
                    0x38 => {
                        self.step = 0x3A2;
                        break :next;
                    },
                    // LD A,(nn)
                    0x3A => {
                        self.step = 0x3AA;
                        break :next;
                    },
                    // DEC SP
                    0x3B => {
                        self.setSP(self.SP() -% 1);
                        self.step = 0x3B3;
                        break :next;
                    },
                    // INC A
                    0x3C => {
                        self.r[A]=self.inc8(self.r[A]);
                    },
                    // DEC A
                    0x3D => {
                        self.r[A]=self.dec8(self.r[A]);
                    },
                    // LD A,n
                    0x3E => {
                        self.step = 0x3B5;
                        break :next;
                    },
                    // CCF
                    0x3F => {
                        self.ccf();
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
                        self.step = 0x3B8;
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
                        self.step = 0x3BB;
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
                        self.step = 0x3BE;
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
                        self.step = 0x3C1;
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
                        self.step = 0x3C4;
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
                        self.step = 0x3C7;
                        break :next;
                    },
                    // LD L,A
                    0x6F => {
                        self.r[L + self.rixy] = self.r[A];
                    },
                    // LD (HL),B
                    0x70 => {
                        self.step = 0x3CA;
                        break :next;
                    },
                    // LD (HL),C
                    0x71 => {
                        self.step = 0x3CD;
                        break :next;
                    },
                    // LD (HL),D
                    0x72 => {
                        self.step = 0x3D0;
                        break :next;
                    },
                    // LD (HL),E
                    0x73 => {
                        self.step = 0x3D3;
                        break :next;
                    },
                    // LD (HL),H
                    0x74 => {
                        self.step = 0x3D6;
                        break :next;
                    },
                    // LD (HL),L
                    0x75 => {
                        self.step = 0x3D9;
                        break :next;
                    },
                    // HALT
                    0x76 => {
                        bus = self.halt(bus);
                    },
                    // LD (HL),A
                    0x77 => {
                        self.step = 0x3DC;
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
                        self.step = 0x3DF;
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
                        self.step = 0x3E2;
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
                        self.step = 0x3E5;
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
                        self.step = 0x3E8;
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
                        self.step = 0x3EB;
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
                        self.step = 0x3EE;
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
                        self.step = 0x3F1;
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
                        self.step = 0x3F4;
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
                        self.step = 0x3F7;
                        break :next;
                    },
                    // CP A
                    0xBF => {
                        self.cp8(self.r[A]);
                    },
                    // POP BC
                    0xC1 => {
                        self.step = 0x3FA;
                        break :next;
                    },
                    // JP nn
                    0xC3 => {
                        self.step = 0x400;
                        break :next;
                    },
                    // PUSH BC
                    0xC5 => {
                        self.setSP(self.SP() -% 1);
                        self.step = 0x406;
                        break :next;
                    },
                    // ADD n
                    0xC6 => {
                        self.step = 0x40D;
                        break :next;
                    },
                    // ADC n
                    0xCE => {
                        self.step = 0x410;
                        break :next;
                    },
                    // POP DE
                    0xD1 => {
                        self.step = 0x413;
                        break :next;
                    },
                    // PUSH DE
                    0xD5 => {
                        self.setSP(self.SP() -% 1);
                        self.step = 0x419;
                        break :next;
                    },
                    // SUB n
                    0xD6 => {
                        self.step = 0x420;
                        break :next;
                    },
                    // EXX
                    0xD9 => {
                        self.exx();
                    },
                    // DD Prefix
                    0xDD => {
                        bus = self.fetchDD(bus);
                        break :next;
                    },
                    // SBC n
                    0xDE => {
                        self.step = 0x423;
                        break :next;
                    },
                    // POP HL
                    0xE1 => {
                        self.step = 0x426;
                        break :next;
                    },
                    // EX (SP),HL
                    0xE3 => {
                        self.step = 0x42C;
                        break :next;
                    },
                    // PUSH HL
                    0xE5 => {
                        self.setSP(self.SP() -% 1);
                        self.step = 0x43B;
                        break :next;
                    },
                    // AND n
                    0xE6 => {
                        self.step = 0x442;
                        break :next;
                    },
                    // JP HL
                    0xE9 => {
                        self.pc = self.HLIXY();
                    },
                    // EX DE,HL
                    0xEB => {
                        self.exdehl();
                    },
                    // XOR n
                    0xEE => {
                        self.step = 0x445;
                        break :next;
                    },
                    // POP AF
                    0xF1 => {
                        self.step = 0x448;
                        break :next;
                    },
                    // PUSH AF
                    0xF5 => {
                        self.setSP(self.SP() -% 1);
                        self.step = 0x44E;
                        break :next;
                    },
                    // OR n
                    0xF6 => {
                        self.step = 0x455;
                        break :next;
                    },
                    // FD Prefix
                    0xFD => {
                        bus = self.fetchFD(bus);
                        break :next;
                    },
                    // CP n
                    0xFE => {
                        self.step = 0x458;
                        break :next;
                    },
                    // LD BC,nn (continued...)
                    0x300 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x301;
                        break :next;
                    },
                    0x301 => {
                        self.r[C] = gd(bus);
                        self.step = 0x302;
                        break :next;
                    },
                    0x302 => {
                        self.step = 0x303;
                        break :next;
                    },
                    0x303 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x304;
                        break :next;
                    },
                    0x304 => {
                        self.r[B] = gd(bus);
                        self.step = 0x305;
                        break :next;
                    },
                    0x305 => {
                    },
                    // LD (BC),A (continued...)
                    0x306 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.BC(), self.r[A]);
                        self.r[WZL]=self.r[C] +% 1; self.r[WZH]=self.r[A];
                        self.step = 0x307;
                        break :next;
                    },
                    0x307 => {
                        self.step = 0x308;
                        break :next;
                    },
                    0x308 => {
                    },
                    // INC BC (continued...)
                    0x309 => {
                        self.step = 0x30A;
                        break :next;
                    },
                    0x30A => {
                    },
                    // LD B,n (continued...)
                    0x30B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x30C;
                        break :next;
                    },
                    0x30C => {
                        self.r[B] = gd(bus);
                        self.step = 0x30D;
                        break :next;
                    },
                    0x30D => {
                    },
                    // LD A,(BC) (continued...)
                    0x30E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.BC());
                        self.step = 0x30F;
                        break :next;
                    },
                    0x30F => {
                        self.r[A] = gd(bus);
                        self.setWZ(self.BC() +% 1);
                        self.step = 0x310;
                        break :next;
                    },
                    0x310 => {
                    },
                    // DEC BC (continued...)
                    0x311 => {
                        self.step = 0x312;
                        break :next;
                    },
                    0x312 => {
                    },
                    // LD C,n (continued...)
                    0x313 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x314;
                        break :next;
                    },
                    0x314 => {
                        self.r[C] = gd(bus);
                        self.step = 0x315;
                        break :next;
                    },
                    0x315 => {
                    },
                    // DJNZ (continued...)
                    0x316 => {
                        self.step = 0x317;
                        break :next;
                    },
                    0x317 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x318;
                        break :next;
                    },
                    0x318 => {
                        self.dlatch = gd(bus);
                        if (self.skipZero(self.r[B], 6)) break :next;
                        self.step = 0x319;
                        break :next;
                    },
                    0x319 => {
                        self.pc +%= dimm8(self.dlatch);
                        self.setWZ(self.pc);
                        self.step = 0x31A;
                        break :next;
                    },
                    0x31A => {
                        self.step = 0x31B;
                        break :next;
                    },
                    0x31B => {
                        self.step = 0x31C;
                        break :next;
                    },
                    0x31C => {
                        self.step = 0x31D;
                        break :next;
                    },
                    0x31D => {
                        self.step = 0x31E;
                        break :next;
                    },
                    0x31E => {
                    },
                    // LD DE,nn (continued...)
                    0x31F => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x320;
                        break :next;
                    },
                    0x320 => {
                        self.r[E] = gd(bus);
                        self.step = 0x321;
                        break :next;
                    },
                    0x321 => {
                        self.step = 0x322;
                        break :next;
                    },
                    0x322 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x323;
                        break :next;
                    },
                    0x323 => {
                        self.r[D] = gd(bus);
                        self.step = 0x324;
                        break :next;
                    },
                    0x324 => {
                    },
                    // LD (DE),A (continued...)
                    0x325 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.DE(), self.r[A]);
                        self.r[WZL]=self.r[E] +% 1; self.r[WZH]=self.r[A];
                        self.step = 0x326;
                        break :next;
                    },
                    0x326 => {
                        self.step = 0x327;
                        break :next;
                    },
                    0x327 => {
                    },
                    // INC DE (continued...)
                    0x328 => {
                        self.step = 0x329;
                        break :next;
                    },
                    0x329 => {
                    },
                    // LD D,n (continued...)
                    0x32A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x32B;
                        break :next;
                    },
                    0x32B => {
                        self.r[D] = gd(bus);
                        self.step = 0x32C;
                        break :next;
                    },
                    0x32C => {
                    },
                    // JR d (continued...)
                    0x32D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x32E;
                        break :next;
                    },
                    0x32E => {
                        self.dlatch = gd(bus);
                        self.step = 0x32F;
                        break :next;
                    },
                    0x32F => {
                        self.pc +%= dimm8(self.dlatch);
                        self.setWZ(self.pc);
                        self.step = 0x330;
                        break :next;
                    },
                    0x330 => {
                        self.step = 0x331;
                        break :next;
                    },
                    0x331 => {
                        self.step = 0x332;
                        break :next;
                    },
                    0x332 => {
                        self.step = 0x333;
                        break :next;
                    },
                    0x333 => {
                        self.step = 0x334;
                        break :next;
                    },
                    0x334 => {
                    },
                    // LD A,(DE) (continued...)
                    0x335 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.DE());
                        self.step = 0x336;
                        break :next;
                    },
                    0x336 => {
                        self.r[A] = gd(bus);
                        self.setWZ(self.DE() +% 1);
                        self.step = 0x337;
                        break :next;
                    },
                    0x337 => {
                    },
                    // DEC DE (continued...)
                    0x338 => {
                        self.step = 0x339;
                        break :next;
                    },
                    0x339 => {
                    },
                    // LD E,n (continued...)
                    0x33A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x33B;
                        break :next;
                    },
                    0x33B => {
                        self.r[E] = gd(bus);
                        self.step = 0x33C;
                        break :next;
                    },
                    0x33C => {
                    },
                    // JR NZ,d (continued...)
                    0x33D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x33E;
                        break :next;
                    },
                    0x33E => {
                        self.dlatch = gd(bus);
                        if (self.skipNZ(6)) break :next;
                        self.step = 0x33F;
                        break :next;
                    },
                    0x33F => {
                        self.pc +%= dimm8(self.dlatch);
                        self.setWZ(self.pc);
                        self.step = 0x340;
                        break :next;
                    },
                    0x340 => {
                        self.step = 0x341;
                        break :next;
                    },
                    0x341 => {
                        self.step = 0x342;
                        break :next;
                    },
                    0x342 => {
                        self.step = 0x343;
                        break :next;
                    },
                    0x343 => {
                        self.step = 0x344;
                        break :next;
                    },
                    0x344 => {
                    },
                    // LD HL,nn (continued...)
                    0x345 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x346;
                        break :next;
                    },
                    0x346 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x347;
                        break :next;
                    },
                    0x347 => {
                        self.step = 0x348;
                        break :next;
                    },
                    0x348 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x349;
                        break :next;
                    },
                    0x349 => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x34A;
                        break :next;
                    },
                    0x34A => {
                    },
                    // LD (HL),nn (continued...)
                    0x34B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x34C;
                        break :next;
                    },
                    0x34C => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x34D;
                        break :next;
                    },
                    0x34D => {
                        self.step = 0x34E;
                        break :next;
                    },
                    0x34E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x34F;
                        break :next;
                    },
                    0x34F => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x350;
                        break :next;
                    },
                    0x350 => {
                        self.step = 0x351;
                        break :next;
                    },
                    0x351 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.WZ(), self.r[L + self.rixy]);
                        self.setWZ(self.WZ() +% 1);
                        self.step = 0x352;
                        break :next;
                    },
                    0x352 => {
                        self.step = 0x353;
                        break :next;
                    },
                    0x353 => {
                        self.step = 0x354;
                        break :next;
                    },
                    0x354 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.WZ(), self.r[H + self.rixy]);
                        self.step = 0x355;
                        break :next;
                    },
                    0x355 => {
                        self.step = 0x356;
                        break :next;
                    },
                    0x356 => {
                    },
                    // INC HL (continued...)
                    0x357 => {
                        self.step = 0x358;
                        break :next;
                    },
                    0x358 => {
                    },
                    // LD H,n (continued...)
                    0x359 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x35A;
                        break :next;
                    },
                    0x35A => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x35B;
                        break :next;
                    },
                    0x35B => {
                    },
                    // JR Z,d (continued...)
                    0x35C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x35D;
                        break :next;
                    },
                    0x35D => {
                        self.dlatch = gd(bus);
                        if (self.skipZ(6)) break :next;
                        self.step = 0x35E;
                        break :next;
                    },
                    0x35E => {
                        self.pc +%= dimm8(self.dlatch);
                        self.setWZ(self.pc);
                        self.step = 0x35F;
                        break :next;
                    },
                    0x35F => {
                        self.step = 0x360;
                        break :next;
                    },
                    0x360 => {
                        self.step = 0x361;
                        break :next;
                    },
                    0x361 => {
                        self.step = 0x362;
                        break :next;
                    },
                    0x362 => {
                        self.step = 0x363;
                        break :next;
                    },
                    0x363 => {
                    },
                    // LD HL,(nn) (continued...)
                    0x364 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x365;
                        break :next;
                    },
                    0x365 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x366;
                        break :next;
                    },
                    0x366 => {
                        self.step = 0x367;
                        break :next;
                    },
                    0x367 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x368;
                        break :next;
                    },
                    0x368 => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x369;
                        break :next;
                    },
                    0x369 => {
                        self.step = 0x36A;
                        break :next;
                    },
                    0x36A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.WZ());
                        self.setWZ(self.WZ() +% 1);
                        self.step = 0x36B;
                        break :next;
                    },
                    0x36B => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x36C;
                        break :next;
                    },
                    0x36C => {
                        self.step = 0x36D;
                        break :next;
                    },
                    0x36D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.WZ());
                        self.step = 0x36E;
                        break :next;
                    },
                    0x36E => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x36F;
                        break :next;
                    },
                    0x36F => {
                    },
                    // DEC HL (continued...)
                    0x370 => {
                        self.step = 0x371;
                        break :next;
                    },
                    0x371 => {
                    },
                    // LD L,n (continued...)
                    0x372 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x373;
                        break :next;
                    },
                    0x373 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x374;
                        break :next;
                    },
                    0x374 => {
                    },
                    // JR NC,d (continued...)
                    0x375 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x376;
                        break :next;
                    },
                    0x376 => {
                        self.dlatch = gd(bus);
                        if (self.skipNC(6)) break :next;
                        self.step = 0x377;
                        break :next;
                    },
                    0x377 => {
                        self.pc +%= dimm8(self.dlatch);
                        self.setWZ(self.pc);
                        self.step = 0x378;
                        break :next;
                    },
                    0x378 => {
                        self.step = 0x379;
                        break :next;
                    },
                    0x379 => {
                        self.step = 0x37A;
                        break :next;
                    },
                    0x37A => {
                        self.step = 0x37B;
                        break :next;
                    },
                    0x37B => {
                        self.step = 0x37C;
                        break :next;
                    },
                    0x37C => {
                    },
                    // LD SP,nn (continued...)
                    0x37D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x37E;
                        break :next;
                    },
                    0x37E => {
                        self.r[SPL] = gd(bus);
                        self.step = 0x37F;
                        break :next;
                    },
                    0x37F => {
                        self.step = 0x380;
                        break :next;
                    },
                    0x380 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x381;
                        break :next;
                    },
                    0x381 => {
                        self.r[SPH] = gd(bus);
                        self.step = 0x382;
                        break :next;
                    },
                    0x382 => {
                    },
                    // LD (HL),A (continued...)
                    0x383 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x384;
                        break :next;
                    },
                    0x384 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x385;
                        break :next;
                    },
                    0x385 => {
                        self.step = 0x386;
                        break :next;
                    },
                    0x386 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x387;
                        break :next;
                    },
                    0x387 => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x388;
                        break :next;
                    },
                    0x388 => {
                        self.step = 0x389;
                        break :next;
                    },
                    0x389 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.WZ(), self.r[A]);
                        self.setWZ(self.WZ() +% 1); self.r[WZH]=self.r[A];
                        self.step = 0x38A;
                        break :next;
                    },
                    0x38A => {
                        self.step = 0x38B;
                        break :next;
                    },
                    0x38B => {
                    },
                    // INC SP (continued...)
                    0x38C => {
                        self.step = 0x38D;
                        break :next;
                    },
                    0x38D => {
                    },
                    // INC (HL) (continued...)
                    0x38E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x38F;
                        break :next;
                    },
                    0x38F => {
                        self.dlatch = gd(bus);
                        self.step = 0x390;
                        break :next;
                    },
                    0x390 => {
                        self.dlatch=self.inc8(self.dlatch);
                        self.step = 0x391;
                        break :next;
                    },
                    0x391 => {
                        self.step = 0x392;
                        break :next;
                    },
                    0x392 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x393;
                        break :next;
                    },
                    0x393 => {
                        self.step = 0x394;
                        break :next;
                    },
                    0x394 => {
                    },
                    // DEC (HL) (continued...)
                    0x395 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x396;
                        break :next;
                    },
                    0x396 => {
                        self.dlatch = gd(bus);
                        self.step = 0x397;
                        break :next;
                    },
                    0x397 => {
                        self.dlatch=self.dec8(self.dlatch);
                        self.step = 0x398;
                        break :next;
                    },
                    0x398 => {
                        self.step = 0x399;
                        break :next;
                    },
                    0x399 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x39A;
                        break :next;
                    },
                    0x39A => {
                        self.step = 0x39B;
                        break :next;
                    },
                    0x39B => {
                    },
                    // LD (HL),n (continued...)
                    0x39C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x39D;
                        break :next;
                    },
                    0x39D => {
                        self.dlatch = gd(bus);
                        self.step = 0x39E;
                        break :next;
                    },
                    0x39E => {
                        self.step = 0x39F;
                        break :next;
                    },
                    0x39F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x3A0;
                        break :next;
                    },
                    0x3A0 => {
                        self.step = 0x3A1;
                        break :next;
                    },
                    0x3A1 => {
                    },
                    // JR C,d (continued...)
                    0x3A2 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x3A3;
                        break :next;
                    },
                    0x3A3 => {
                        self.dlatch = gd(bus);
                        if (self.skipC(6)) break :next;
                        self.step = 0x3A4;
                        break :next;
                    },
                    0x3A4 => {
                        self.pc +%= dimm8(self.dlatch);
                        self.setWZ(self.pc);
                        self.step = 0x3A5;
                        break :next;
                    },
                    0x3A5 => {
                        self.step = 0x3A6;
                        break :next;
                    },
                    0x3A6 => {
                        self.step = 0x3A7;
                        break :next;
                    },
                    0x3A7 => {
                        self.step = 0x3A8;
                        break :next;
                    },
                    0x3A8 => {
                        self.step = 0x3A9;
                        break :next;
                    },
                    0x3A9 => {
                    },
                    // LD A,(nn) (continued...)
                    0x3AA => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x3AB;
                        break :next;
                    },
                    0x3AB => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x3AC;
                        break :next;
                    },
                    0x3AC => {
                        self.step = 0x3AD;
                        break :next;
                    },
                    0x3AD => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x3AE;
                        break :next;
                    },
                    0x3AE => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x3AF;
                        break :next;
                    },
                    0x3AF => {
                        self.step = 0x3B0;
                        break :next;
                    },
                    0x3B0 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.WZ());
                        self.setWZ(self.WZ() +% 1);
                        self.step = 0x3B1;
                        break :next;
                    },
                    0x3B1 => {
                        self.r[A] = gd(bus);
                        self.step = 0x3B2;
                        break :next;
                    },
                    0x3B2 => {
                    },
                    // DEC SP (continued...)
                    0x3B3 => {
                        self.step = 0x3B4;
                        break :next;
                    },
                    0x3B4 => {
                    },
                    // LD A,n (continued...)
                    0x3B5 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x3B6;
                        break :next;
                    },
                    0x3B6 => {
                        self.r[A] = gd(bus);
                        self.step = 0x3B7;
                        break :next;
                    },
                    0x3B7 => {
                    },
                    // LD B,(HL) (continued...)
                    0x3B8 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3B9;
                        break :next;
                    },
                    0x3B9 => {
                        self.r[B] = gd(bus);
                        self.step = 0x3BA;
                        break :next;
                    },
                    0x3BA => {
                    },
                    // LD C,(HL) (continued...)
                    0x3BB => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3BC;
                        break :next;
                    },
                    0x3BC => {
                        self.r[C] = gd(bus);
                        self.step = 0x3BD;
                        break :next;
                    },
                    0x3BD => {
                    },
                    // LD D,(HL) (continued...)
                    0x3BE => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3BF;
                        break :next;
                    },
                    0x3BF => {
                        self.r[D] = gd(bus);
                        self.step = 0x3C0;
                        break :next;
                    },
                    0x3C0 => {
                    },
                    // LD E,(HL) (continued...)
                    0x3C1 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3C2;
                        break :next;
                    },
                    0x3C2 => {
                        self.r[E] = gd(bus);
                        self.step = 0x3C3;
                        break :next;
                    },
                    0x3C3 => {
                    },
                    // LD H,(HL) (continued...)
                    0x3C4 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3C5;
                        break :next;
                    },
                    0x3C5 => {
                        self.r[H] = gd(bus);
                        self.step = 0x3C6;
                        break :next;
                    },
                    0x3C6 => {
                    },
                    // LD L,(HL) (continued...)
                    0x3C7 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3C8;
                        break :next;
                    },
                    0x3C8 => {
                        self.r[L] = gd(bus);
                        self.step = 0x3C9;
                        break :next;
                    },
                    0x3C9 => {
                    },
                    // LD (HL),B (continued...)
                    0x3CA => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[B]);
                        self.step = 0x3CB;
                        break :next;
                    },
                    0x3CB => {
                        self.step = 0x3CC;
                        break :next;
                    },
                    0x3CC => {
                    },
                    // LD (HL),C (continued...)
                    0x3CD => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[C]);
                        self.step = 0x3CE;
                        break :next;
                    },
                    0x3CE => {
                        self.step = 0x3CF;
                        break :next;
                    },
                    0x3CF => {
                    },
                    // LD (HL),D (continued...)
                    0x3D0 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[D]);
                        self.step = 0x3D1;
                        break :next;
                    },
                    0x3D1 => {
                        self.step = 0x3D2;
                        break :next;
                    },
                    0x3D2 => {
                    },
                    // LD (HL),E (continued...)
                    0x3D3 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[E]);
                        self.step = 0x3D4;
                        break :next;
                    },
                    0x3D4 => {
                        self.step = 0x3D5;
                        break :next;
                    },
                    0x3D5 => {
                    },
                    // LD (HL),H (continued...)
                    0x3D6 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[H]);
                        self.step = 0x3D7;
                        break :next;
                    },
                    0x3D7 => {
                        self.step = 0x3D8;
                        break :next;
                    },
                    0x3D8 => {
                    },
                    // LD (HL),L (continued...)
                    0x3D9 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[L]);
                        self.step = 0x3DA;
                        break :next;
                    },
                    0x3DA => {
                        self.step = 0x3DB;
                        break :next;
                    },
                    0x3DB => {
                    },
                    // LD (HL),A (continued...)
                    0x3DC => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[A]);
                        self.step = 0x3DD;
                        break :next;
                    },
                    0x3DD => {
                        self.step = 0x3DE;
                        break :next;
                    },
                    0x3DE => {
                    },
                    // LD A,(HL) (continued...)
                    0x3DF => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3E0;
                        break :next;
                    },
                    0x3E0 => {
                        self.r[A] = gd(bus);
                        self.step = 0x3E1;
                        break :next;
                    },
                    0x3E1 => {
                    },
                    // ADD (HL) (continued...)
                    0x3E2 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3E3;
                        break :next;
                    },
                    0x3E3 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3E4;
                        break :next;
                    },
                    0x3E4 => {
                        self.add8(self.dlatch);
                    },
                    // ADC (HL) (continued...)
                    0x3E5 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3E6;
                        break :next;
                    },
                    0x3E6 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3E7;
                        break :next;
                    },
                    0x3E7 => {
                        self.adc8(self.dlatch);
                    },
                    // SUB (HL) (continued...)
                    0x3E8 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3E9;
                        break :next;
                    },
                    0x3E9 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3EA;
                        break :next;
                    },
                    0x3EA => {
                        self.sub8(self.dlatch);
                    },
                    // SBC (HL) (continued...)
                    0x3EB => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3EC;
                        break :next;
                    },
                    0x3EC => {
                        self.dlatch = gd(bus);
                        self.step = 0x3ED;
                        break :next;
                    },
                    0x3ED => {
                        self.sbc8(self.dlatch);
                    },
                    // AND (HL) (continued...)
                    0x3EE => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3EF;
                        break :next;
                    },
                    0x3EF => {
                        self.dlatch = gd(bus);
                        self.step = 0x3F0;
                        break :next;
                    },
                    0x3F0 => {
                        self.and8(self.dlatch);
                    },
                    // XOR (HL) (continued...)
                    0x3F1 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3F2;
                        break :next;
                    },
                    0x3F2 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3F3;
                        break :next;
                    },
                    0x3F3 => {
                        self.xor8(self.dlatch);
                    },
                    // OR (HL) (continued...)
                    0x3F4 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3F5;
                        break :next;
                    },
                    0x3F5 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3F6;
                        break :next;
                    },
                    0x3F6 => {
                        self.or8(self.dlatch);
                    },
                    // CP (HL) (continued...)
                    0x3F7 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3F8;
                        break :next;
                    },
                    0x3F8 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3F9;
                        break :next;
                    },
                    0x3F9 => {
                        self.cp8(self.dlatch);
                    },
                    // POP BC (continued...)
                    0x3FA => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x3FB;
                        break :next;
                    },
                    0x3FB => {
                        self.r[C] = gd(bus);
                        self.step = 0x3FC;
                        break :next;
                    },
                    0x3FC => {
                        self.step = 0x3FD;
                        break :next;
                    },
                    0x3FD => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x3FE;
                        break :next;
                    },
                    0x3FE => {
                        self.r[B] = gd(bus);
                        self.step = 0x3FF;
                        break :next;
                    },
                    0x3FF => {
                    },
                    // JP nn (continued...)
                    0x400 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x401;
                        break :next;
                    },
                    0x401 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x402;
                        break :next;
                    },
                    0x402 => {
                        self.step = 0x403;
                        break :next;
                    },
                    0x403 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x404;
                        break :next;
                    },
                    0x404 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x405;
                        break :next;
                    },
                    0x405 => {
                    },
                    // PUSH BC (continued...)
                    0x406 => {
                        self.step = 0x407;
                        break :next;
                    },
                    0x407 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[B]);
                        self.setSP(self.SP() -% 1);
                        self.step = 0x408;
                        break :next;
                    },
                    0x408 => {
                        self.step = 0x409;
                        break :next;
                    },
                    0x409 => {
                        self.step = 0x40A;
                        break :next;
                    },
                    0x40A => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[C]);
                        self.step = 0x40B;
                        break :next;
                    },
                    0x40B => {
                        self.step = 0x40C;
                        break :next;
                    },
                    0x40C => {
                    },
                    // ADD n (continued...)
                    0x40D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x40E;
                        break :next;
                    },
                    0x40E => {
                        self.dlatch = gd(bus);
                        self.step = 0x40F;
                        break :next;
                    },
                    0x40F => {
                        self.add8(self.dlatch);
                    },
                    // ADC n (continued...)
                    0x410 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x411;
                        break :next;
                    },
                    0x411 => {
                        self.dlatch = gd(bus);
                        self.step = 0x412;
                        break :next;
                    },
                    0x412 => {
                        self.adc8(self.dlatch);
                    },
                    // POP DE (continued...)
                    0x413 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x414;
                        break :next;
                    },
                    0x414 => {
                        self.r[E] = gd(bus);
                        self.step = 0x415;
                        break :next;
                    },
                    0x415 => {
                        self.step = 0x416;
                        break :next;
                    },
                    0x416 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x417;
                        break :next;
                    },
                    0x417 => {
                        self.r[D] = gd(bus);
                        self.step = 0x418;
                        break :next;
                    },
                    0x418 => {
                    },
                    // PUSH DE (continued...)
                    0x419 => {
                        self.step = 0x41A;
                        break :next;
                    },
                    0x41A => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[D]);
                        self.setSP(self.SP() -% 1);
                        self.step = 0x41B;
                        break :next;
                    },
                    0x41B => {
                        self.step = 0x41C;
                        break :next;
                    },
                    0x41C => {
                        self.step = 0x41D;
                        break :next;
                    },
                    0x41D => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[E]);
                        self.step = 0x41E;
                        break :next;
                    },
                    0x41E => {
                        self.step = 0x41F;
                        break :next;
                    },
                    0x41F => {
                    },
                    // SUB n (continued...)
                    0x420 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x421;
                        break :next;
                    },
                    0x421 => {
                        self.dlatch = gd(bus);
                        self.step = 0x422;
                        break :next;
                    },
                    0x422 => {
                        self.sub8(self.dlatch);
                    },
                    // SBC n (continued...)
                    0x423 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x424;
                        break :next;
                    },
                    0x424 => {
                        self.dlatch = gd(bus);
                        self.step = 0x425;
                        break :next;
                    },
                    0x425 => {
                        self.sbc8(self.dlatch);
                    },
                    // POP HL (continued...)
                    0x426 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x427;
                        break :next;
                    },
                    0x427 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x428;
                        break :next;
                    },
                    0x428 => {
                        self.step = 0x429;
                        break :next;
                    },
                    0x429 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x42A;
                        break :next;
                    },
                    0x42A => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x42B;
                        break :next;
                    },
                    0x42B => {
                    },
                    // EX (SP),HL (continued...)
                    0x42C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.step = 0x42D;
                        break :next;
                    },
                    0x42D => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x42E;
                        break :next;
                    },
                    0x42E => {
                        self.step = 0x42F;
                        break :next;
                    },
                    0x42F => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP() +% 1);
                        self.step = 0x430;
                        break :next;
                    },
                    0x430 => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x431;
                        break :next;
                    },
                    0x431 => {
                        self.step = 0x432;
                        break :next;
                    },
                    0x432 => {
                        self.step = 0x433;
                        break :next;
                    },
                    0x433 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP() +% 1, self.r[H + self.rixy]);
                        self.step = 0x434;
                        break :next;
                    },
                    0x434 => {
                        self.step = 0x435;
                        break :next;
                    },
                    0x435 => {
                        self.step = 0x436;
                        break :next;
                    },
                    0x436 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[L + self.rixy]);
                        self.setHLIXY(self.WZ());
                        self.step = 0x437;
                        break :next;
                    },
                    0x437 => {
                        self.step = 0x438;
                        break :next;
                    },
                    0x438 => {
                        self.step = 0x439;
                        break :next;
                    },
                    0x439 => {
                        self.step = 0x43A;
                        break :next;
                    },
                    0x43A => {
                    },
                    // PUSH HL (continued...)
                    0x43B => {
                        self.step = 0x43C;
                        break :next;
                    },
                    0x43C => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[H + self.rixy]);
                        self.setSP(self.SP() -% 1);
                        self.step = 0x43D;
                        break :next;
                    },
                    0x43D => {
                        self.step = 0x43E;
                        break :next;
                    },
                    0x43E => {
                        self.step = 0x43F;
                        break :next;
                    },
                    0x43F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[L + self.rixy]);
                        self.step = 0x440;
                        break :next;
                    },
                    0x440 => {
                        self.step = 0x441;
                        break :next;
                    },
                    0x441 => {
                    },
                    // AND n (continued...)
                    0x442 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x443;
                        break :next;
                    },
                    0x443 => {
                        self.dlatch = gd(bus);
                        self.step = 0x444;
                        break :next;
                    },
                    0x444 => {
                        self.and8(self.dlatch);
                    },
                    // XOR n (continued...)
                    0x445 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x446;
                        break :next;
                    },
                    0x446 => {
                        self.dlatch = gd(bus);
                        self.step = 0x447;
                        break :next;
                    },
                    0x447 => {
                        self.xor8(self.dlatch);
                    },
                    // POP AF (continued...)
                    0x448 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x449;
                        break :next;
                    },
                    0x449 => {
                        self.r[F] = gd(bus);
                        self.step = 0x44A;
                        break :next;
                    },
                    0x44A => {
                        self.step = 0x44B;
                        break :next;
                    },
                    0x44B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.setSP(self.SP() +% 1);
                        self.step = 0x44C;
                        break :next;
                    },
                    0x44C => {
                        self.r[A] = gd(bus);
                        self.step = 0x44D;
                        break :next;
                    },
                    0x44D => {
                    },
                    // PUSH AF (continued...)
                    0x44E => {
                        self.step = 0x44F;
                        break :next;
                    },
                    0x44F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[A]);
                        self.setSP(self.SP() -% 1);
                        self.step = 0x450;
                        break :next;
                    },
                    0x450 => {
                        self.step = 0x451;
                        break :next;
                    },
                    0x451 => {
                        self.step = 0x452;
                        break :next;
                    },
                    0x452 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[F]);
                        self.step = 0x453;
                        break :next;
                    },
                    0x453 => {
                        self.step = 0x454;
                        break :next;
                    },
                    0x454 => {
                    },
                    // OR n (continued...)
                    0x455 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x456;
                        break :next;
                    },
                    0x456 => {
                        self.dlatch = gd(bus);
                        self.step = 0x457;
                        break :next;
                    },
                    0x457 => {
                        self.or8(self.dlatch);
                    },
                    // CP n (continued...)
                    0x458 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.pc +%= 1;
                        self.step = 0x459;
                        break :next;
                    },
                    0x459 => {
                        self.dlatch = gd(bus);
                        self.step = 0x45A;
                        break :next;
                    },
                    0x45A => {
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
