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

        inline fn gotoZero(self: *Self, val: u8, comptime next_step: u16) bool {
            if (val == 0) {
                self.step = next_step;
                return true;
            } else {
                return false;
            }
        }

        inline fn testNZ(self: *const Self) bool {
            return (self.r[F] & ZF) == 0;
        }

        inline fn testZ(self: *const Self) bool {
            return (self.r[F] & ZF) != 0;
        }

        inline fn testNC(self: *const Self) bool {
            return (self.r[F] & CF) == 0;
        }

        inline fn testC(self: *const Self) bool {
            return (self.r[F] & CF) != 0;
        }

        inline fn testPO(self: *const Self) bool {
            return (self.r[F] & PF) == 0;
        }

        inline fn testPE(self: *const Self) bool {
            return (self.r[F] & PF) != 0;
        }

        inline fn testP(self: *const Self) bool {
            return (self.r[F] & SF) == 0;
        }

        inline fn testM(self: *const Self) bool {
            return (self.r[F] & SF) != 0;
        }

        // NOTE: the gotoCC funcs are a bit unintuitive, because they jump
        // when the condition is NOT fulfilled
        inline fn gotoNZ(self: *Self, comptime next_step: u16) bool {
            if (self.testNZ()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoZ(self: *Self, comptime next_step: u16) bool {
            if (self.testZ()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoNC(self: *Self, comptime next_step: u16) bool {
            if (self.testNC()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoC(self: *Self, comptime next_step: u16) bool {
            if (self.testC()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoPO(self: *Self, comptime next_step: u16) bool {
            if (self.testPO()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoPE(self: *Self, comptime next_step: u16) bool {
            if (self.testPE()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoP(self: *Self, comptime next_step: u16) bool {
            if (self.testP()) {
                return false;
            } else {
                self.step = next_step;
                return true;
            }
        }

        inline fn gotoM(self: *Self, comptime next_step: u16) bool {
            if (self.testM()) {
                return false;
            } else {
                self.step += next_step;
                return true;
            }
        }

        inline fn incPC(self: *Self) void {
            self.pc +%= 1;
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

        inline fn incWZ(self: *Self) void {
            self.setWZ(self.WZ() +% 1);
        }

        pub inline fn SP(self: *const Self) u16 {
            return self.get16(SPL);
        }

        pub inline fn setSP(self: *Self, sp: u16) void {
            self.set16(SPL, sp);
        }

        inline fn decSP(self: *Self) void {
            self.setSP(self.SP() -% 1);
        }

        inline fn incSP(self: *Self) void {
            self.setSP(self.SP() +% 1);
        }

        inline fn PCH(self: *const Self) u8 {
            return @truncate(self.pc >> 8);
        }

        inline fn PCL(self: *const Self) u8 {
            return @truncate(self.pc);
        }

        pub inline fn I(self: *const Self) u8 {
            return @truncate(self.ir >> 8);
        }

        pub inline fn setI(self: *Self, i: u8) void {
            self.ir = (self.ir & 0x00FF) | (@as(u16, i) << 8);
        }

        pub inline fn R(self: *const Self) u8 {
            return @truncate(self.ir);
        }

        pub inline fn setR(self: *Self, r: u8) void {
            self.ir = (self.ir & 0xFF00) | r;
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

        inline fn iord(bus: Bus, addr: u16) Bus {
            return setAddr(bus, addr) | comptime mask(&.{ IORQ, RD });
        }

        inline fn iowr(bus: Bus, addr: u16, data: u8) Bus {
            return setAddrData(bus, addr, data) | comptime mask(&.{ IORQ, WR });
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

        inline fn fetchED(self: *Self, bus: Bus) Bus {
            self.rixy = 0;
            self.prefix_active = true;
            self.step = ED_M1_T2;
            const out_bus = setAddr(bus, self.pc) | comptime mask(&.{ M1, MREQ, RD });
            self.pc +%= 1;
            return out_bus;
        }

        inline fn fetchCB(self: *Self, bus: Bus) Bus {
            _ = self;
            _ = bus;
            @panic("fetchCB(): implement me!");
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

        inline fn szFlags(val: u8) u8 {
            return if (val != 0) (val & SF) else ZF;
        }

        inline fn szyxchFlags(acc: u9, val: u8, res: u9) u8 {
            return szFlags(trn8(res)) | trn8((res & (YF | XF)) | ((res >> 8) & CF) | ((acc ^ val ^ res) & HF));
        }

        inline fn addFlags(acc: u9, val: u8, res: u9) u8 {
            return szyxchFlags(acc, val, res) | trn8((((val ^ acc ^ 0x80) & (val ^ res)) >> 5) & VF);
        }

        inline fn subFlags(acc: u9, val: u8, res: u9) u8 {
            return NF | szyxchFlags(acc, val, res) | trn8((((val ^ acc) & (res ^ acc)) >> 5) & VF);
        }

        inline fn cpFlags(acc: u9, val: u8, res: u9) u8 {
            return NF | szFlags(trn8(res)) | trn8((val & (YF | XF)) | ((res >> 8) & CF) | ((acc ^ val ^ res) & HF) | ((((val ^ acc) & (res ^ acc)) >> 5) & VF));
        }

        inline fn szpFlags(val: u8) u8 {
            return szFlags(val) | (((@popCount(val) << 2) & PF) ^ PF) | (val & (YF | XF));
        }

        inline fn sziff2Flags(self: *const Self, val: u8) u8 {
            return (self.r[F] & CF) | szFlags(val) | (val & (YF | XF)) | if (self.iff2) PF else @as(u8, 0);
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

        fn add16(self: *Self, val: u16) void {
            const acc = self.HLIXY();
            self.setWZ(acc +% 1);
            const res: u17 = @as(u17, acc) +% val;
            self.setHLIXY(@truncate(res));
            var f: u17 = self.r[F] & (SF | ZF | VF);
            f |= ((acc ^ res ^ val) >> 8) & HF;
            f |= ((res >> 16) & CF) | ((res >> 8) & (YF | XF));
            self.r[F] = @truncate(f);
        }

        // BEGIN CONSTS
        const M1_T2: u16 = 0x5A6;
        const M1_T3: u16 = 0x5A7;
        const M1_T4: u16 = 0x5A8;
        const DDFD_M1_T2: u16 = 0x5A9;
        const DDFD_M1_T3: u16 = 0x5AA;
        const DDFD_M1_T4: u16 = 0x5AB;
        const DDFD_D_T1: u16 = 0x5AC;
        const DDFD_D_T2: u16 = 0x5AD;
        const DDFD_D_T3: u16 = 0x5AE;
        const DDFD_D_T4: u16 = 0x5AF;
        const DDFD_D_T5: u16 = 0x5B0;
        const DDFD_D_T6: u16 = 0x5B1;
        const DDFD_D_T7: u16 = 0x5B2;
        const DDFD_D_T8: u16 = 0x5B3;
        const DDFD_LDHLN_WR_T1: u16 = 0x5B4;
        const DDFD_LDHLN_WR_T2: u16 = 0x5B5;
        const DDFD_LDHLN_WR_T3: u16 = 0x5B6;
        const DDFD_LDHLN_OVERLAPPED: u16 = 0x5B7;
        const ED_M1_T2: u16 = 0x5B8;
        const ED_M1_T3: u16 = 0x5B9;
        const ED_M1_T4: u16 = 0x5BA;
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
                    // fetch machine cycle for ED prefixed ops
                    ED_M1_T2 => {
                        if (wait(bus)) break :next;
                        self.opcode = gd(bus);
                        self.step = ED_M1_T3;
                        break :next;
                    },
                    ED_M1_T3 => {
                        bus = self.refresh(bus);
                        self.step = ED_M1_T4;
                        break :next;
                    },
                    ED_M1_T4 => {
                        self.step = @as(u16, self.opcode) + 0x100;
                        break :next;
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
                    // ADD HL,BC
                    0x9 => {
                        self.add16(self.BC());
                        self.step = 0x30E;
                        break :next;
                    },
                    // LD A,(BC)
                    0xA => {
                        self.step = 0x315;
                        break :next;
                    },
                    // DEC BC
                    0xB => {
                        self.setBC(self.BC() -% 1);
                        self.step = 0x318;
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
                        self.step = 0x31A;
                        break :next;
                    },
                    // RRCA
                    0xF => {
                        self.rrca();
                    },
                    // DJNZ
                    0x10 => {
                        self.r[B] -%= 1;
                        self.step = 0x31D;
                        break :next;
                    },
                    // LD DE,nn
                    0x11 => {
                        self.step = 0x326;
                        break :next;
                    },
                    // LD (DE),A
                    0x12 => {
                        self.step = 0x32C;
                        break :next;
                    },
                    // INC DE
                    0x13 => {
                        self.setDE(self.DE() +% 1);
                        self.step = 0x32F;
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
                        self.step = 0x331;
                        break :next;
                    },
                    // RLA
                    0x17 => {
                        self.rla();
                    },
                    // JR d
                    0x18 => {
                        self.step = 0x334;
                        break :next;
                    },
                    // ADD HL,DE
                    0x19 => {
                        self.add16(self.DE());
                        self.step = 0x33C;
                        break :next;
                    },
                    // LD A,(DE)
                    0x1A => {
                        self.step = 0x343;
                        break :next;
                    },
                    // DEC DE
                    0x1B => {
                        self.setDE(self.DE() -% 1);
                        self.step = 0x346;
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
                        self.step = 0x348;
                        break :next;
                    },
                    // RRA
                    0x1F => {
                        self.rra();
                    },
                    // JR NZ,d
                    0x20 => {
                        self.step = 0x34B;
                        break :next;
                    },
                    // LD HL,nn
                    0x21 => {
                        self.step = 0x353;
                        break :next;
                    },
                    // LD (HL),nn
                    0x22 => {
                        self.step = 0x359;
                        break :next;
                    },
                    // INC HL
                    0x23 => {
                        self.setHLIXY(self.HLIXY() +% 1);
                        self.step = 0x365;
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
                        self.step = 0x367;
                        break :next;
                    },
                    // DDA
                    0x27 => {
                        self.daa();
                    },
                    // JR Z,d
                    0x28 => {
                        self.step = 0x36A;
                        break :next;
                    },
                    // ADD HL,HL
                    0x29 => {
                        self.add16(self.HLIXY());
                        self.step = 0x372;
                        break :next;
                    },
                    // LD HL,(nn)
                    0x2A => {
                        self.step = 0x379;
                        break :next;
                    },
                    // DEC HL
                    0x2B => {
                        self.setHLIXY(self.HLIXY() -% 1);
                        self.step = 0x385;
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
                        self.step = 0x387;
                        break :next;
                    },
                    // CPL
                    0x2F => {
                        self.cpl();
                    },
                    // JR NC,d
                    0x30 => {
                        self.step = 0x38A;
                        break :next;
                    },
                    // LD SP,nn
                    0x31 => {
                        self.step = 0x392;
                        break :next;
                    },
                    // LD (HL),A
                    0x32 => {
                        self.step = 0x398;
                        break :next;
                    },
                    // INC SP
                    0x33 => {
                        self.setSP(self.SP() +% 1);
                        self.step = 0x3A1;
                        break :next;
                    },
                    // INC (HL)
                    0x34 => {
                        self.step = 0x3A3;
                        break :next;
                    },
                    // DEC (HL)
                    0x35 => {
                        self.step = 0x3AA;
                        break :next;
                    },
                    // LD (HL),n
                    0x36 => {
                        self.step = 0x3B1;
                        break :next;
                    },
                    // SCF
                    0x37 => {
                        self.scf();
                    },
                    // JR C,d
                    0x38 => {
                        self.step = 0x3B7;
                        break :next;
                    },
                    // ADD HL,SP
                    0x39 => {
                        self.add16(self.SP());
                        self.step = 0x3BF;
                        break :next;
                    },
                    // LD A,(nn)
                    0x3A => {
                        self.step = 0x3C6;
                        break :next;
                    },
                    // DEC SP
                    0x3B => {
                        self.setSP(self.SP() -% 1);
                        self.step = 0x3CF;
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
                        self.step = 0x3D1;
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
                        self.step = 0x3D4;
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
                        self.step = 0x3D7;
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
                        self.step = 0x3DA;
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
                        self.step = 0x3DD;
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
                        self.step = 0x3E0;
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
                        self.step = 0x3E3;
                        break :next;
                    },
                    // LD L,A
                    0x6F => {
                        self.r[L + self.rixy] = self.r[A];
                    },
                    // LD (HL),B
                    0x70 => {
                        self.step = 0x3E6;
                        break :next;
                    },
                    // LD (HL),C
                    0x71 => {
                        self.step = 0x3E9;
                        break :next;
                    },
                    // LD (HL),D
                    0x72 => {
                        self.step = 0x3EC;
                        break :next;
                    },
                    // LD (HL),E
                    0x73 => {
                        self.step = 0x3EF;
                        break :next;
                    },
                    // LD (HL),H
                    0x74 => {
                        self.step = 0x3F2;
                        break :next;
                    },
                    // LD (HL),L
                    0x75 => {
                        self.step = 0x3F5;
                        break :next;
                    },
                    // HALT
                    0x76 => {
                        bus = self.halt(bus);
                    },
                    // LD (HL),A
                    0x77 => {
                        self.step = 0x3F8;
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
                        self.step = 0x3FB;
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
                        self.step = 0x3FE;
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
                        self.step = 0x401;
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
                        self.step = 0x404;
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
                        self.step = 0x407;
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
                        self.step = 0x40A;
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
                        self.step = 0x40D;
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
                        self.step = 0x410;
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
                        self.step = 0x413;
                        break :next;
                    },
                    // CP A
                    0xBF => {
                        self.cp8(self.r[A]);
                    },
                    // RET NZ
                    0xC0 => {
                        if (self.gotoNZ(0x416 + 6)) break :next;
                        self.step = 0x416;
                        break :next;
                    },
                    // POP BC
                    0xC1 => {
                        self.step = 0x41D;
                        break :next;
                    },
                    // JP NZ,nn
                    0xC2 => {
                        self.step = 0x423;
                        break :next;
                    },
                    // JP nn
                    0xC3 => {
                        self.step = 0x429;
                        break :next;
                    },
                    // CALL NZ,nn
                    0xC4 => {
                        self.step = 0x42F;
                        break :next;
                    },
                    // PUSH BC
                    0xC5 => {
                        self.decSP();
                        self.step = 0x43C;
                        break :next;
                    },
                    // ADD n
                    0xC6 => {
                        self.step = 0x443;
                        break :next;
                    },
                    // RST 0
                    0xC7 => {
                        self.decSP();
                        self.step = 0x446;
                        break :next;
                    },
                    // RET Z
                    0xC8 => {
                        if (self.gotoZ(0x44D + 6)) break :next;
                        self.step = 0x44D;
                        break :next;
                    },
                    // RET
                    0xC9 => {
                        self.step = 0x454;
                        break :next;
                    },
                    // JP Z,nn
                    0xCA => {
                        self.step = 0x45A;
                        break :next;
                    },
                    // CB Prefix
                    0xCB => {
                        bus = self.fetchCB(bus);
                        break :next;
                    },
                    // CALL Z,nn
                    0xCC => {
                        self.step = 0x460;
                        break :next;
                    },
                    // CALL nn
                    0xCD => {
                        self.step = 0x46D;
                        break :next;
                    },
                    // ADC n
                    0xCE => {
                        self.step = 0x47A;
                        break :next;
                    },
                    // RST 8
                    0xCF => {
                        self.decSP();
                        self.step = 0x47D;
                        break :next;
                    },
                    // RET NC
                    0xD0 => {
                        if (self.gotoNC(0x484 + 6)) break :next;
                        self.step = 0x484;
                        break :next;
                    },
                    // POP DE
                    0xD1 => {
                        self.step = 0x48B;
                        break :next;
                    },
                    // JP NC,nn
                    0xD2 => {
                        self.step = 0x491;
                        break :next;
                    },
                    // OUT (n),A
                    0xD3 => {
                        self.step = 0x497;
                        break :next;
                    },
                    // CALL NC,nn
                    0xD4 => {
                        self.step = 0x49E;
                        break :next;
                    },
                    // PUSH DE
                    0xD5 => {
                        self.decSP();
                        self.step = 0x4AB;
                        break :next;
                    },
                    // SUB n
                    0xD6 => {
                        self.step = 0x4B2;
                        break :next;
                    },
                    // RST 10
                    0xD7 => {
                        self.decSP();
                        self.step = 0x4B5;
                        break :next;
                    },
                    // RET C
                    0xD8 => {
                        if (self.gotoC(0x4BC + 6)) break :next;
                        self.step = 0x4BC;
                        break :next;
                    },
                    // EXX
                    0xD9 => {
                        self.exx();
                    },
                    // JP C,nn
                    0xDA => {
                        self.step = 0x4C3;
                        break :next;
                    },
                    // IN A,(n)
                    0xDB => {
                        self.step = 0x4C9;
                        break :next;
                    },
                    // CALL C,nn
                    0xDC => {
                        self.step = 0x4D0;
                        break :next;
                    },
                    // DD Prefix
                    0xDD => {
                        bus = self.fetchDD(bus);
                        break :next;
                    },
                    // SBC n
                    0xDE => {
                        self.step = 0x4DD;
                        break :next;
                    },
                    // RST 18
                    0xDF => {
                        self.decSP();
                        self.step = 0x4E0;
                        break :next;
                    },
                    // RET PO
                    0xE0 => {
                        if (self.gotoPO(0x4E7 + 6)) break :next;
                        self.step = 0x4E7;
                        break :next;
                    },
                    // POP HL
                    0xE1 => {
                        self.step = 0x4EE;
                        break :next;
                    },
                    // JP PO,nn
                    0xE2 => {
                        self.step = 0x4F4;
                        break :next;
                    },
                    // EX (SP),HL
                    0xE3 => {
                        self.step = 0x4FA;
                        break :next;
                    },
                    // CALL PO,nn
                    0xE4 => {
                        self.step = 0x509;
                        break :next;
                    },
                    // PUSH HL
                    0xE5 => {
                        self.decSP();
                        self.step = 0x516;
                        break :next;
                    },
                    // AND n
                    0xE6 => {
                        self.step = 0x51D;
                        break :next;
                    },
                    // RST 20
                    0xE7 => {
                        self.decSP();
                        self.step = 0x520;
                        break :next;
                    },
                    // RET PE
                    0xE8 => {
                        if (self.gotoPE(0x527 + 6)) break :next;
                        self.step = 0x527;
                        break :next;
                    },
                    // JP HL
                    0xE9 => {
                        self.pc = self.HLIXY();
                    },
                    // JP PE,nn
                    0xEA => {
                        self.step = 0x52E;
                        break :next;
                    },
                    // EX DE,HL
                    0xEB => {
                        self.exdehl();
                    },
                    // CALL PE,nn
                    0xEC => {
                        self.step = 0x534;
                        break :next;
                    },
                    // ED Prefix
                    0xED => {
                        bus = self.fetchED(bus);
                        break :next;
                    },
                    // XOR n
                    0xEE => {
                        self.step = 0x541;
                        break :next;
                    },
                    // RST 28
                    0xEF => {
                        self.decSP();
                        self.step = 0x544;
                        break :next;
                    },
                    // RET P
                    0xF0 => {
                        if (self.gotoP(0x54B + 6)) break :next;
                        self.step = 0x54B;
                        break :next;
                    },
                    // POP AF
                    0xF1 => {
                        self.step = 0x552;
                        break :next;
                    },
                    // JP P,nn
                    0xF2 => {
                        self.step = 0x558;
                        break :next;
                    },
                    // DI
                    0xF3 => {
                        self.iff1 = false; self.iff2 = false;
                    },
                    // CALL P,nn
                    0xF4 => {
                        self.step = 0x55E;
                        break :next;
                    },
                    // PUSH AF
                    0xF5 => {
                        self.decSP();
                        self.step = 0x56B;
                        break :next;
                    },
                    // OR n
                    0xF6 => {
                        self.step = 0x572;
                        break :next;
                    },
                    // RST 30
                    0xF7 => {
                        self.decSP();
                        self.step = 0x575;
                        break :next;
                    },
                    // RET M
                    0xF8 => {
                        if (self.gotoM(0x57C + 6)) break :next;
                        self.step = 0x57C;
                        break :next;
                    },
                    // LD SP,HL
                    0xF9 => {
                        self.setSP(self.HLIXY());
                        self.step = 0x583;
                        break :next;
                    },
                    // JP M,nn
                    0xFA => {
                        self.step = 0x585;
                        break :next;
                    },
                    // EI
                    0xFB => {
                        self.iff1 = false; self.iff2 = false; bus = self.fetch(bus); self.iff1 = true; self.iff2 = true;
                        break :next;
                    },
                    // CALL M,nn
                    0xFC => {
                        self.step = 0x58B;
                        break :next;
                    },
                    // FD Prefix
                    0xFD => {
                        bus = self.fetchFD(bus);
                        break :next;
                    },
                    // CP n
                    0xFE => {
                        self.step = 0x598;
                        break :next;
                    },
                    // RST 38
                    0xFF => {
                        self.decSP();
                        self.step = 0x59B;
                        break :next;
                    },
                    // LD I,A
                    0x147 => {
                        self.step = 0x5A2;
                        break :next;
                    },
                    // LD R,A
                    0x14F => {
                        self.step = 0x5A3;
                        break :next;
                    },
                    // LD A,I
                    0x157 => {
                        self.step = 0x5A4;
                        break :next;
                    },
                    // LD A,R
                    0x15F => {
                        self.step = 0x5A5;
                        break :next;
                    },
                    // LD BC,nn (continued...)
                    0x300 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
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
                        self.incPC();
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
                        self.incPC();
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
                    // ADD HL,BC (continued...)
                    0x30E => {
                        self.step = 0x30F;
                        break :next;
                    },
                    0x30F => {
                        self.step = 0x310;
                        break :next;
                    },
                    0x310 => {
                        self.step = 0x311;
                        break :next;
                    },
                    0x311 => {
                        self.step = 0x312;
                        break :next;
                    },
                    0x312 => {
                        self.step = 0x313;
                        break :next;
                    },
                    0x313 => {
                        self.step = 0x314;
                        break :next;
                    },
                    0x314 => {
                    },
                    // LD A,(BC) (continued...)
                    0x315 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.BC());
                        self.step = 0x316;
                        break :next;
                    },
                    0x316 => {
                        self.r[A] = gd(bus);
                        self.setWZ(self.BC() +% 1);
                        self.step = 0x317;
                        break :next;
                    },
                    0x317 => {
                    },
                    // DEC BC (continued...)
                    0x318 => {
                        self.step = 0x319;
                        break :next;
                    },
                    0x319 => {
                    },
                    // LD C,n (continued...)
                    0x31A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x31B;
                        break :next;
                    },
                    0x31B => {
                        self.r[C] = gd(bus);
                        self.step = 0x31C;
                        break :next;
                    },
                    0x31C => {
                    },
                    // DJNZ (continued...)
                    0x31D => {
                        self.step = 0x31E;
                        break :next;
                    },
                    0x31E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x31F;
                        break :next;
                    },
                    0x31F => {
                        self.dlatch = gd(bus);
                        if (self.gotoZero(self.r[B], 0x320 + 5)) break :next;
                        self.step = 0x320;
                        break :next;
                    },
                    0x320 => {
                        self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc);
                        self.step = 0x321;
                        break :next;
                    },
                    0x321 => {
                        self.step = 0x322;
                        break :next;
                    },
                    0x322 => {
                        self.step = 0x323;
                        break :next;
                    },
                    0x323 => {
                        self.step = 0x324;
                        break :next;
                    },
                    0x324 => {
                        self.step = 0x325;
                        break :next;
                    },
                    0x325 => {
                    },
                    // LD DE,nn (continued...)
                    0x326 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x327;
                        break :next;
                    },
                    0x327 => {
                        self.r[E] = gd(bus);
                        self.step = 0x328;
                        break :next;
                    },
                    0x328 => {
                        self.step = 0x329;
                        break :next;
                    },
                    0x329 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x32A;
                        break :next;
                    },
                    0x32A => {
                        self.r[D] = gd(bus);
                        self.step = 0x32B;
                        break :next;
                    },
                    0x32B => {
                    },
                    // LD (DE),A (continued...)
                    0x32C => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.DE(), self.r[A]);
                        self.r[WZL]=self.r[E] +% 1; self.r[WZH]=self.r[A];
                        self.step = 0x32D;
                        break :next;
                    },
                    0x32D => {
                        self.step = 0x32E;
                        break :next;
                    },
                    0x32E => {
                    },
                    // INC DE (continued...)
                    0x32F => {
                        self.step = 0x330;
                        break :next;
                    },
                    0x330 => {
                    },
                    // LD D,n (continued...)
                    0x331 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x332;
                        break :next;
                    },
                    0x332 => {
                        self.r[D] = gd(bus);
                        self.step = 0x333;
                        break :next;
                    },
                    0x333 => {
                    },
                    // JR d (continued...)
                    0x334 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x335;
                        break :next;
                    },
                    0x335 => {
                        self.dlatch = gd(bus);
                        self.step = 0x336;
                        break :next;
                    },
                    0x336 => {
                        self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc);
                        self.step = 0x337;
                        break :next;
                    },
                    0x337 => {
                        self.step = 0x338;
                        break :next;
                    },
                    0x338 => {
                        self.step = 0x339;
                        break :next;
                    },
                    0x339 => {
                        self.step = 0x33A;
                        break :next;
                    },
                    0x33A => {
                        self.step = 0x33B;
                        break :next;
                    },
                    0x33B => {
                    },
                    // ADD HL,DE (continued...)
                    0x33C => {
                        self.step = 0x33D;
                        break :next;
                    },
                    0x33D => {
                        self.step = 0x33E;
                        break :next;
                    },
                    0x33E => {
                        self.step = 0x33F;
                        break :next;
                    },
                    0x33F => {
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
                    },
                    // LD A,(DE) (continued...)
                    0x343 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.DE());
                        self.step = 0x344;
                        break :next;
                    },
                    0x344 => {
                        self.r[A] = gd(bus);
                        self.setWZ(self.DE() +% 1);
                        self.step = 0x345;
                        break :next;
                    },
                    0x345 => {
                    },
                    // DEC DE (continued...)
                    0x346 => {
                        self.step = 0x347;
                        break :next;
                    },
                    0x347 => {
                    },
                    // LD E,n (continued...)
                    0x348 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x349;
                        break :next;
                    },
                    0x349 => {
                        self.r[E] = gd(bus);
                        self.step = 0x34A;
                        break :next;
                    },
                    0x34A => {
                    },
                    // JR NZ,d (continued...)
                    0x34B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x34C;
                        break :next;
                    },
                    0x34C => {
                        self.dlatch = gd(bus);
                        if (self.gotoNZ(0x34D + 5)) break :next;
                        self.step = 0x34D;
                        break :next;
                    },
                    0x34D => {
                        self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc);
                        self.step = 0x34E;
                        break :next;
                    },
                    0x34E => {
                        self.step = 0x34F;
                        break :next;
                    },
                    0x34F => {
                        self.step = 0x350;
                        break :next;
                    },
                    0x350 => {
                        self.step = 0x351;
                        break :next;
                    },
                    0x351 => {
                        self.step = 0x352;
                        break :next;
                    },
                    0x352 => {
                    },
                    // LD HL,nn (continued...)
                    0x353 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x354;
                        break :next;
                    },
                    0x354 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x355;
                        break :next;
                    },
                    0x355 => {
                        self.step = 0x356;
                        break :next;
                    },
                    0x356 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x357;
                        break :next;
                    },
                    0x357 => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x358;
                        break :next;
                    },
                    0x358 => {
                    },
                    // LD (HL),nn (continued...)
                    0x359 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x35A;
                        break :next;
                    },
                    0x35A => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x35B;
                        break :next;
                    },
                    0x35B => {
                        self.step = 0x35C;
                        break :next;
                    },
                    0x35C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x35D;
                        break :next;
                    },
                    0x35D => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x35E;
                        break :next;
                    },
                    0x35E => {
                        self.step = 0x35F;
                        break :next;
                    },
                    0x35F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.WZ(), self.r[L + self.rixy]);
                        self.incWZ();
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
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.WZ(), self.r[H + self.rixy]);
                        self.step = 0x363;
                        break :next;
                    },
                    0x363 => {
                        self.step = 0x364;
                        break :next;
                    },
                    0x364 => {
                    },
                    // INC HL (continued...)
                    0x365 => {
                        self.step = 0x366;
                        break :next;
                    },
                    0x366 => {
                    },
                    // LD H,n (continued...)
                    0x367 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x368;
                        break :next;
                    },
                    0x368 => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x369;
                        break :next;
                    },
                    0x369 => {
                    },
                    // JR Z,d (continued...)
                    0x36A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x36B;
                        break :next;
                    },
                    0x36B => {
                        self.dlatch = gd(bus);
                        if (self.gotoZ(0x36C + 5)) break :next;
                        self.step = 0x36C;
                        break :next;
                    },
                    0x36C => {
                        self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc);
                        self.step = 0x36D;
                        break :next;
                    },
                    0x36D => {
                        self.step = 0x36E;
                        break :next;
                    },
                    0x36E => {
                        self.step = 0x36F;
                        break :next;
                    },
                    0x36F => {
                        self.step = 0x370;
                        break :next;
                    },
                    0x370 => {
                        self.step = 0x371;
                        break :next;
                    },
                    0x371 => {
                    },
                    // ADD HL,HL (continued...)
                    0x372 => {
                        self.step = 0x373;
                        break :next;
                    },
                    0x373 => {
                        self.step = 0x374;
                        break :next;
                    },
                    0x374 => {
                        self.step = 0x375;
                        break :next;
                    },
                    0x375 => {
                        self.step = 0x376;
                        break :next;
                    },
                    0x376 => {
                        self.step = 0x377;
                        break :next;
                    },
                    0x377 => {
                        self.step = 0x378;
                        break :next;
                    },
                    0x378 => {
                    },
                    // LD HL,(nn) (continued...)
                    0x379 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x37A;
                        break :next;
                    },
                    0x37A => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x37B;
                        break :next;
                    },
                    0x37B => {
                        self.step = 0x37C;
                        break :next;
                    },
                    0x37C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x37D;
                        break :next;
                    },
                    0x37D => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x37E;
                        break :next;
                    },
                    0x37E => {
                        self.step = 0x37F;
                        break :next;
                    },
                    0x37F => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.WZ());
                        self.incWZ();
                        self.step = 0x380;
                        break :next;
                    },
                    0x380 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x381;
                        break :next;
                    },
                    0x381 => {
                        self.step = 0x382;
                        break :next;
                    },
                    0x382 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.WZ());
                        self.step = 0x383;
                        break :next;
                    },
                    0x383 => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x384;
                        break :next;
                    },
                    0x384 => {
                    },
                    // DEC HL (continued...)
                    0x385 => {
                        self.step = 0x386;
                        break :next;
                    },
                    0x386 => {
                    },
                    // LD L,n (continued...)
                    0x387 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x388;
                        break :next;
                    },
                    0x388 => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x389;
                        break :next;
                    },
                    0x389 => {
                    },
                    // JR NC,d (continued...)
                    0x38A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x38B;
                        break :next;
                    },
                    0x38B => {
                        self.dlatch = gd(bus);
                        if (self.gotoNC(0x38C + 5)) break :next;
                        self.step = 0x38C;
                        break :next;
                    },
                    0x38C => {
                        self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc);
                        self.step = 0x38D;
                        break :next;
                    },
                    0x38D => {
                        self.step = 0x38E;
                        break :next;
                    },
                    0x38E => {
                        self.step = 0x38F;
                        break :next;
                    },
                    0x38F => {
                        self.step = 0x390;
                        break :next;
                    },
                    0x390 => {
                        self.step = 0x391;
                        break :next;
                    },
                    0x391 => {
                    },
                    // LD SP,nn (continued...)
                    0x392 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x393;
                        break :next;
                    },
                    0x393 => {
                        self.r[SPL] = gd(bus);
                        self.step = 0x394;
                        break :next;
                    },
                    0x394 => {
                        self.step = 0x395;
                        break :next;
                    },
                    0x395 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x396;
                        break :next;
                    },
                    0x396 => {
                        self.r[SPH] = gd(bus);
                        self.step = 0x397;
                        break :next;
                    },
                    0x397 => {
                    },
                    // LD (HL),A (continued...)
                    0x398 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x399;
                        break :next;
                    },
                    0x399 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x39A;
                        break :next;
                    },
                    0x39A => {
                        self.step = 0x39B;
                        break :next;
                    },
                    0x39B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x39C;
                        break :next;
                    },
                    0x39C => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x39D;
                        break :next;
                    },
                    0x39D => {
                        self.step = 0x39E;
                        break :next;
                    },
                    0x39E => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.WZ(), self.r[A]);
                        self.incWZ(); self.r[WZH]=self.r[A];
                        self.step = 0x39F;
                        break :next;
                    },
                    0x39F => {
                        self.step = 0x3A0;
                        break :next;
                    },
                    0x3A0 => {
                    },
                    // INC SP (continued...)
                    0x3A1 => {
                        self.step = 0x3A2;
                        break :next;
                    },
                    0x3A2 => {
                    },
                    // INC (HL) (continued...)
                    0x3A3 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3A4;
                        break :next;
                    },
                    0x3A4 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3A5;
                        break :next;
                    },
                    0x3A5 => {
                        self.dlatch=self.inc8(self.dlatch);
                        self.step = 0x3A6;
                        break :next;
                    },
                    0x3A6 => {
                        self.step = 0x3A7;
                        break :next;
                    },
                    0x3A7 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x3A8;
                        break :next;
                    },
                    0x3A8 => {
                        self.step = 0x3A9;
                        break :next;
                    },
                    0x3A9 => {
                    },
                    // DEC (HL) (continued...)
                    0x3AA => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3AB;
                        break :next;
                    },
                    0x3AB => {
                        self.dlatch = gd(bus);
                        self.step = 0x3AC;
                        break :next;
                    },
                    0x3AC => {
                        self.dlatch=self.dec8(self.dlatch);
                        self.step = 0x3AD;
                        break :next;
                    },
                    0x3AD => {
                        self.step = 0x3AE;
                        break :next;
                    },
                    0x3AE => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x3AF;
                        break :next;
                    },
                    0x3AF => {
                        self.step = 0x3B0;
                        break :next;
                    },
                    0x3B0 => {
                    },
                    // LD (HL),n (continued...)
                    0x3B1 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x3B2;
                        break :next;
                    },
                    0x3B2 => {
                        self.dlatch = gd(bus);
                        self.step = 0x3B3;
                        break :next;
                    },
                    0x3B3 => {
                        self.step = 0x3B4;
                        break :next;
                    },
                    0x3B4 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.dlatch);
                        self.step = 0x3B5;
                        break :next;
                    },
                    0x3B5 => {
                        self.step = 0x3B6;
                        break :next;
                    },
                    0x3B6 => {
                    },
                    // JR C,d (continued...)
                    0x3B7 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x3B8;
                        break :next;
                    },
                    0x3B8 => {
                        self.dlatch = gd(bus);
                        if (self.gotoC(0x3B9 + 5)) break :next;
                        self.step = 0x3B9;
                        break :next;
                    },
                    0x3B9 => {
                        self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc);
                        self.step = 0x3BA;
                        break :next;
                    },
                    0x3BA => {
                        self.step = 0x3BB;
                        break :next;
                    },
                    0x3BB => {
                        self.step = 0x3BC;
                        break :next;
                    },
                    0x3BC => {
                        self.step = 0x3BD;
                        break :next;
                    },
                    0x3BD => {
                        self.step = 0x3BE;
                        break :next;
                    },
                    0x3BE => {
                    },
                    // ADD HL,SP (continued...)
                    0x3BF => {
                        self.step = 0x3C0;
                        break :next;
                    },
                    0x3C0 => {
                        self.step = 0x3C1;
                        break :next;
                    },
                    0x3C1 => {
                        self.step = 0x3C2;
                        break :next;
                    },
                    0x3C2 => {
                        self.step = 0x3C3;
                        break :next;
                    },
                    0x3C3 => {
                        self.step = 0x3C4;
                        break :next;
                    },
                    0x3C4 => {
                        self.step = 0x3C5;
                        break :next;
                    },
                    0x3C5 => {
                    },
                    // LD A,(nn) (continued...)
                    0x3C6 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x3C7;
                        break :next;
                    },
                    0x3C7 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x3C8;
                        break :next;
                    },
                    0x3C8 => {
                        self.step = 0x3C9;
                        break :next;
                    },
                    0x3C9 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x3CA;
                        break :next;
                    },
                    0x3CA => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x3CB;
                        break :next;
                    },
                    0x3CB => {
                        self.step = 0x3CC;
                        break :next;
                    },
                    0x3CC => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.WZ());
                        self.incWZ();
                        self.step = 0x3CD;
                        break :next;
                    },
                    0x3CD => {
                        self.r[A] = gd(bus);
                        self.step = 0x3CE;
                        break :next;
                    },
                    0x3CE => {
                    },
                    // DEC SP (continued...)
                    0x3CF => {
                        self.step = 0x3D0;
                        break :next;
                    },
                    0x3D0 => {
                    },
                    // LD A,n (continued...)
                    0x3D1 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x3D2;
                        break :next;
                    },
                    0x3D2 => {
                        self.r[A] = gd(bus);
                        self.step = 0x3D3;
                        break :next;
                    },
                    0x3D3 => {
                    },
                    // LD B,(HL) (continued...)
                    0x3D4 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3D5;
                        break :next;
                    },
                    0x3D5 => {
                        self.r[B] = gd(bus);
                        self.step = 0x3D6;
                        break :next;
                    },
                    0x3D6 => {
                    },
                    // LD C,(HL) (continued...)
                    0x3D7 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3D8;
                        break :next;
                    },
                    0x3D8 => {
                        self.r[C] = gd(bus);
                        self.step = 0x3D9;
                        break :next;
                    },
                    0x3D9 => {
                    },
                    // LD D,(HL) (continued...)
                    0x3DA => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3DB;
                        break :next;
                    },
                    0x3DB => {
                        self.r[D] = gd(bus);
                        self.step = 0x3DC;
                        break :next;
                    },
                    0x3DC => {
                    },
                    // LD E,(HL) (continued...)
                    0x3DD => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3DE;
                        break :next;
                    },
                    0x3DE => {
                        self.r[E] = gd(bus);
                        self.step = 0x3DF;
                        break :next;
                    },
                    0x3DF => {
                    },
                    // LD H,(HL) (continued...)
                    0x3E0 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3E1;
                        break :next;
                    },
                    0x3E1 => {
                        self.r[H] = gd(bus);
                        self.step = 0x3E2;
                        break :next;
                    },
                    0x3E2 => {
                    },
                    // LD L,(HL) (continued...)
                    0x3E3 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3E4;
                        break :next;
                    },
                    0x3E4 => {
                        self.r[L] = gd(bus);
                        self.step = 0x3E5;
                        break :next;
                    },
                    0x3E5 => {
                    },
                    // LD (HL),B (continued...)
                    0x3E6 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[B]);
                        self.step = 0x3E7;
                        break :next;
                    },
                    0x3E7 => {
                        self.step = 0x3E8;
                        break :next;
                    },
                    0x3E8 => {
                    },
                    // LD (HL),C (continued...)
                    0x3E9 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[C]);
                        self.step = 0x3EA;
                        break :next;
                    },
                    0x3EA => {
                        self.step = 0x3EB;
                        break :next;
                    },
                    0x3EB => {
                    },
                    // LD (HL),D (continued...)
                    0x3EC => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[D]);
                        self.step = 0x3ED;
                        break :next;
                    },
                    0x3ED => {
                        self.step = 0x3EE;
                        break :next;
                    },
                    0x3EE => {
                    },
                    // LD (HL),E (continued...)
                    0x3EF => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[E]);
                        self.step = 0x3F0;
                        break :next;
                    },
                    0x3F0 => {
                        self.step = 0x3F1;
                        break :next;
                    },
                    0x3F1 => {
                    },
                    // LD (HL),H (continued...)
                    0x3F2 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[H]);
                        self.step = 0x3F3;
                        break :next;
                    },
                    0x3F3 => {
                        self.step = 0x3F4;
                        break :next;
                    },
                    0x3F4 => {
                    },
                    // LD (HL),L (continued...)
                    0x3F5 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[L]);
                        self.step = 0x3F6;
                        break :next;
                    },
                    0x3F6 => {
                        self.step = 0x3F7;
                        break :next;
                    },
                    0x3F7 => {
                    },
                    // LD (HL),A (continued...)
                    0x3F8 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.addr, self.r[A]);
                        self.step = 0x3F9;
                        break :next;
                    },
                    0x3F9 => {
                        self.step = 0x3FA;
                        break :next;
                    },
                    0x3FA => {
                    },
                    // LD A,(HL) (continued...)
                    0x3FB => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3FC;
                        break :next;
                    },
                    0x3FC => {
                        self.r[A] = gd(bus);
                        self.step = 0x3FD;
                        break :next;
                    },
                    0x3FD => {
                    },
                    // ADD (HL) (continued...)
                    0x3FE => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x3FF;
                        break :next;
                    },
                    0x3FF => {
                        self.dlatch = gd(bus);
                        self.step = 0x400;
                        break :next;
                    },
                    0x400 => {
                        self.add8(self.dlatch);
                    },
                    // ADC (HL) (continued...)
                    0x401 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x402;
                        break :next;
                    },
                    0x402 => {
                        self.dlatch = gd(bus);
                        self.step = 0x403;
                        break :next;
                    },
                    0x403 => {
                        self.adc8(self.dlatch);
                    },
                    // SUB (HL) (continued...)
                    0x404 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x405;
                        break :next;
                    },
                    0x405 => {
                        self.dlatch = gd(bus);
                        self.step = 0x406;
                        break :next;
                    },
                    0x406 => {
                        self.sub8(self.dlatch);
                    },
                    // SBC (HL) (continued...)
                    0x407 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x408;
                        break :next;
                    },
                    0x408 => {
                        self.dlatch = gd(bus);
                        self.step = 0x409;
                        break :next;
                    },
                    0x409 => {
                        self.sbc8(self.dlatch);
                    },
                    // AND (HL) (continued...)
                    0x40A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x40B;
                        break :next;
                    },
                    0x40B => {
                        self.dlatch = gd(bus);
                        self.step = 0x40C;
                        break :next;
                    },
                    0x40C => {
                        self.and8(self.dlatch);
                    },
                    // XOR (HL) (continued...)
                    0x40D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x40E;
                        break :next;
                    },
                    0x40E => {
                        self.dlatch = gd(bus);
                        self.step = 0x40F;
                        break :next;
                    },
                    0x40F => {
                        self.xor8(self.dlatch);
                    },
                    // OR (HL) (continued...)
                    0x410 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x411;
                        break :next;
                    },
                    0x411 => {
                        self.dlatch = gd(bus);
                        self.step = 0x412;
                        break :next;
                    },
                    0x412 => {
                        self.or8(self.dlatch);
                    },
                    // CP (HL) (continued...)
                    0x413 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.addr);
                        self.step = 0x414;
                        break :next;
                    },
                    0x414 => {
                        self.dlatch = gd(bus);
                        self.step = 0x415;
                        break :next;
                    },
                    0x415 => {
                        self.cp8(self.dlatch);
                    },
                    // RET NZ (continued...)
                    0x416 => {
                        self.step = 0x417;
                        break :next;
                    },
                    0x417 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x418;
                        break :next;
                    },
                    0x418 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x419;
                        break :next;
                    },
                    0x419 => {
                        self.step = 0x41A;
                        break :next;
                    },
                    0x41A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x41B;
                        break :next;
                    },
                    0x41B => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x41C;
                        break :next;
                    },
                    0x41C => {
                    },
                    // POP BC (continued...)
                    0x41D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x41E;
                        break :next;
                    },
                    0x41E => {
                        self.r[C] = gd(bus);
                        self.step = 0x41F;
                        break :next;
                    },
                    0x41F => {
                        self.step = 0x420;
                        break :next;
                    },
                    0x420 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x421;
                        break :next;
                    },
                    0x421 => {
                        self.r[B] = gd(bus);
                        self.step = 0x422;
                        break :next;
                    },
                    0x422 => {
                    },
                    // JP NZ,nn (continued...)
                    0x423 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x424;
                        break :next;
                    },
                    0x424 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x425;
                        break :next;
                    },
                    0x425 => {
                        self.step = 0x426;
                        break :next;
                    },
                    0x426 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x427;
                        break :next;
                    },
                    0x427 => {
                        self.r[WZH] = gd(bus);
                        if (self.testNZ()) self.pc = self.WZ();
                        self.step = 0x428;
                        break :next;
                    },
                    0x428 => {
                    },
                    // JP nn (continued...)
                    0x429 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x42A;
                        break :next;
                    },
                    0x42A => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x42B;
                        break :next;
                    },
                    0x42B => {
                        self.step = 0x42C;
                        break :next;
                    },
                    0x42C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x42D;
                        break :next;
                    },
                    0x42D => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x42E;
                        break :next;
                    },
                    0x42E => {
                    },
                    // CALL NZ,nn (continued...)
                    0x42F => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x430;
                        break :next;
                    },
                    0x430 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x431;
                        break :next;
                    },
                    0x431 => {
                        self.step = 0x432;
                        break :next;
                    },
                    0x432 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x433;
                        break :next;
                    },
                    0x433 => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoNZ(0x434 + 7)) break: next;
                        self.step = 0x434;
                        break :next;
                    },
                    0x434 => {
                        self.decSP();
                        self.step = 0x435;
                        break :next;
                    },
                    0x435 => {
                        self.step = 0x436;
                        break :next;
                    },
                    0x436 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
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
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x43A;
                        break :next;
                    },
                    0x43A => {
                        self.step = 0x43B;
                        break :next;
                    },
                    0x43B => {
                    },
                    // PUSH BC (continued...)
                    0x43C => {
                        self.step = 0x43D;
                        break :next;
                    },
                    0x43D => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[B]);
                        self.decSP();
                        self.step = 0x43E;
                        break :next;
                    },
                    0x43E => {
                        self.step = 0x43F;
                        break :next;
                    },
                    0x43F => {
                        self.step = 0x440;
                        break :next;
                    },
                    0x440 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[C]);
                        self.step = 0x441;
                        break :next;
                    },
                    0x441 => {
                        self.step = 0x442;
                        break :next;
                    },
                    0x442 => {
                    },
                    // ADD n (continued...)
                    0x443 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x444;
                        break :next;
                    },
                    0x444 => {
                        self.dlatch = gd(bus);
                        self.step = 0x445;
                        break :next;
                    },
                    0x445 => {
                        self.add8(self.dlatch);
                    },
                    // RST 0 (continued...)
                    0x446 => {
                        self.step = 0x447;
                        break :next;
                    },
                    0x447 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x448;
                        break :next;
                    },
                    0x448 => {
                        self.step = 0x449;
                        break :next;
                    },
                    0x449 => {
                        self.step = 0x44A;
                        break :next;
                    },
                    0x44A => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x0; self.setWZ(self.pc);
                        self.step = 0x44B;
                        break :next;
                    },
                    0x44B => {
                        self.step = 0x44C;
                        break :next;
                    },
                    0x44C => {
                    },
                    // RET Z (continued...)
                    0x44D => {
                        self.step = 0x44E;
                        break :next;
                    },
                    0x44E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x44F;
                        break :next;
                    },
                    0x44F => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x450;
                        break :next;
                    },
                    0x450 => {
                        self.step = 0x451;
                        break :next;
                    },
                    0x451 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x452;
                        break :next;
                    },
                    0x452 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x453;
                        break :next;
                    },
                    0x453 => {
                    },
                    // RET (continued...)
                    0x454 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x455;
                        break :next;
                    },
                    0x455 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x456;
                        break :next;
                    },
                    0x456 => {
                        self.step = 0x457;
                        break :next;
                    },
                    0x457 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x458;
                        break :next;
                    },
                    0x458 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x459;
                        break :next;
                    },
                    0x459 => {
                    },
                    // JP Z,nn (continued...)
                    0x45A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x45B;
                        break :next;
                    },
                    0x45B => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x45C;
                        break :next;
                    },
                    0x45C => {
                        self.step = 0x45D;
                        break :next;
                    },
                    0x45D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x45E;
                        break :next;
                    },
                    0x45E => {
                        self.r[WZH] = gd(bus);
                        if (self.testZ()) self.pc = self.WZ();
                        self.step = 0x45F;
                        break :next;
                    },
                    0x45F => {
                    },
                    // CALL Z,nn (continued...)
                    0x460 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x461;
                        break :next;
                    },
                    0x461 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x462;
                        break :next;
                    },
                    0x462 => {
                        self.step = 0x463;
                        break :next;
                    },
                    0x463 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x464;
                        break :next;
                    },
                    0x464 => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoZ(0x465 + 7)) break: next;
                        self.step = 0x465;
                        break :next;
                    },
                    0x465 => {
                        self.decSP();
                        self.step = 0x466;
                        break :next;
                    },
                    0x466 => {
                        self.step = 0x467;
                        break :next;
                    },
                    0x467 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x468;
                        break :next;
                    },
                    0x468 => {
                        self.step = 0x469;
                        break :next;
                    },
                    0x469 => {
                        self.step = 0x46A;
                        break :next;
                    },
                    0x46A => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x46B;
                        break :next;
                    },
                    0x46B => {
                        self.step = 0x46C;
                        break :next;
                    },
                    0x46C => {
                    },
                    // CALL nn (continued...)
                    0x46D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x46E;
                        break :next;
                    },
                    0x46E => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x46F;
                        break :next;
                    },
                    0x46F => {
                        self.step = 0x470;
                        break :next;
                    },
                    0x470 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x471;
                        break :next;
                    },
                    0x471 => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x472;
                        break :next;
                    },
                    0x472 => {
                        self.decSP();
                        self.step = 0x473;
                        break :next;
                    },
                    0x473 => {
                        self.step = 0x474;
                        break :next;
                    },
                    0x474 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x475;
                        break :next;
                    },
                    0x475 => {
                        self.step = 0x476;
                        break :next;
                    },
                    0x476 => {
                        self.step = 0x477;
                        break :next;
                    },
                    0x477 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x478;
                        break :next;
                    },
                    0x478 => {
                        self.step = 0x479;
                        break :next;
                    },
                    0x479 => {
                    },
                    // ADC n (continued...)
                    0x47A => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x47B;
                        break :next;
                    },
                    0x47B => {
                        self.dlatch = gd(bus);
                        self.step = 0x47C;
                        break :next;
                    },
                    0x47C => {
                        self.adc8(self.dlatch);
                    },
                    // RST 8 (continued...)
                    0x47D => {
                        self.step = 0x47E;
                        break :next;
                    },
                    0x47E => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x47F;
                        break :next;
                    },
                    0x47F => {
                        self.step = 0x480;
                        break :next;
                    },
                    0x480 => {
                        self.step = 0x481;
                        break :next;
                    },
                    0x481 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x8; self.setWZ(self.pc);
                        self.step = 0x482;
                        break :next;
                    },
                    0x482 => {
                        self.step = 0x483;
                        break :next;
                    },
                    0x483 => {
                    },
                    // RET NC (continued...)
                    0x484 => {
                        self.step = 0x485;
                        break :next;
                    },
                    0x485 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x486;
                        break :next;
                    },
                    0x486 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x487;
                        break :next;
                    },
                    0x487 => {
                        self.step = 0x488;
                        break :next;
                    },
                    0x488 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x489;
                        break :next;
                    },
                    0x489 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x48A;
                        break :next;
                    },
                    0x48A => {
                    },
                    // POP DE (continued...)
                    0x48B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x48C;
                        break :next;
                    },
                    0x48C => {
                        self.r[E] = gd(bus);
                        self.step = 0x48D;
                        break :next;
                    },
                    0x48D => {
                        self.step = 0x48E;
                        break :next;
                    },
                    0x48E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x48F;
                        break :next;
                    },
                    0x48F => {
                        self.r[D] = gd(bus);
                        self.step = 0x490;
                        break :next;
                    },
                    0x490 => {
                    },
                    // JP NC,nn (continued...)
                    0x491 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x492;
                        break :next;
                    },
                    0x492 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x493;
                        break :next;
                    },
                    0x493 => {
                        self.step = 0x494;
                        break :next;
                    },
                    0x494 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x495;
                        break :next;
                    },
                    0x495 => {
                        self.r[WZH] = gd(bus);
                        if (self.testNC()) self.pc = self.WZ();
                        self.step = 0x496;
                        break :next;
                    },
                    0x496 => {
                    },
                    // OUT (n),A (continued...)
                    0x497 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x498;
                        break :next;
                    },
                    0x498 => {
                        self.r[WZL] = gd(bus);
                        self.r[WZH] = self.r[A];
                        self.step = 0x499;
                        break :next;
                    },
                    0x499 => {
                        self.step = 0x49A;
                        break :next;
                    },
                    0x49A => {
                        bus = iowr(bus, self.WZ(), self.r[A]);
                        self.step = 0x49B;
                        break :next;
                    },
                    0x49B => {
                        if (wait(bus)) break :next;
                        self.r[WZL] +%=1;
                        self.step = 0x49C;
                        break :next;
                    },
                    0x49C => {
                        self.step = 0x49D;
                        break :next;
                    },
                    0x49D => {
                    },
                    // CALL NC,nn (continued...)
                    0x49E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x49F;
                        break :next;
                    },
                    0x49F => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4A0;
                        break :next;
                    },
                    0x4A0 => {
                        self.step = 0x4A1;
                        break :next;
                    },
                    0x4A1 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4A2;
                        break :next;
                    },
                    0x4A2 => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoNC(0x4A3 + 7)) break: next;
                        self.step = 0x4A3;
                        break :next;
                    },
                    0x4A3 => {
                        self.decSP();
                        self.step = 0x4A4;
                        break :next;
                    },
                    0x4A4 => {
                        self.step = 0x4A5;
                        break :next;
                    },
                    0x4A5 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x4A6;
                        break :next;
                    },
                    0x4A6 => {
                        self.step = 0x4A7;
                        break :next;
                    },
                    0x4A7 => {
                        self.step = 0x4A8;
                        break :next;
                    },
                    0x4A8 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x4A9;
                        break :next;
                    },
                    0x4A9 => {
                        self.step = 0x4AA;
                        break :next;
                    },
                    0x4AA => {
                    },
                    // PUSH DE (continued...)
                    0x4AB => {
                        self.step = 0x4AC;
                        break :next;
                    },
                    0x4AC => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[D]);
                        self.decSP();
                        self.step = 0x4AD;
                        break :next;
                    },
                    0x4AD => {
                        self.step = 0x4AE;
                        break :next;
                    },
                    0x4AE => {
                        self.step = 0x4AF;
                        break :next;
                    },
                    0x4AF => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[E]);
                        self.step = 0x4B0;
                        break :next;
                    },
                    0x4B0 => {
                        self.step = 0x4B1;
                        break :next;
                    },
                    0x4B1 => {
                    },
                    // SUB n (continued...)
                    0x4B2 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4B3;
                        break :next;
                    },
                    0x4B3 => {
                        self.dlatch = gd(bus);
                        self.step = 0x4B4;
                        break :next;
                    },
                    0x4B4 => {
                        self.sub8(self.dlatch);
                    },
                    // RST 10 (continued...)
                    0x4B5 => {
                        self.step = 0x4B6;
                        break :next;
                    },
                    0x4B6 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x4B7;
                        break :next;
                    },
                    0x4B7 => {
                        self.step = 0x4B8;
                        break :next;
                    },
                    0x4B8 => {
                        self.step = 0x4B9;
                        break :next;
                    },
                    0x4B9 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x10; self.setWZ(self.pc);
                        self.step = 0x4BA;
                        break :next;
                    },
                    0x4BA => {
                        self.step = 0x4BB;
                        break :next;
                    },
                    0x4BB => {
                    },
                    // RET C (continued...)
                    0x4BC => {
                        self.step = 0x4BD;
                        break :next;
                    },
                    0x4BD => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x4BE;
                        break :next;
                    },
                    0x4BE => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4BF;
                        break :next;
                    },
                    0x4BF => {
                        self.step = 0x4C0;
                        break :next;
                    },
                    0x4C0 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x4C1;
                        break :next;
                    },
                    0x4C1 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x4C2;
                        break :next;
                    },
                    0x4C2 => {
                    },
                    // JP C,nn (continued...)
                    0x4C3 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4C4;
                        break :next;
                    },
                    0x4C4 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4C5;
                        break :next;
                    },
                    0x4C5 => {
                        self.step = 0x4C6;
                        break :next;
                    },
                    0x4C6 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4C7;
                        break :next;
                    },
                    0x4C7 => {
                        self.r[WZH] = gd(bus);
                        if (self.testC()) self.pc = self.WZ();
                        self.step = 0x4C8;
                        break :next;
                    },
                    0x4C8 => {
                    },
                    // IN A,(n) (continued...)
                    0x4C9 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4CA;
                        break :next;
                    },
                    0x4CA => {
                        self.r[WZL] = gd(bus);
                        self.r[WZH] = self.r[A];
                        self.step = 0x4CB;
                        break :next;
                    },
                    0x4CB => {
                        self.step = 0x4CC;
                        break :next;
                    },
                    0x4CC => {
                        self.step = 0x4CD;
                        break :next;
                    },
                    0x4CD => {
                        if (wait(bus)) break :next;
                        bus = iord(bus, self.WZ());
                        self.incWZ();
                        self.step = 0x4CE;
                        break :next;
                    },
                    0x4CE => {
                        self.r[A] = gd(bus);
                        self.step = 0x4CF;
                        break :next;
                    },
                    0x4CF => {
                    },
                    // CALL C,nn (continued...)
                    0x4D0 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4D1;
                        break :next;
                    },
                    0x4D1 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4D2;
                        break :next;
                    },
                    0x4D2 => {
                        self.step = 0x4D3;
                        break :next;
                    },
                    0x4D3 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4D4;
                        break :next;
                    },
                    0x4D4 => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoC(0x4D5 + 7)) break: next;
                        self.step = 0x4D5;
                        break :next;
                    },
                    0x4D5 => {
                        self.decSP();
                        self.step = 0x4D6;
                        break :next;
                    },
                    0x4D6 => {
                        self.step = 0x4D7;
                        break :next;
                    },
                    0x4D7 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x4D8;
                        break :next;
                    },
                    0x4D8 => {
                        self.step = 0x4D9;
                        break :next;
                    },
                    0x4D9 => {
                        self.step = 0x4DA;
                        break :next;
                    },
                    0x4DA => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x4DB;
                        break :next;
                    },
                    0x4DB => {
                        self.step = 0x4DC;
                        break :next;
                    },
                    0x4DC => {
                    },
                    // SBC n (continued...)
                    0x4DD => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4DE;
                        break :next;
                    },
                    0x4DE => {
                        self.dlatch = gd(bus);
                        self.step = 0x4DF;
                        break :next;
                    },
                    0x4DF => {
                        self.sbc8(self.dlatch);
                    },
                    // RST 18 (continued...)
                    0x4E0 => {
                        self.step = 0x4E1;
                        break :next;
                    },
                    0x4E1 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x4E2;
                        break :next;
                    },
                    0x4E2 => {
                        self.step = 0x4E3;
                        break :next;
                    },
                    0x4E3 => {
                        self.step = 0x4E4;
                        break :next;
                    },
                    0x4E4 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x18; self.setWZ(self.pc);
                        self.step = 0x4E5;
                        break :next;
                    },
                    0x4E5 => {
                        self.step = 0x4E6;
                        break :next;
                    },
                    0x4E6 => {
                    },
                    // RET PO (continued...)
                    0x4E7 => {
                        self.step = 0x4E8;
                        break :next;
                    },
                    0x4E8 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x4E9;
                        break :next;
                    },
                    0x4E9 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4EA;
                        break :next;
                    },
                    0x4EA => {
                        self.step = 0x4EB;
                        break :next;
                    },
                    0x4EB => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x4EC;
                        break :next;
                    },
                    0x4EC => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x4ED;
                        break :next;
                    },
                    0x4ED => {
                    },
                    // POP HL (continued...)
                    0x4EE => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x4EF;
                        break :next;
                    },
                    0x4EF => {
                        self.r[L + self.rixy] = gd(bus);
                        self.step = 0x4F0;
                        break :next;
                    },
                    0x4F0 => {
                        self.step = 0x4F1;
                        break :next;
                    },
                    0x4F1 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x4F2;
                        break :next;
                    },
                    0x4F2 => {
                        self.r[H + self.rixy] = gd(bus);
                        self.step = 0x4F3;
                        break :next;
                    },
                    0x4F3 => {
                    },
                    // JP PO,nn (continued...)
                    0x4F4 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4F5;
                        break :next;
                    },
                    0x4F5 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4F6;
                        break :next;
                    },
                    0x4F6 => {
                        self.step = 0x4F7;
                        break :next;
                    },
                    0x4F7 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x4F8;
                        break :next;
                    },
                    0x4F8 => {
                        self.r[WZH] = gd(bus);
                        if (self.testPO()) self.pc = self.WZ();
                        self.step = 0x4F9;
                        break :next;
                    },
                    0x4F9 => {
                    },
                    // EX (SP),HL (continued...)
                    0x4FA => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.step = 0x4FB;
                        break :next;
                    },
                    0x4FB => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x4FC;
                        break :next;
                    },
                    0x4FC => {
                        self.step = 0x4FD;
                        break :next;
                    },
                    0x4FD => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP() +% 1);
                        self.step = 0x4FE;
                        break :next;
                    },
                    0x4FE => {
                        self.r[WZH] = gd(bus);
                        self.step = 0x4FF;
                        break :next;
                    },
                    0x4FF => {
                        self.step = 0x500;
                        break :next;
                    },
                    0x500 => {
                        self.step = 0x501;
                        break :next;
                    },
                    0x501 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP() +% 1, self.r[H + self.rixy]);
                        self.step = 0x502;
                        break :next;
                    },
                    0x502 => {
                        self.step = 0x503;
                        break :next;
                    },
                    0x503 => {
                        self.step = 0x504;
                        break :next;
                    },
                    0x504 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[L + self.rixy]);
                        self.setHLIXY(self.WZ());
                        self.step = 0x505;
                        break :next;
                    },
                    0x505 => {
                        self.step = 0x506;
                        break :next;
                    },
                    0x506 => {
                        self.step = 0x507;
                        break :next;
                    },
                    0x507 => {
                        self.step = 0x508;
                        break :next;
                    },
                    0x508 => {
                    },
                    // CALL PO,nn (continued...)
                    0x509 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x50A;
                        break :next;
                    },
                    0x50A => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x50B;
                        break :next;
                    },
                    0x50B => {
                        self.step = 0x50C;
                        break :next;
                    },
                    0x50C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x50D;
                        break :next;
                    },
                    0x50D => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoPO(0x50E + 7)) break: next;
                        self.step = 0x50E;
                        break :next;
                    },
                    0x50E => {
                        self.decSP();
                        self.step = 0x50F;
                        break :next;
                    },
                    0x50F => {
                        self.step = 0x510;
                        break :next;
                    },
                    0x510 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x511;
                        break :next;
                    },
                    0x511 => {
                        self.step = 0x512;
                        break :next;
                    },
                    0x512 => {
                        self.step = 0x513;
                        break :next;
                    },
                    0x513 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x514;
                        break :next;
                    },
                    0x514 => {
                        self.step = 0x515;
                        break :next;
                    },
                    0x515 => {
                    },
                    // PUSH HL (continued...)
                    0x516 => {
                        self.step = 0x517;
                        break :next;
                    },
                    0x517 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[H + self.rixy]);
                        self.decSP();
                        self.step = 0x518;
                        break :next;
                    },
                    0x518 => {
                        self.step = 0x519;
                        break :next;
                    },
                    0x519 => {
                        self.step = 0x51A;
                        break :next;
                    },
                    0x51A => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[L + self.rixy]);
                        self.step = 0x51B;
                        break :next;
                    },
                    0x51B => {
                        self.step = 0x51C;
                        break :next;
                    },
                    0x51C => {
                    },
                    // AND n (continued...)
                    0x51D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x51E;
                        break :next;
                    },
                    0x51E => {
                        self.dlatch = gd(bus);
                        self.step = 0x51F;
                        break :next;
                    },
                    0x51F => {
                        self.and8(self.dlatch);
                    },
                    // RST 20 (continued...)
                    0x520 => {
                        self.step = 0x521;
                        break :next;
                    },
                    0x521 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x522;
                        break :next;
                    },
                    0x522 => {
                        self.step = 0x523;
                        break :next;
                    },
                    0x523 => {
                        self.step = 0x524;
                        break :next;
                    },
                    0x524 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x20; self.setWZ(self.pc);
                        self.step = 0x525;
                        break :next;
                    },
                    0x525 => {
                        self.step = 0x526;
                        break :next;
                    },
                    0x526 => {
                    },
                    // RET PE (continued...)
                    0x527 => {
                        self.step = 0x528;
                        break :next;
                    },
                    0x528 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x529;
                        break :next;
                    },
                    0x529 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x52A;
                        break :next;
                    },
                    0x52A => {
                        self.step = 0x52B;
                        break :next;
                    },
                    0x52B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x52C;
                        break :next;
                    },
                    0x52C => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x52D;
                        break :next;
                    },
                    0x52D => {
                    },
                    // JP PE,nn (continued...)
                    0x52E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x52F;
                        break :next;
                    },
                    0x52F => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x530;
                        break :next;
                    },
                    0x530 => {
                        self.step = 0x531;
                        break :next;
                    },
                    0x531 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x532;
                        break :next;
                    },
                    0x532 => {
                        self.r[WZH] = gd(bus);
                        if (self.testPE()) self.pc = self.WZ();
                        self.step = 0x533;
                        break :next;
                    },
                    0x533 => {
                    },
                    // CALL PE,nn (continued...)
                    0x534 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x535;
                        break :next;
                    },
                    0x535 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x536;
                        break :next;
                    },
                    0x536 => {
                        self.step = 0x537;
                        break :next;
                    },
                    0x537 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x538;
                        break :next;
                    },
                    0x538 => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoPE(0x539 + 7)) break: next;
                        self.step = 0x539;
                        break :next;
                    },
                    0x539 => {
                        self.decSP();
                        self.step = 0x53A;
                        break :next;
                    },
                    0x53A => {
                        self.step = 0x53B;
                        break :next;
                    },
                    0x53B => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x53C;
                        break :next;
                    },
                    0x53C => {
                        self.step = 0x53D;
                        break :next;
                    },
                    0x53D => {
                        self.step = 0x53E;
                        break :next;
                    },
                    0x53E => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x53F;
                        break :next;
                    },
                    0x53F => {
                        self.step = 0x540;
                        break :next;
                    },
                    0x540 => {
                    },
                    // XOR n (continued...)
                    0x541 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x542;
                        break :next;
                    },
                    0x542 => {
                        self.dlatch = gd(bus);
                        self.step = 0x543;
                        break :next;
                    },
                    0x543 => {
                        self.xor8(self.dlatch);
                    },
                    // RST 28 (continued...)
                    0x544 => {
                        self.step = 0x545;
                        break :next;
                    },
                    0x545 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x546;
                        break :next;
                    },
                    0x546 => {
                        self.step = 0x547;
                        break :next;
                    },
                    0x547 => {
                        self.step = 0x548;
                        break :next;
                    },
                    0x548 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x28; self.setWZ(self.pc);
                        self.step = 0x549;
                        break :next;
                    },
                    0x549 => {
                        self.step = 0x54A;
                        break :next;
                    },
                    0x54A => {
                    },
                    // RET P (continued...)
                    0x54B => {
                        self.step = 0x54C;
                        break :next;
                    },
                    0x54C => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x54D;
                        break :next;
                    },
                    0x54D => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x54E;
                        break :next;
                    },
                    0x54E => {
                        self.step = 0x54F;
                        break :next;
                    },
                    0x54F => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x550;
                        break :next;
                    },
                    0x550 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x551;
                        break :next;
                    },
                    0x551 => {
                    },
                    // POP AF (continued...)
                    0x552 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x553;
                        break :next;
                    },
                    0x553 => {
                        self.r[F] = gd(bus);
                        self.step = 0x554;
                        break :next;
                    },
                    0x554 => {
                        self.step = 0x555;
                        break :next;
                    },
                    0x555 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x556;
                        break :next;
                    },
                    0x556 => {
                        self.r[A] = gd(bus);
                        self.step = 0x557;
                        break :next;
                    },
                    0x557 => {
                    },
                    // JP P,nn (continued...)
                    0x558 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x559;
                        break :next;
                    },
                    0x559 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x55A;
                        break :next;
                    },
                    0x55A => {
                        self.step = 0x55B;
                        break :next;
                    },
                    0x55B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x55C;
                        break :next;
                    },
                    0x55C => {
                        self.r[WZH] = gd(bus);
                        if (self.testP()) self.pc = self.WZ();
                        self.step = 0x55D;
                        break :next;
                    },
                    0x55D => {
                    },
                    // CALL P,nn (continued...)
                    0x55E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x55F;
                        break :next;
                    },
                    0x55F => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x560;
                        break :next;
                    },
                    0x560 => {
                        self.step = 0x561;
                        break :next;
                    },
                    0x561 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x562;
                        break :next;
                    },
                    0x562 => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoP(0x563 + 7)) break: next;
                        self.step = 0x563;
                        break :next;
                    },
                    0x563 => {
                        self.decSP();
                        self.step = 0x564;
                        break :next;
                    },
                    0x564 => {
                        self.step = 0x565;
                        break :next;
                    },
                    0x565 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x566;
                        break :next;
                    },
                    0x566 => {
                        self.step = 0x567;
                        break :next;
                    },
                    0x567 => {
                        self.step = 0x568;
                        break :next;
                    },
                    0x568 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x569;
                        break :next;
                    },
                    0x569 => {
                        self.step = 0x56A;
                        break :next;
                    },
                    0x56A => {
                    },
                    // PUSH AF (continued...)
                    0x56B => {
                        self.step = 0x56C;
                        break :next;
                    },
                    0x56C => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[A]);
                        self.decSP();
                        self.step = 0x56D;
                        break :next;
                    },
                    0x56D => {
                        self.step = 0x56E;
                        break :next;
                    },
                    0x56E => {
                        self.step = 0x56F;
                        break :next;
                    },
                    0x56F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.r[F]);
                        self.step = 0x570;
                        break :next;
                    },
                    0x570 => {
                        self.step = 0x571;
                        break :next;
                    },
                    0x571 => {
                    },
                    // OR n (continued...)
                    0x572 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x573;
                        break :next;
                    },
                    0x573 => {
                        self.dlatch = gd(bus);
                        self.step = 0x574;
                        break :next;
                    },
                    0x574 => {
                        self.or8(self.dlatch);
                    },
                    // RST 30 (continued...)
                    0x575 => {
                        self.step = 0x576;
                        break :next;
                    },
                    0x576 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x577;
                        break :next;
                    },
                    0x577 => {
                        self.step = 0x578;
                        break :next;
                    },
                    0x578 => {
                        self.step = 0x579;
                        break :next;
                    },
                    0x579 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x30; self.setWZ(self.pc);
                        self.step = 0x57A;
                        break :next;
                    },
                    0x57A => {
                        self.step = 0x57B;
                        break :next;
                    },
                    0x57B => {
                    },
                    // RET M (continued...)
                    0x57C => {
                        self.step = 0x57D;
                        break :next;
                    },
                    0x57D => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x57E;
                        break :next;
                    },
                    0x57E => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x57F;
                        break :next;
                    },
                    0x57F => {
                        self.step = 0x580;
                        break :next;
                    },
                    0x580 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.SP());
                        self.incSP();
                        self.step = 0x581;
                        break :next;
                    },
                    0x581 => {
                        self.r[WZH] = gd(bus);
                        self.pc = self.WZ();
                        self.step = 0x582;
                        break :next;
                    },
                    0x582 => {
                    },
                    // LD SP,HL (continued...)
                    0x583 => {
                        self.step = 0x584;
                        break :next;
                    },
                    0x584 => {
                    },
                    // JP M,nn (continued...)
                    0x585 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x586;
                        break :next;
                    },
                    0x586 => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x587;
                        break :next;
                    },
                    0x587 => {
                        self.step = 0x588;
                        break :next;
                    },
                    0x588 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x589;
                        break :next;
                    },
                    0x589 => {
                        self.r[WZH] = gd(bus);
                        if (self.testM()) self.pc = self.WZ();
                        self.step = 0x58A;
                        break :next;
                    },
                    0x58A => {
                    },
                    // CALL M,nn (continued...)
                    0x58B => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x58C;
                        break :next;
                    },
                    0x58C => {
                        self.r[WZL] = gd(bus);
                        self.step = 0x58D;
                        break :next;
                    },
                    0x58D => {
                        self.step = 0x58E;
                        break :next;
                    },
                    0x58E => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x58F;
                        break :next;
                    },
                    0x58F => {
                        self.r[WZH] = gd(bus);
                        if (self.gotoM(0x590 + 7)) break: next;
                        self.step = 0x590;
                        break :next;
                    },
                    0x590 => {
                        self.decSP();
                        self.step = 0x591;
                        break :next;
                    },
                    0x591 => {
                        self.step = 0x592;
                        break :next;
                    },
                    0x592 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x593;
                        break :next;
                    },
                    0x593 => {
                        self.step = 0x594;
                        break :next;
                    },
                    0x594 => {
                        self.step = 0x595;
                        break :next;
                    },
                    0x595 => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = self.WZ();
                        self.step = 0x596;
                        break :next;
                    },
                    0x596 => {
                        self.step = 0x597;
                        break :next;
                    },
                    0x597 => {
                    },
                    // CP n (continued...)
                    0x598 => {
                        if (wait(bus)) break :next;
                        bus = mrd(bus, self.pc);
                        self.incPC();
                        self.step = 0x599;
                        break :next;
                    },
                    0x599 => {
                        self.dlatch = gd(bus);
                        self.step = 0x59A;
                        break :next;
                    },
                    0x59A => {
                        self.cp8(self.dlatch);
                    },
                    // RST 38 (continued...)
                    0x59B => {
                        self.step = 0x59C;
                        break :next;
                    },
                    0x59C => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCH());
                        self.decSP();
                        self.step = 0x59D;
                        break :next;
                    },
                    0x59D => {
                        self.step = 0x59E;
                        break :next;
                    },
                    0x59E => {
                        self.step = 0x59F;
                        break :next;
                    },
                    0x59F => {
                        if (wait(bus)) break :next;
                        bus = mwr(bus, self.SP(), self.PCL());
                        self.pc = 0x38; self.setWZ(self.pc);
                        self.step = 0x5A0;
                        break :next;
                    },
                    0x5A0 => {
                        self.step = 0x5A1;
                        break :next;
                    },
                    0x5A1 => {
                    },
                    // LD I,A (continued...)
                    0x5A2 => {
                        self.setI(self.r[A]);
                    },
                    // LD R,A (continued...)
                    0x5A3 => {
                        self.setR(self.r[A]);
                    },
                    // LD A,I (continued...)
                    0x5A4 => {
                        self.r[A] = self.I(); self.r[F] = self.sziff2Flags(self.I());
                    },
                    // LD A,R (continued...)
                    0x5A5 => {
                        self.r[A] = self.R(); self.r[F] = self.sziff2Flags(self.R());
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
