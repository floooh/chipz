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
pub const CF: u8 = 1 << 0;
pub const NF: u8 = 1 << 1;
pub const VF: u8 = 1 << 2;
pub const PF: u8 = VF;
pub const XF: u8 = 1 << 3;
pub const HF: u8 = 1 << 4;
pub const YF: u8 = 1 << 5;
pub const ZF: u8 = 1 << 6;
pub const SF: u8 = 1 << 7;

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

        inline fn gotoFalse(self: *Self, cond: bool, comptime next_step: u16) bool {
            if (!cond) {
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

        inline fn decPC(self: *Self) void {
            self.pc -%= 1;
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

        inline fn decBC(self: *Self) void {
            self.setBC(self.BC() -% 1);
        }

        pub inline fn DE(self: *const Self) u16 {
            return self.get16(E);
        }

        pub inline fn setDE(self: *Self, de: u16) void {
            self.set16(E, de);
        }

        inline fn incDE(self: *Self) void {
            self.setDE(self.DE() +% 1);
        }

        inline fn decDE(self: *Self) void {
            self.setDE(self.DE() -% 1);
        }

        pub inline fn HL(self: *const Self) u16 {
            return self.get16(L);
        }

        pub inline fn setHL(self: *Self, hl: u16) void {
            self.set16(L, hl);
        }

        inline fn incHL(self: *Self) void {
            self.setHL(self.HL() +% 1);
        }

        inline fn decHL(self: *Self) void {
            self.setHL(self.HL() -% 1);
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

        inline fn decWZ(self: *Self) void {
            self.setWZ(self.WZ() -% 1);
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
            return @truncate(v);
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
            return (self.r[F] & CF) | szFlags(val) | (val & (YF | XF)) | if (self.iff2) PF else 0;
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

        fn neg8(self: *Self) void {
            const val = self.r[A];
            self.r[A] = 0;
            self.sub8(val);
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

        fn adc16(self: *Self, val: u16) void {
            const acc = self.HL();
            self.setWZ(acc +% 1);
            const res: u17 = @as(u17, acc) +% val +% (self.r[F] & CF);
            self.setHL(@truncate(res));
            var f: u17 = ((val ^ acc ^ 0x8000) & (val ^ res) & 0x8000) >> 13;
            f |= ((acc ^ res ^ val) >> 8) & HF;
            f |= (res >> 16) & CF;
            f |= (res >> 8) & (SF | YF | XF);
            f |= if (0 == (res & 0xFFFF)) ZF else 0;
            self.r[F] = @truncate(f);
        }

        fn sbc16(self: *Self, val: u16) void {
            const acc = self.HL();
            self.setWZ(acc +% 1);
            const res: u17 = @as(u17, acc) -% val -% (self.r[F] & CF);
            self.setHL(@truncate(res));
            var f: u17 = NF | (((val ^ acc) & (acc ^ res) & 0x8000) >> 13);
            f |= ((acc ^ res ^ val) >> 8) & HF;
            f |= (res >> 16) & CF;
            f |= (res >> 8) & (SF | YF | XF);
            f |= if (0 == (res & 0xFFFF)) ZF else 0;
            self.r[F] = @truncate(f);
        }

        fn in(self: *Self, val: u8) u8 {
            self.r[F] = (self.r[F] & CF) | szpFlags(val);
            return val;
        }

        fn rrd(self: *Self, val: u8) u8 {
            const lo = self.r[A] & 0x0F;
            const hi = self.r[A] & 0xF0;
            self.r[A] = hi | (val & 0x0F);
            self.r[F] = (self.r[F] & CF) | szpFlags(self.r[A]);
            return (val >> 4) | (lo << 4);
        }

        fn rld(self: *Self, val: u8) u8 {
            const lo = self.r[A] & 0x0F;
            const hi = self.r[A] & 0xF0;
            self.r[A] = hi | (val >> 4);
            self.r[F] = (self.r[F] & CF) | szpFlags(self.r[A]);
            return (val << 4) | lo;
        }

        fn ldildd(self: *Self) bool {
            const val = self.dlatch;
            const res = self.r[A] +% val;
            self.decBC();
            const bcnz = self.BC() != 0;
            self.r[F] = (self.r[F] & (SF | ZF | CF)) | ((res << 2) & (YF | XF)) | if (bcnz) VF else 0;
            return bcnz;
        }

        fn cpicpd(self: *Self) bool {
            const acc: u9 = self.r[A];
            var res: u9 = acc -% self.dlatch;
            self.decBC();
            const bcnz = self.BC() != 0;
            var f: u8 = (self.r[F] & CF) | NF | szFlags(trn8(res));
            if ((res & 0x0F) > (self.r[A] & 0x0F)) {
                f |= HF;
                res -%= 1;
            }
            self.r[F] = f | ((trn8(res) << 2) & (YF | XF)) | if (bcnz) VF else 0;
            return bcnz and ((f & ZF) == 0);
        }

        fn iniind(self: *Self, c8: u8) bool {
            const c: u9 = c8;
            const val: u9 = self.dlatch;
            const b: u8 = self.r[B];
            var f: u8 = szFlags(b) | (b & (XF | YF));
            if ((val & SF) != 0) f |= NF;
            const t: u9 = c + val;
            if ((t & 0x100) != 0) {
                f |= HF | CF;
            }
            self.r[F] = f | (szpFlags(trn8(t & 7) ^ b) & PF);
            return b != 0;
        }

        fn outioutd(self: *Self) bool {
            const b: u8 = self.r[B];
            const val: u9 = self.dlatch;
            const t: u9 = self.r[L] + val;
            var f: u8 = szFlags(b) | (b & (XF | YF));
            if ((t & 0x100) != 0) {
                f |= HF | CF;
            }
            self.r[F] = f | (szpFlags(trn8(t & 7) ^ b) & PF);
            return b != 0;
        }

        // BEGIN CONSTS
        const M1_T2: u16 = 0x76A;
        const M1_T3: u16 = 0x76B;
        const M1_T4: u16 = 0x76C;
        const DDFD_M1_T2: u16 = 0x76D;
        const DDFD_M1_T3: u16 = 0x76E;
        const DDFD_M1_T4: u16 = 0x76F;
        const DDFD_D_T1: u16 = 0x770;
        const DDFD_D_T2: u16 = 0x771;
        const DDFD_D_T3: u16 = 0x772;
        const DDFD_D_T4: u16 = 0x773;
        const DDFD_D_T5: u16 = 0x774;
        const DDFD_D_T6: u16 = 0x775;
        const DDFD_D_T7: u16 = 0x776;
        const DDFD_D_T8: u16 = 0x777;
        const DDFD_LDHLN_WR_T1: u16 = 0x778;
        const DDFD_LDHLN_WR_T2: u16 = 0x779;
        const DDFD_LDHLN_WR_T3: u16 = 0x77A;
        const DDFD_LDHLN_OVERLAPPED: u16 = 0x77B;
        const ED_M1_T2: u16 = 0x77C;
        const ED_M1_T3: u16 = 0x77D;
        const ED_M1_T4: u16 = 0x77E;
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
                    0x0 => { }, // NOP
                    0x1 => { self.step = 0x300; break :next; }, // LD BC,nn
                    0x2 => { self.step = 0x306; break :next; }, // LD (BC),A
                    0x3 => { self.setBC(self.BC() +% 1); self.step = 0x309; break :next; }, // INC BC
                    0x4 => { self.r[B]=self.inc8(self.r[B]); }, // INC B
                    0x5 => { self.r[B]=self.dec8(self.r[B]); }, // DEC B
                    0x6 => { self.step = 0x30B; break :next; }, // LD B,n
                    0x7 => { self.rlca(); }, // RLCA
                    0x8 => { self.exafaf2(); }, // EX AF,AF'
                    0x9 => { self.add16(self.BC()); self.step = 0x30E; break :next; }, // ADD HL,BC
                    0xA => { self.step = 0x315; break :next; }, // LD A,(BC)
                    0xB => { self.setBC(self.BC() -% 1); self.step = 0x318; break :next; }, // DEC BC
                    0xC => { self.r[C]=self.inc8(self.r[C]); }, // INC C
                    0xD => { self.r[C]=self.dec8(self.r[C]); }, // DEC C
                    0xE => { self.step = 0x31A; break :next; }, // LD C,n
                    0xF => { self.rrca(); }, // RRCA
                    0x10 => { self.r[B] -%= 1; self.step = 0x31D; break :next; }, // DJNZ
                    0x11 => { self.step = 0x326; break :next; }, // LD DE,nn
                    0x12 => { self.step = 0x32C; break :next; }, // LD (DE),A
                    0x13 => { self.setDE(self.DE() +% 1); self.step = 0x32F; break :next; }, // INC DE
                    0x14 => { self.r[D]=self.inc8(self.r[D]); }, // INC D
                    0x15 => { self.r[D]=self.dec8(self.r[D]); }, // DEC D
                    0x16 => { self.step = 0x331; break :next; }, // LD D,n
                    0x17 => { self.rla(); }, // RLA
                    0x18 => { self.step = 0x334; break :next; }, // JR d
                    0x19 => { self.add16(self.DE()); self.step = 0x33C; break :next; }, // ADD HL,DE
                    0x1A => { self.step = 0x343; break :next; }, // LD A,(DE)
                    0x1B => { self.setDE(self.DE() -% 1); self.step = 0x346; break :next; }, // DEC DE
                    0x1C => { self.r[E]=self.inc8(self.r[E]); }, // INC E
                    0x1D => { self.r[E]=self.dec8(self.r[E]); }, // DEC E
                    0x1E => { self.step = 0x348; break :next; }, // LD E,n
                    0x1F => { self.rra(); }, // RRA
                    0x20 => { self.step = 0x34B; break :next; }, // JR NZ,d
                    0x21 => { self.step = 0x353; break :next; }, // LD HL,nn
                    0x22 => { self.step = 0x359; break :next; }, // LD (HL),nn
                    0x23 => { self.setHLIXY(self.HLIXY() +% 1); self.step = 0x365; break :next; }, // INC HL
                    0x24 => { self.r[H + self.rixy]=self.inc8(self.r[H + self.rixy]); }, // INC H
                    0x25 => { self.r[H + self.rixy]=self.dec8(self.r[H + self.rixy]); }, // DEC H
                    0x26 => { self.step = 0x367; break :next; }, // LD H,n
                    0x27 => { self.daa(); }, // DDA
                    0x28 => { self.step = 0x36A; break :next; }, // JR Z,d
                    0x29 => { self.add16(self.HLIXY()); self.step = 0x372; break :next; }, // ADD HL,HL
                    0x2A => { self.step = 0x379; break :next; }, // LD HL,(nn)
                    0x2B => { self.setHLIXY(self.HLIXY() -% 1); self.step = 0x385; break :next; }, // DEC HL
                    0x2C => { self.r[L + self.rixy]=self.inc8(self.r[L + self.rixy]); }, // INC L
                    0x2D => { self.r[L + self.rixy]=self.dec8(self.r[L + self.rixy]); }, // DEC L
                    0x2E => { self.step = 0x387; break :next; }, // LD L,n
                    0x2F => { self.cpl(); }, // CPL
                    0x30 => { self.step = 0x38A; break :next; }, // JR NC,d
                    0x31 => { self.step = 0x392; break :next; }, // LD SP,nn
                    0x32 => { self.step = 0x398; break :next; }, // LD (HL),A
                    0x33 => { self.setSP(self.SP() +% 1); self.step = 0x3A1; break :next; }, // INC SP
                    0x34 => { self.step = 0x3A3; break :next; }, // INC (HL)
                    0x35 => { self.step = 0x3AA; break :next; }, // DEC (HL)
                    0x36 => { self.step = 0x3B1; break :next; }, // LD (HL),n
                    0x37 => { self.scf(); }, // SCF
                    0x38 => { self.step = 0x3B7; break :next; }, // JR C,d
                    0x39 => { self.add16(self.SP()); self.step = 0x3BF; break :next; }, // ADD HL,SP
                    0x3A => { self.step = 0x3C6; break :next; }, // LD A,(nn)
                    0x3B => { self.setSP(self.SP() -% 1); self.step = 0x3CF; break :next; }, // DEC SP
                    0x3C => { self.r[A]=self.inc8(self.r[A]); }, // INC A
                    0x3D => { self.r[A]=self.dec8(self.r[A]); }, // DEC A
                    0x3E => { self.step = 0x3D1; break :next; }, // LD A,n
                    0x3F => { self.ccf(); }, // CCF
                    0x40 => { self.r[B] = self.r[B]; }, // LD B,B
                    0x41 => { self.r[B] = self.r[C]; }, // LD B,C
                    0x42 => { self.r[B] = self.r[D]; }, // LD B,D
                    0x43 => { self.r[B] = self.r[E]; }, // LD B,E
                    0x44 => { self.r[B] = self.r[H + self.rixy]; }, // LD B,H
                    0x45 => { self.r[B] = self.r[L + self.rixy]; }, // LD B,L
                    0x46 => { self.step = 0x3D4; break :next; }, // LD B,(HL)
                    0x47 => { self.r[B] = self.r[A]; }, // LD B,A
                    0x48 => { self.r[C] = self.r[B]; }, // LD C,B
                    0x49 => { self.r[C] = self.r[C]; }, // LD C,C
                    0x4A => { self.r[C] = self.r[D]; }, // LD C,D
                    0x4B => { self.r[C] = self.r[E]; }, // LD C,E
                    0x4C => { self.r[C] = self.r[H + self.rixy]; }, // LD C,H
                    0x4D => { self.r[C] = self.r[L + self.rixy]; }, // LD C,L
                    0x4E => { self.step = 0x3D7; break :next; }, // LD C,(HL)
                    0x4F => { self.r[C] = self.r[A]; }, // LD C,A
                    0x50 => { self.r[D] = self.r[B]; }, // LD D,B
                    0x51 => { self.r[D] = self.r[C]; }, // LD D,C
                    0x52 => { self.r[D] = self.r[D]; }, // LD D,D
                    0x53 => { self.r[D] = self.r[E]; }, // LD D,E
                    0x54 => { self.r[D] = self.r[H + self.rixy]; }, // LD D,H
                    0x55 => { self.r[D] = self.r[L + self.rixy]; }, // LD D,L
                    0x56 => { self.step = 0x3DA; break :next; }, // LD D,(HL)
                    0x57 => { self.r[D] = self.r[A]; }, // LD D,A
                    0x58 => { self.r[E] = self.r[B]; }, // LD E,B
                    0x59 => { self.r[E] = self.r[C]; }, // LD E,C
                    0x5A => { self.r[E] = self.r[D]; }, // LD E,D
                    0x5B => { self.r[E] = self.r[E]; }, // LD E,E
                    0x5C => { self.r[E] = self.r[H + self.rixy]; }, // LD E,H
                    0x5D => { self.r[E] = self.r[L + self.rixy]; }, // LD E,L
                    0x5E => { self.step = 0x3DD; break :next; }, // LD E,(HL)
                    0x5F => { self.r[E] = self.r[A]; }, // LD E,A
                    0x60 => { self.r[H + self.rixy] = self.r[B]; }, // LD H,B
                    0x61 => { self.r[H + self.rixy] = self.r[C]; }, // LD H,C
                    0x62 => { self.r[H + self.rixy] = self.r[D]; }, // LD H,D
                    0x63 => { self.r[H + self.rixy] = self.r[E]; }, // LD H,E
                    0x64 => { self.r[H + self.rixy] = self.r[H + self.rixy]; }, // LD H,H
                    0x65 => { self.r[H + self.rixy] = self.r[L + self.rixy]; }, // LD H,L
                    0x66 => { self.step = 0x3E0; break :next; }, // LD H,(HL)
                    0x67 => { self.r[H + self.rixy] = self.r[A]; }, // LD H,A
                    0x68 => { self.r[L + self.rixy] = self.r[B]; }, // LD L,B
                    0x69 => { self.r[L + self.rixy] = self.r[C]; }, // LD L,C
                    0x6A => { self.r[L + self.rixy] = self.r[D]; }, // LD L,D
                    0x6B => { self.r[L + self.rixy] = self.r[E]; }, // LD L,E
                    0x6C => { self.r[L + self.rixy] = self.r[H + self.rixy]; }, // LD L,H
                    0x6D => { self.r[L + self.rixy] = self.r[L + self.rixy]; }, // LD L,L
                    0x6E => { self.step = 0x3E3; break :next; }, // LD L,(HL)
                    0x6F => { self.r[L + self.rixy] = self.r[A]; }, // LD L,A
                    0x70 => { self.step = 0x3E6; break :next; }, // LD (HL),B
                    0x71 => { self.step = 0x3E9; break :next; }, // LD (HL),C
                    0x72 => { self.step = 0x3EC; break :next; }, // LD (HL),D
                    0x73 => { self.step = 0x3EF; break :next; }, // LD (HL),E
                    0x74 => { self.step = 0x3F2; break :next; }, // LD (HL),H
                    0x75 => { self.step = 0x3F5; break :next; }, // LD (HL),L
                    0x76 => { bus = self.halt(bus); }, // HALT
                    0x77 => { self.step = 0x3F8; break :next; }, // LD (HL),A
                    0x78 => { self.r[A] = self.r[B]; }, // LD A,B
                    0x79 => { self.r[A] = self.r[C]; }, // LD A,C
                    0x7A => { self.r[A] = self.r[D]; }, // LD A,D
                    0x7B => { self.r[A] = self.r[E]; }, // LD A,E
                    0x7C => { self.r[A] = self.r[H + self.rixy]; }, // LD A,H
                    0x7D => { self.r[A] = self.r[L + self.rixy]; }, // LD A,L
                    0x7E => { self.step = 0x3FB; break :next; }, // LD A,(HL)
                    0x7F => { self.r[A] = self.r[A]; }, // LD A,A
                    0x80 => { self.add8(self.r[B]); }, // ADD B
                    0x81 => { self.add8(self.r[C]); }, // ADD C
                    0x82 => { self.add8(self.r[D]); }, // ADD D
                    0x83 => { self.add8(self.r[E]); }, // ADD E
                    0x84 => { self.add8(self.r[H + self.rixy]); }, // ADD H
                    0x85 => { self.add8(self.r[L + self.rixy]); }, // ADD L
                    0x86 => { self.step = 0x3FE; break :next; }, // ADD (HL)
                    0x87 => { self.add8(self.r[A]); }, // ADD A
                    0x88 => { self.adc8(self.r[B]); }, // ADC B
                    0x89 => { self.adc8(self.r[C]); }, // ADC C
                    0x8A => { self.adc8(self.r[D]); }, // ADC D
                    0x8B => { self.adc8(self.r[E]); }, // ADC E
                    0x8C => { self.adc8(self.r[H + self.rixy]); }, // ADC H
                    0x8D => { self.adc8(self.r[L + self.rixy]); }, // ADC L
                    0x8E => { self.step = 0x401; break :next; }, // ADC (HL)
                    0x8F => { self.adc8(self.r[A]); }, // ADC A
                    0x90 => { self.sub8(self.r[B]); }, // SUB B
                    0x91 => { self.sub8(self.r[C]); }, // SUB C
                    0x92 => { self.sub8(self.r[D]); }, // SUB D
                    0x93 => { self.sub8(self.r[E]); }, // SUB E
                    0x94 => { self.sub8(self.r[H + self.rixy]); }, // SUB H
                    0x95 => { self.sub8(self.r[L + self.rixy]); }, // SUB L
                    0x96 => { self.step = 0x404; break :next; }, // SUB (HL)
                    0x97 => { self.sub8(self.r[A]); }, // SUB A
                    0x98 => { self.sbc8(self.r[B]); }, // SBC B
                    0x99 => { self.sbc8(self.r[C]); }, // SBC C
                    0x9A => { self.sbc8(self.r[D]); }, // SBC D
                    0x9B => { self.sbc8(self.r[E]); }, // SBC E
                    0x9C => { self.sbc8(self.r[H + self.rixy]); }, // SBC H
                    0x9D => { self.sbc8(self.r[L + self.rixy]); }, // SBC L
                    0x9E => { self.step = 0x407; break :next; }, // SBC (HL)
                    0x9F => { self.sbc8(self.r[A]); }, // SBC A
                    0xA0 => { self.and8(self.r[B]); }, // AND B
                    0xA1 => { self.and8(self.r[C]); }, // AND C
                    0xA2 => { self.and8(self.r[D]); }, // AND D
                    0xA3 => { self.and8(self.r[E]); }, // AND E
                    0xA4 => { self.and8(self.r[H + self.rixy]); }, // AND H
                    0xA5 => { self.and8(self.r[L + self.rixy]); }, // AND L
                    0xA6 => { self.step = 0x40A; break :next; }, // AND (HL)
                    0xA7 => { self.and8(self.r[A]); }, // AND A
                    0xA8 => { self.xor8(self.r[B]); }, // XOR B
                    0xA9 => { self.xor8(self.r[C]); }, // XOR C
                    0xAA => { self.xor8(self.r[D]); }, // XOR D
                    0xAB => { self.xor8(self.r[E]); }, // XOR E
                    0xAC => { self.xor8(self.r[H + self.rixy]); }, // XOR H
                    0xAD => { self.xor8(self.r[L + self.rixy]); }, // XOR L
                    0xAE => { self.step = 0x40D; break :next; }, // XOR (HL)
                    0xAF => { self.xor8(self.r[A]); }, // XOR A
                    0xB0 => { self.or8(self.r[B]); }, // OR B
                    0xB1 => { self.or8(self.r[C]); }, // OR C
                    0xB2 => { self.or8(self.r[D]); }, // OR D
                    0xB3 => { self.or8(self.r[E]); }, // OR E
                    0xB4 => { self.or8(self.r[H + self.rixy]); }, // OR H
                    0xB5 => { self.or8(self.r[L + self.rixy]); }, // OR L
                    0xB6 => { self.step = 0x410; break :next; }, // OR (HL)
                    0xB7 => { self.or8(self.r[A]); }, // OR A
                    0xB8 => { self.cp8(self.r[B]); }, // CP B
                    0xB9 => { self.cp8(self.r[C]); }, // CP C
                    0xBA => { self.cp8(self.r[D]); }, // CP D
                    0xBB => { self.cp8(self.r[E]); }, // CP E
                    0xBC => { self.cp8(self.r[H + self.rixy]); }, // CP H
                    0xBD => { self.cp8(self.r[L + self.rixy]); }, // CP L
                    0xBE => { self.step = 0x413; break :next; }, // CP (HL)
                    0xBF => { self.cp8(self.r[A]); }, // CP A
                    0xC0 => { if (self.gotoNZ(0x416 + 6)) break :next; self.step = 0x416; break :next; }, // RET NZ
                    0xC1 => { self.step = 0x41D; break :next; }, // POP BC
                    0xC2 => { self.step = 0x423; break :next; }, // JP NZ,nn
                    0xC3 => { self.step = 0x429; break :next; }, // JP nn
                    0xC4 => { self.step = 0x42F; break :next; }, // CALL NZ,nn
                    0xC5 => { self.decSP(); self.step = 0x43C; break :next; }, // PUSH BC
                    0xC6 => { self.step = 0x443; break :next; }, // ADD n
                    0xC7 => { self.decSP(); self.step = 0x446; break :next; }, // RST 0
                    0xC8 => { if (self.gotoZ(0x44D + 6)) break :next; self.step = 0x44D; break :next; }, // RET Z
                    0xC9 => { self.step = 0x454; break :next; }, // RET
                    0xCA => { self.step = 0x45A; break :next; }, // JP Z,nn
                    0xCB => { bus = self.fetchCB(bus); break :next; }, // CB Prefix
                    0xCC => { self.step = 0x460; break :next; }, // CALL Z,nn
                    0xCD => { self.step = 0x46D; break :next; }, // CALL nn
                    0xCE => { self.step = 0x47A; break :next; }, // ADC n
                    0xCF => { self.decSP(); self.step = 0x47D; break :next; }, // RST 8
                    0xD0 => { if (self.gotoNC(0x484 + 6)) break :next; self.step = 0x484; break :next; }, // RET NC
                    0xD1 => { self.step = 0x48B; break :next; }, // POP DE
                    0xD2 => { self.step = 0x491; break :next; }, // JP NC,nn
                    0xD3 => { self.step = 0x497; break :next; }, // OUT (n),A
                    0xD4 => { self.step = 0x49E; break :next; }, // CALL NC,nn
                    0xD5 => { self.decSP(); self.step = 0x4AB; break :next; }, // PUSH DE
                    0xD6 => { self.step = 0x4B2; break :next; }, // SUB n
                    0xD7 => { self.decSP(); self.step = 0x4B5; break :next; }, // RST 10
                    0xD8 => { if (self.gotoC(0x4BC + 6)) break :next; self.step = 0x4BC; break :next; }, // RET C
                    0xD9 => { self.exx(); }, // EXX
                    0xDA => { self.step = 0x4C3; break :next; }, // JP C,nn
                    0xDB => { self.step = 0x4C9; break :next; }, // IN A,(n)
                    0xDC => { self.step = 0x4D0; break :next; }, // CALL C,nn
                    0xDD => { bus = self.fetchDD(bus); break :next; }, // DD Prefix
                    0xDE => { self.step = 0x4DD; break :next; }, // SBC n
                    0xDF => { self.decSP(); self.step = 0x4E0; break :next; }, // RST 18
                    0xE0 => { if (self.gotoPO(0x4E7 + 6)) break :next; self.step = 0x4E7; break :next; }, // RET PO
                    0xE1 => { self.step = 0x4EE; break :next; }, // POP HL
                    0xE2 => { self.step = 0x4F4; break :next; }, // JP PO,nn
                    0xE3 => { self.step = 0x4FA; break :next; }, // EX (SP),HL
                    0xE4 => { self.step = 0x509; break :next; }, // CALL PO,nn
                    0xE5 => { self.decSP(); self.step = 0x516; break :next; }, // PUSH HL
                    0xE6 => { self.step = 0x51D; break :next; }, // AND n
                    0xE7 => { self.decSP(); self.step = 0x520; break :next; }, // RST 20
                    0xE8 => { if (self.gotoPE(0x527 + 6)) break :next; self.step = 0x527; break :next; }, // RET PE
                    0xE9 => { self.pc = self.HLIXY(); }, // JP HL
                    0xEA => { self.step = 0x52E; break :next; }, // JP PE,nn
                    0xEB => { self.exdehl(); }, // EX DE,HL
                    0xEC => { self.step = 0x534; break :next; }, // CALL PE,nn
                    0xED => { bus = self.fetchED(bus); break :next; }, // ED Prefix
                    0xEE => { self.step = 0x541; break :next; }, // XOR n
                    0xEF => { self.decSP(); self.step = 0x544; break :next; }, // RST 28
                    0xF0 => { if (self.gotoP(0x54B + 6)) break :next; self.step = 0x54B; break :next; }, // RET P
                    0xF1 => { self.step = 0x552; break :next; }, // POP AF
                    0xF2 => { self.step = 0x558; break :next; }, // JP P,nn
                    0xF3 => { self.iff1 = false; self.iff2 = false; }, // DI
                    0xF4 => { self.step = 0x55E; break :next; }, // CALL P,nn
                    0xF5 => { self.decSP(); self.step = 0x56B; break :next; }, // PUSH AF
                    0xF6 => { self.step = 0x572; break :next; }, // OR n
                    0xF7 => { self.decSP(); self.step = 0x575; break :next; }, // RST 30
                    0xF8 => { if (self.gotoM(0x57C + 6)) break :next; self.step = 0x57C; break :next; }, // RET M
                    0xF9 => { self.setSP(self.HLIXY()); self.step = 0x583; break :next; }, // LD SP,HL
                    0xFA => { self.step = 0x585; break :next; }, // JP M,nn
                    0xFB => { self.iff1 = false; self.iff2 = false; bus = self.fetch(bus); self.iff1 = true; self.iff2 = true; break :next; }, // EI
                    0xFC => { self.step = 0x58B; break :next; }, // CALL M,nn
                    0xFD => { bus = self.fetchFD(bus); break :next; }, // FD Prefix
                    0xFE => { self.step = 0x598; break :next; }, // CP n
                    0xFF => { self.decSP(); self.step = 0x59B; break :next; }, // RST 38
                    0x100 => { }, // ED NOP
                    0x101 => { }, // ED NOP
                    0x102 => { }, // ED NOP
                    0x103 => { }, // ED NOP
                    0x104 => { }, // ED NOP
                    0x105 => { }, // ED NOP
                    0x106 => { }, // ED NOP
                    0x107 => { }, // ED NOP
                    0x108 => { }, // ED NOP
                    0x109 => { }, // ED NOP
                    0x10A => { }, // ED NOP
                    0x10B => { }, // ED NOP
                    0x10C => { }, // ED NOP
                    0x10D => { }, // ED NOP
                    0x10E => { }, // ED NOP
                    0x10F => { }, // ED NOP
                    0x110 => { }, // ED NOP
                    0x111 => { }, // ED NOP
                    0x112 => { }, // ED NOP
                    0x113 => { }, // ED NOP
                    0x114 => { }, // ED NOP
                    0x115 => { }, // ED NOP
                    0x116 => { }, // ED NOP
                    0x117 => { }, // ED NOP
                    0x118 => { }, // ED NOP
                    0x119 => { }, // ED NOP
                    0x11A => { }, // ED NOP
                    0x11B => { }, // ED NOP
                    0x11C => { }, // ED NOP
                    0x11D => { }, // ED NOP
                    0x11E => { }, // ED NOP
                    0x11F => { }, // ED NOP
                    0x120 => { }, // ED NOP
                    0x121 => { }, // ED NOP
                    0x122 => { }, // ED NOP
                    0x123 => { }, // ED NOP
                    0x124 => { }, // ED NOP
                    0x125 => { }, // ED NOP
                    0x126 => { }, // ED NOP
                    0x127 => { }, // ED NOP
                    0x128 => { }, // ED NOP
                    0x129 => { }, // ED NOP
                    0x12A => { }, // ED NOP
                    0x12B => { }, // ED NOP
                    0x12C => { }, // ED NOP
                    0x12D => { }, // ED NOP
                    0x12E => { }, // ED NOP
                    0x12F => { }, // ED NOP
                    0x130 => { }, // ED NOP
                    0x131 => { }, // ED NOP
                    0x132 => { }, // ED NOP
                    0x133 => { }, // ED NOP
                    0x134 => { }, // ED NOP
                    0x135 => { }, // ED NOP
                    0x136 => { }, // ED NOP
                    0x137 => { }, // ED NOP
                    0x138 => { }, // ED NOP
                    0x139 => { }, // ED NOP
                    0x13A => { }, // ED NOP
                    0x13B => { }, // ED NOP
                    0x13C => { }, // ED NOP
                    0x13D => { }, // ED NOP
                    0x13E => { }, // ED NOP
                    0x13F => { }, // ED NOP
                    0x140 => { self.step = 0x5A2; break :next; }, // IN B,(C)
                    0x141 => { self.step = 0x5A6; break :next; }, // OUT (C),B
                    0x142 => { self.sbc16(self.BC()); self.step = 0x5AA; break :next; }, // SBC HL,BC
                    0x143 => { self.step = 0x5B1; break :next; }, // LD (nn),BC
                    0x144 => { self.neg8(); }, // NEG
                    0x145 => { self.step = 0x5BD; break :next; }, // RETN
                    0x146 => { self.im = 0; }, // IM 0
                    0x147 => { self.step = 0x5C3; break :next; }, // LD I,A
                    0x148 => { self.step = 0x5C4; break :next; }, // IN C,(C)
                    0x149 => { self.step = 0x5C8; break :next; }, // OUT (C),C
                    0x14A => { self.adc16(self.BC()); self.step = 0x5CC; break :next; }, // ADC HL,BC
                    0x14B => { self.step = 0x5D3; break :next; }, // LD BC,(nn)
                    0x14C => { self.neg8(); }, // NEG
                    0x14D => { self.step = 0x5DF; break :next; }, // RETI
                    0x14E => { self.im = 0; }, // IM 0
                    0x14F => { self.step = 0x5E5; break :next; }, // LD R,A
                    0x150 => { self.step = 0x5E6; break :next; }, // IN D,(C)
                    0x151 => { self.step = 0x5EA; break :next; }, // OUT (C),D
                    0x152 => { self.sbc16(self.DE()); self.step = 0x5EE; break :next; }, // SBC HL,DE
                    0x153 => { self.step = 0x5F5; break :next; }, // LD (nn),DE
                    0x154 => { self.neg8(); }, // NEG
                    0x155 => { self.step = 0x601; break :next; }, // RETI
                    0x156 => { self.im = 1; }, // IM 1
                    0x157 => { self.step = 0x607; break :next; }, // LD A,I
                    0x158 => { self.step = 0x608; break :next; }, // IN E,(C)
                    0x159 => { self.step = 0x60C; break :next; }, // OUT (C),E
                    0x15A => { self.adc16(self.DE()); self.step = 0x610; break :next; }, // ADC HL,DE
                    0x15B => { self.step = 0x617; break :next; }, // LD DE,(nn)
                    0x15C => { self.neg8(); }, // NEG
                    0x15D => { self.step = 0x623; break :next; }, // RETI
                    0x15E => { self.im = 2; }, // IM 2
                    0x15F => { self.step = 0x629; break :next; }, // LD A,R
                    0x160 => { self.step = 0x62A; break :next; }, // IN H,(C)
                    0x161 => { self.step = 0x62E; break :next; }, // OUT (C),H
                    0x162 => { self.sbc16(self.HL()); self.step = 0x632; break :next; }, // SBC HL,HL
                    0x163 => { self.step = 0x639; break :next; }, // LD (nn),HL
                    0x164 => { self.neg8(); }, // NEG
                    0x165 => { self.step = 0x645; break :next; }, // RETI
                    0x166 => { self.im = 0; }, // IM 0
                    0x167 => { self.step = 0x64B; break :next; }, // RRD
                    0x168 => { self.step = 0x655; break :next; }, // IN L,(C)
                    0x169 => { self.step = 0x659; break :next; }, // OUT (C),L
                    0x16A => { self.adc16(self.HL()); self.step = 0x65D; break :next; }, // ADC HL,HL
                    0x16B => { self.step = 0x664; break :next; }, // LD HL,(nn)
                    0x16C => { self.neg8(); }, // NEG
                    0x16D => { self.step = 0x670; break :next; }, // RETI
                    0x16E => { self.im = 0; }, // IM 0
                    0x16F => { self.step = 0x676; break :next; }, // RLD
                    0x170 => { self.step = 0x680; break :next; }, // IN (C)
                    0x171 => { self.step = 0x684; break :next; }, // OUT (C)
                    0x172 => { self.sbc16(self.SP()); self.step = 0x688; break :next; }, // SBC HL,SP
                    0x173 => { self.step = 0x68F; break :next; }, // LD (nn),SP
                    0x174 => { self.neg8(); }, // NEG
                    0x175 => { self.step = 0x69B; break :next; }, // RETI
                    0x176 => { self.im = 1; }, // IM 1
                    0x177 => { }, // ED NOP
                    0x178 => { self.step = 0x6A1; break :next; }, // IN A,(C)
                    0x179 => { self.step = 0x6A5; break :next; }, // OUT (C),A
                    0x17A => { self.adc16(self.SP()); self.step = 0x6A9; break :next; }, // ADC HL,SP
                    0x17B => { self.step = 0x6B0; break :next; }, // LD SP,(nn)
                    0x17C => { self.neg8(); }, // NEG
                    0x17D => { self.step = 0x6BC; break :next; }, // RETI
                    0x17E => { self.im = 2; }, // IM 2
                    0x17F => { }, // ED NOP
                    0x180 => { }, // ED NOP
                    0x181 => { }, // ED NOP
                    0x182 => { }, // ED NOP
                    0x183 => { }, // ED NOP
                    0x184 => { }, // ED NOP
                    0x185 => { }, // ED NOP
                    0x186 => { }, // ED NOP
                    0x187 => { }, // ED NOP
                    0x188 => { }, // ED NOP
                    0x189 => { }, // ED NOP
                    0x18A => { }, // ED NOP
                    0x18B => { }, // ED NOP
                    0x18C => { }, // ED NOP
                    0x18D => { }, // ED NOP
                    0x18E => { }, // ED NOP
                    0x18F => { }, // ED NOP
                    0x190 => { }, // ED NOP
                    0x191 => { }, // ED NOP
                    0x192 => { }, // ED NOP
                    0x193 => { }, // ED NOP
                    0x194 => { }, // ED NOP
                    0x195 => { }, // ED NOP
                    0x196 => { }, // ED NOP
                    0x197 => { }, // ED NOP
                    0x198 => { }, // ED NOP
                    0x199 => { }, // ED NOP
                    0x19A => { }, // ED NOP
                    0x19B => { }, // ED NOP
                    0x19C => { }, // ED NOP
                    0x19D => { }, // ED NOP
                    0x19E => { }, // ED NOP
                    0x19F => { }, // ED NOP
                    0x1A0 => { self.step = 0x6C2; break :next; }, // LDI
                    0x1A1 => { self.step = 0x6CA; break :next; }, // CPI
                    0x1A2 => { self.step = 0x6D2; break :next; }, // INI
                    0x1A3 => { self.step = 0x6DA; break :next; }, // OUTI
                    0x1A4 => { }, // ED NOP
                    0x1A5 => { }, // ED NOP
                    0x1A6 => { }, // ED NOP
                    0x1A7 => { }, // ED NOP
                    0x1A8 => { self.step = 0x6E2; break :next; }, // LDD
                    0x1A9 => { self.step = 0x6EA; break :next; }, // CPD
                    0x1AA => { self.step = 0x6F2; break :next; }, // IND
                    0x1AB => { self.step = 0x6FA; break :next; }, // OUTD
                    0x1AC => { }, // ED NOP
                    0x1AD => { }, // ED NOP
                    0x1AE => { }, // ED NOP
                    0x1AF => { }, // ED NOP
                    0x1B0 => { self.step = 0x702; break :next; }, // LDIR
                    0x1B1 => { self.step = 0x70F; break :next; }, // CPIR
                    0x1B2 => { self.step = 0x71C; break :next; }, // INIR
                    0x1B3 => { self.step = 0x729; break :next; }, // OTIR
                    0x1B4 => { }, // ED NOP
                    0x1B5 => { }, // ED NOP
                    0x1B6 => { }, // ED NOP
                    0x1B7 => { }, // ED NOP
                    0x1B8 => { self.step = 0x736; break :next; }, // LDDR
                    0x1B9 => { self.step = 0x743; break :next; }, // CPDR
                    0x1BA => { self.step = 0x750; break :next; }, // INDR
                    0x1BB => { self.step = 0x75D; break :next; }, // OTDR
                    0x1BC => { }, // ED NOP
                    0x1BD => { }, // ED NOP
                    0x1BE => { }, // ED NOP
                    0x1BF => { }, // ED NOP
                    0x1C0 => { }, // ED NOP
                    0x1C1 => { }, // ED NOP
                    0x1C2 => { }, // ED NOP
                    0x1C3 => { }, // ED NOP
                    0x1C4 => { }, // ED NOP
                    0x1C5 => { }, // ED NOP
                    0x1C6 => { }, // ED NOP
                    0x1C7 => { }, // ED NOP
                    0x1C8 => { }, // ED NOP
                    0x1C9 => { }, // ED NOP
                    0x1CA => { }, // ED NOP
                    0x1CB => { }, // ED NOP
                    0x1CC => { }, // ED NOP
                    0x1CD => { }, // ED NOP
                    0x1CE => { }, // ED NOP
                    0x1CF => { }, // ED NOP
                    0x1D0 => { }, // ED NOP
                    0x1D1 => { }, // ED NOP
                    0x1D2 => { }, // ED NOP
                    0x1D3 => { }, // ED NOP
                    0x1D4 => { }, // ED NOP
                    0x1D5 => { }, // ED NOP
                    0x1D6 => { }, // ED NOP
                    0x1D7 => { }, // ED NOP
                    0x1D8 => { }, // ED NOP
                    0x1D9 => { }, // ED NOP
                    0x1DA => { }, // ED NOP
                    0x1DB => { }, // ED NOP
                    0x1DC => { }, // ED NOP
                    0x1DD => { }, // ED NOP
                    0x1DE => { }, // ED NOP
                    0x1DF => { }, // ED NOP
                    0x1E0 => { }, // ED NOP
                    0x1E1 => { }, // ED NOP
                    0x1E2 => { }, // ED NOP
                    0x1E3 => { }, // ED NOP
                    0x1E4 => { }, // ED NOP
                    0x1E5 => { }, // ED NOP
                    0x1E6 => { }, // ED NOP
                    0x1E7 => { }, // ED NOP
                    0x1E8 => { }, // ED NOP
                    0x1E9 => { }, // ED NOP
                    0x1EA => { }, // ED NOP
                    0x1EB => { }, // ED NOP
                    0x1EC => { }, // ED NOP
                    0x1ED => { }, // ED NOP
                    0x1EE => { }, // ED NOP
                    0x1EF => { }, // ED NOP
                    0x1F0 => { }, // ED NOP
                    0x1F1 => { }, // ED NOP
                    0x1F2 => { }, // ED NOP
                    0x1F3 => { }, // ED NOP
                    0x1F4 => { }, // ED NOP
                    0x1F5 => { }, // ED NOP
                    0x1F6 => { }, // ED NOP
                    0x1F7 => { }, // ED NOP
                    0x1F8 => { }, // ED NOP
                    0x1F9 => { }, // ED NOP
                    0x1FA => { }, // ED NOP
                    0x1FB => { }, // ED NOP
                    0x1FC => { }, // ED NOP
                    0x1FD => { }, // ED NOP
                    0x1FE => { }, // ED NOP
                    0x1FF => { }, // ED NOP
                    0x300 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x301; break :next; }, // LD BC,nn (cont...)
                    0x301 => { self.r[C] = gd(bus); self.step = 0x302; break :next; }, 
                    0x302 => { self.step = 0x303; break :next; }, 
                    0x303 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x304; break :next; }, 
                    0x304 => { self.r[B] = gd(bus); self.step = 0x305; break :next; }, 
                    0x305 => { }, 
                    0x306 => { if (wait(bus)) break :next; bus = mwr(bus, self.BC(), self.r[A]); self.r[WZL]=self.r[C] +% 1; self.r[WZH]=self.r[A]; self.step = 0x307; break :next; }, // LD (BC),A (cont...)
                    0x307 => { self.step = 0x308; break :next; }, 
                    0x308 => { }, 
                    0x309 => { self.step = 0x30A; break :next; }, // INC BC (cont...)
                    0x30A => { }, 
                    0x30B => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x30C; break :next; }, // LD B,n (cont...)
                    0x30C => { self.r[B] = gd(bus); self.step = 0x30D; break :next; }, 
                    0x30D => { }, 
                    0x30E => { self.step = 0x30F; break :next; }, // ADD HL,BC (cont...)
                    0x30F => { self.step = 0x310; break :next; }, 
                    0x310 => { self.step = 0x311; break :next; }, 
                    0x311 => { self.step = 0x312; break :next; }, 
                    0x312 => { self.step = 0x313; break :next; }, 
                    0x313 => { self.step = 0x314; break :next; }, 
                    0x314 => { }, 
                    0x315 => { if (wait(bus)) break :next; bus = mrd(bus, self.BC()); self.step = 0x316; break :next; }, // LD A,(BC) (cont...)
                    0x316 => { self.r[A] = gd(bus); self.setWZ(self.BC() +% 1); self.step = 0x317; break :next; }, 
                    0x317 => { }, 
                    0x318 => { self.step = 0x319; break :next; }, // DEC BC (cont...)
                    0x319 => { }, 
                    0x31A => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x31B; break :next; }, // LD C,n (cont...)
                    0x31B => { self.r[C] = gd(bus); self.step = 0x31C; break :next; }, 
                    0x31C => { }, 
                    0x31D => { self.step = 0x31E; break :next; }, // DJNZ (cont...)
                    0x31E => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x31F; break :next; }, 
                    0x31F => { self.dlatch = gd(bus); if (self.gotoZero(self.r[B], 0x320 + 5)) break :next; self.step = 0x320; break :next; }, 
                    0x320 => { self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc); self.step = 0x321; break :next; }, 
                    0x321 => { self.step = 0x322; break :next; }, 
                    0x322 => { self.step = 0x323; break :next; }, 
                    0x323 => { self.step = 0x324; break :next; }, 
                    0x324 => { self.step = 0x325; break :next; }, 
                    0x325 => { }, 
                    0x326 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x327; break :next; }, // LD DE,nn (cont...)
                    0x327 => { self.r[E] = gd(bus); self.step = 0x328; break :next; }, 
                    0x328 => { self.step = 0x329; break :next; }, 
                    0x329 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x32A; break :next; }, 
                    0x32A => { self.r[D] = gd(bus); self.step = 0x32B; break :next; }, 
                    0x32B => { }, 
                    0x32C => { if (wait(bus)) break :next; bus = mwr(bus, self.DE(), self.r[A]); self.r[WZL]=self.r[E] +% 1; self.r[WZH]=self.r[A]; self.step = 0x32D; break :next; }, // LD (DE),A (cont...)
                    0x32D => { self.step = 0x32E; break :next; }, 
                    0x32E => { }, 
                    0x32F => { self.step = 0x330; break :next; }, // INC DE (cont...)
                    0x330 => { }, 
                    0x331 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x332; break :next; }, // LD D,n (cont...)
                    0x332 => { self.r[D] = gd(bus); self.step = 0x333; break :next; }, 
                    0x333 => { }, 
                    0x334 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x335; break :next; }, // JR d (cont...)
                    0x335 => { self.dlatch = gd(bus); self.step = 0x336; break :next; }, 
                    0x336 => { self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc); self.step = 0x337; break :next; }, 
                    0x337 => { self.step = 0x338; break :next; }, 
                    0x338 => { self.step = 0x339; break :next; }, 
                    0x339 => { self.step = 0x33A; break :next; }, 
                    0x33A => { self.step = 0x33B; break :next; }, 
                    0x33B => { }, 
                    0x33C => { self.step = 0x33D; break :next; }, // ADD HL,DE (cont...)
                    0x33D => { self.step = 0x33E; break :next; }, 
                    0x33E => { self.step = 0x33F; break :next; }, 
                    0x33F => { self.step = 0x340; break :next; }, 
                    0x340 => { self.step = 0x341; break :next; }, 
                    0x341 => { self.step = 0x342; break :next; }, 
                    0x342 => { }, 
                    0x343 => { if (wait(bus)) break :next; bus = mrd(bus, self.DE()); self.step = 0x344; break :next; }, // LD A,(DE) (cont...)
                    0x344 => { self.r[A] = gd(bus); self.setWZ(self.DE() +% 1); self.step = 0x345; break :next; }, 
                    0x345 => { }, 
                    0x346 => { self.step = 0x347; break :next; }, // DEC DE (cont...)
                    0x347 => { }, 
                    0x348 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x349; break :next; }, // LD E,n (cont...)
                    0x349 => { self.r[E] = gd(bus); self.step = 0x34A; break :next; }, 
                    0x34A => { }, 
                    0x34B => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x34C; break :next; }, // JR NZ,d (cont...)
                    0x34C => { self.dlatch = gd(bus); if (self.gotoNZ(0x34D + 5)) break :next; self.step = 0x34D; break :next; }, 
                    0x34D => { self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc); self.step = 0x34E; break :next; }, 
                    0x34E => { self.step = 0x34F; break :next; }, 
                    0x34F => { self.step = 0x350; break :next; }, 
                    0x350 => { self.step = 0x351; break :next; }, 
                    0x351 => { self.step = 0x352; break :next; }, 
                    0x352 => { }, 
                    0x353 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x354; break :next; }, // LD HL,nn (cont...)
                    0x354 => { self.r[L + self.rixy] = gd(bus); self.step = 0x355; break :next; }, 
                    0x355 => { self.step = 0x356; break :next; }, 
                    0x356 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x357; break :next; }, 
                    0x357 => { self.r[H + self.rixy] = gd(bus); self.step = 0x358; break :next; }, 
                    0x358 => { }, 
                    0x359 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x35A; break :next; }, // LD (HL),nn (cont...)
                    0x35A => { self.r[WZL] = gd(bus); self.step = 0x35B; break :next; }, 
                    0x35B => { self.step = 0x35C; break :next; }, 
                    0x35C => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x35D; break :next; }, 
                    0x35D => { self.r[WZH] = gd(bus); self.step = 0x35E; break :next; }, 
                    0x35E => { self.step = 0x35F; break :next; }, 
                    0x35F => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[L + self.rixy]); self.incWZ(); self.step = 0x360; break :next; }, 
                    0x360 => { self.step = 0x361; break :next; }, 
                    0x361 => { self.step = 0x362; break :next; }, 
                    0x362 => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[H + self.rixy]); self.step = 0x363; break :next; }, 
                    0x363 => { self.step = 0x364; break :next; }, 
                    0x364 => { }, 
                    0x365 => { self.step = 0x366; break :next; }, // INC HL (cont...)
                    0x366 => { }, 
                    0x367 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x368; break :next; }, // LD H,n (cont...)
                    0x368 => { self.r[H + self.rixy] = gd(bus); self.step = 0x369; break :next; }, 
                    0x369 => { }, 
                    0x36A => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x36B; break :next; }, // JR Z,d (cont...)
                    0x36B => { self.dlatch = gd(bus); if (self.gotoZ(0x36C + 5)) break :next; self.step = 0x36C; break :next; }, 
                    0x36C => { self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc); self.step = 0x36D; break :next; }, 
                    0x36D => { self.step = 0x36E; break :next; }, 
                    0x36E => { self.step = 0x36F; break :next; }, 
                    0x36F => { self.step = 0x370; break :next; }, 
                    0x370 => { self.step = 0x371; break :next; }, 
                    0x371 => { }, 
                    0x372 => { self.step = 0x373; break :next; }, // ADD HL,HL (cont...)
                    0x373 => { self.step = 0x374; break :next; }, 
                    0x374 => { self.step = 0x375; break :next; }, 
                    0x375 => { self.step = 0x376; break :next; }, 
                    0x376 => { self.step = 0x377; break :next; }, 
                    0x377 => { self.step = 0x378; break :next; }, 
                    0x378 => { }, 
                    0x379 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x37A; break :next; }, // LD HL,(nn) (cont...)
                    0x37A => { self.r[WZL] = gd(bus); self.step = 0x37B; break :next; }, 
                    0x37B => { self.step = 0x37C; break :next; }, 
                    0x37C => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x37D; break :next; }, 
                    0x37D => { self.r[WZH] = gd(bus); self.step = 0x37E; break :next; }, 
                    0x37E => { self.step = 0x37F; break :next; }, 
                    0x37F => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.incWZ(); self.step = 0x380; break :next; }, 
                    0x380 => { self.r[L + self.rixy] = gd(bus); self.step = 0x381; break :next; }, 
                    0x381 => { self.step = 0x382; break :next; }, 
                    0x382 => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.step = 0x383; break :next; }, 
                    0x383 => { self.r[H + self.rixy] = gd(bus); self.step = 0x384; break :next; }, 
                    0x384 => { }, 
                    0x385 => { self.step = 0x386; break :next; }, // DEC HL (cont...)
                    0x386 => { }, 
                    0x387 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x388; break :next; }, // LD L,n (cont...)
                    0x388 => { self.r[L + self.rixy] = gd(bus); self.step = 0x389; break :next; }, 
                    0x389 => { }, 
                    0x38A => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x38B; break :next; }, // JR NC,d (cont...)
                    0x38B => { self.dlatch = gd(bus); if (self.gotoNC(0x38C + 5)) break :next; self.step = 0x38C; break :next; }, 
                    0x38C => { self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc); self.step = 0x38D; break :next; }, 
                    0x38D => { self.step = 0x38E; break :next; }, 
                    0x38E => { self.step = 0x38F; break :next; }, 
                    0x38F => { self.step = 0x390; break :next; }, 
                    0x390 => { self.step = 0x391; break :next; }, 
                    0x391 => { }, 
                    0x392 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x393; break :next; }, // LD SP,nn (cont...)
                    0x393 => { self.r[SPL] = gd(bus); self.step = 0x394; break :next; }, 
                    0x394 => { self.step = 0x395; break :next; }, 
                    0x395 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x396; break :next; }, 
                    0x396 => { self.r[SPH] = gd(bus); self.step = 0x397; break :next; }, 
                    0x397 => { }, 
                    0x398 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x399; break :next; }, // LD (HL),A (cont...)
                    0x399 => { self.r[WZL] = gd(bus); self.step = 0x39A; break :next; }, 
                    0x39A => { self.step = 0x39B; break :next; }, 
                    0x39B => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x39C; break :next; }, 
                    0x39C => { self.r[WZH] = gd(bus); self.step = 0x39D; break :next; }, 
                    0x39D => { self.step = 0x39E; break :next; }, 
                    0x39E => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[A]); self.incWZ(); self.r[WZH]=self.r[A]; self.step = 0x39F; break :next; }, 
                    0x39F => { self.step = 0x3A0; break :next; }, 
                    0x3A0 => { }, 
                    0x3A1 => { self.step = 0x3A2; break :next; }, // INC SP (cont...)
                    0x3A2 => { }, 
                    0x3A3 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3A4; break :next; }, // INC (HL) (cont...)
                    0x3A4 => { self.dlatch = gd(bus); self.step = 0x3A5; break :next; }, 
                    0x3A5 => { self.dlatch=self.inc8(self.dlatch); self.step = 0x3A6; break :next; }, 
                    0x3A6 => { self.step = 0x3A7; break :next; }, 
                    0x3A7 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.dlatch); self.step = 0x3A8; break :next; }, 
                    0x3A8 => { self.step = 0x3A9; break :next; }, 
                    0x3A9 => { }, 
                    0x3AA => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3AB; break :next; }, // DEC (HL) (cont...)
                    0x3AB => { self.dlatch = gd(bus); self.step = 0x3AC; break :next; }, 
                    0x3AC => { self.dlatch=self.dec8(self.dlatch); self.step = 0x3AD; break :next; }, 
                    0x3AD => { self.step = 0x3AE; break :next; }, 
                    0x3AE => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.dlatch); self.step = 0x3AF; break :next; }, 
                    0x3AF => { self.step = 0x3B0; break :next; }, 
                    0x3B0 => { }, 
                    0x3B1 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x3B2; break :next; }, // LD (HL),n (cont...)
                    0x3B2 => { self.dlatch = gd(bus); self.step = 0x3B3; break :next; }, 
                    0x3B3 => { self.step = 0x3B4; break :next; }, 
                    0x3B4 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.dlatch); self.step = 0x3B5; break :next; }, 
                    0x3B5 => { self.step = 0x3B6; break :next; }, 
                    0x3B6 => { }, 
                    0x3B7 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x3B8; break :next; }, // JR C,d (cont...)
                    0x3B8 => { self.dlatch = gd(bus); if (self.gotoC(0x3B9 + 5)) break :next; self.step = 0x3B9; break :next; }, 
                    0x3B9 => { self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc); self.step = 0x3BA; break :next; }, 
                    0x3BA => { self.step = 0x3BB; break :next; }, 
                    0x3BB => { self.step = 0x3BC; break :next; }, 
                    0x3BC => { self.step = 0x3BD; break :next; }, 
                    0x3BD => { self.step = 0x3BE; break :next; }, 
                    0x3BE => { }, 
                    0x3BF => { self.step = 0x3C0; break :next; }, // ADD HL,SP (cont...)
                    0x3C0 => { self.step = 0x3C1; break :next; }, 
                    0x3C1 => { self.step = 0x3C2; break :next; }, 
                    0x3C2 => { self.step = 0x3C3; break :next; }, 
                    0x3C3 => { self.step = 0x3C4; break :next; }, 
                    0x3C4 => { self.step = 0x3C5; break :next; }, 
                    0x3C5 => { }, 
                    0x3C6 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x3C7; break :next; }, // LD A,(nn) (cont...)
                    0x3C7 => { self.r[WZL] = gd(bus); self.step = 0x3C8; break :next; }, 
                    0x3C8 => { self.step = 0x3C9; break :next; }, 
                    0x3C9 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x3CA; break :next; }, 
                    0x3CA => { self.r[WZH] = gd(bus); self.step = 0x3CB; break :next; }, 
                    0x3CB => { self.step = 0x3CC; break :next; }, 
                    0x3CC => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.incWZ(); self.step = 0x3CD; break :next; }, 
                    0x3CD => { self.r[A] = gd(bus); self.step = 0x3CE; break :next; }, 
                    0x3CE => { }, 
                    0x3CF => { self.step = 0x3D0; break :next; }, // DEC SP (cont...)
                    0x3D0 => { }, 
                    0x3D1 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x3D2; break :next; }, // LD A,n (cont...)
                    0x3D2 => { self.r[A] = gd(bus); self.step = 0x3D3; break :next; }, 
                    0x3D3 => { }, 
                    0x3D4 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3D5; break :next; }, // LD B,(HL) (cont...)
                    0x3D5 => { self.r[B] = gd(bus); self.step = 0x3D6; break :next; }, 
                    0x3D6 => { }, 
                    0x3D7 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3D8; break :next; }, // LD C,(HL) (cont...)
                    0x3D8 => { self.r[C] = gd(bus); self.step = 0x3D9; break :next; }, 
                    0x3D9 => { }, 
                    0x3DA => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3DB; break :next; }, // LD D,(HL) (cont...)
                    0x3DB => { self.r[D] = gd(bus); self.step = 0x3DC; break :next; }, 
                    0x3DC => { }, 
                    0x3DD => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3DE; break :next; }, // LD E,(HL) (cont...)
                    0x3DE => { self.r[E] = gd(bus); self.step = 0x3DF; break :next; }, 
                    0x3DF => { }, 
                    0x3E0 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3E1; break :next; }, // LD H,(HL) (cont...)
                    0x3E1 => { self.r[H] = gd(bus); self.step = 0x3E2; break :next; }, 
                    0x3E2 => { }, 
                    0x3E3 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3E4; break :next; }, // LD L,(HL) (cont...)
                    0x3E4 => { self.r[L] = gd(bus); self.step = 0x3E5; break :next; }, 
                    0x3E5 => { }, 
                    0x3E6 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[B]); self.step = 0x3E7; break :next; }, // LD (HL),B (cont...)
                    0x3E7 => { self.step = 0x3E8; break :next; }, 
                    0x3E8 => { }, 
                    0x3E9 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[C]); self.step = 0x3EA; break :next; }, // LD (HL),C (cont...)
                    0x3EA => { self.step = 0x3EB; break :next; }, 
                    0x3EB => { }, 
                    0x3EC => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[D]); self.step = 0x3ED; break :next; }, // LD (HL),D (cont...)
                    0x3ED => { self.step = 0x3EE; break :next; }, 
                    0x3EE => { }, 
                    0x3EF => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[E]); self.step = 0x3F0; break :next; }, // LD (HL),E (cont...)
                    0x3F0 => { self.step = 0x3F1; break :next; }, 
                    0x3F1 => { }, 
                    0x3F2 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[H]); self.step = 0x3F3; break :next; }, // LD (HL),H (cont...)
                    0x3F3 => { self.step = 0x3F4; break :next; }, 
                    0x3F4 => { }, 
                    0x3F5 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[L]); self.step = 0x3F6; break :next; }, // LD (HL),L (cont...)
                    0x3F6 => { self.step = 0x3F7; break :next; }, 
                    0x3F7 => { }, 
                    0x3F8 => { if (wait(bus)) break :next; bus = mwr(bus, self.addr, self.r[A]); self.step = 0x3F9; break :next; }, // LD (HL),A (cont...)
                    0x3F9 => { self.step = 0x3FA; break :next; }, 
                    0x3FA => { }, 
                    0x3FB => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3FC; break :next; }, // LD A,(HL) (cont...)
                    0x3FC => { self.r[A] = gd(bus); self.step = 0x3FD; break :next; }, 
                    0x3FD => { }, 
                    0x3FE => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x3FF; break :next; }, // ADD (HL) (cont...)
                    0x3FF => { self.dlatch = gd(bus); self.step = 0x400; break :next; }, 
                    0x400 => { self.add8(self.dlatch); }, 
                    0x401 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x402; break :next; }, // ADC (HL) (cont...)
                    0x402 => { self.dlatch = gd(bus); self.step = 0x403; break :next; }, 
                    0x403 => { self.adc8(self.dlatch); }, 
                    0x404 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x405; break :next; }, // SUB (HL) (cont...)
                    0x405 => { self.dlatch = gd(bus); self.step = 0x406; break :next; }, 
                    0x406 => { self.sub8(self.dlatch); }, 
                    0x407 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x408; break :next; }, // SBC (HL) (cont...)
                    0x408 => { self.dlatch = gd(bus); self.step = 0x409; break :next; }, 
                    0x409 => { self.sbc8(self.dlatch); }, 
                    0x40A => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x40B; break :next; }, // AND (HL) (cont...)
                    0x40B => { self.dlatch = gd(bus); self.step = 0x40C; break :next; }, 
                    0x40C => { self.and8(self.dlatch); }, 
                    0x40D => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x40E; break :next; }, // XOR (HL) (cont...)
                    0x40E => { self.dlatch = gd(bus); self.step = 0x40F; break :next; }, 
                    0x40F => { self.xor8(self.dlatch); }, 
                    0x410 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x411; break :next; }, // OR (HL) (cont...)
                    0x411 => { self.dlatch = gd(bus); self.step = 0x412; break :next; }, 
                    0x412 => { self.or8(self.dlatch); }, 
                    0x413 => { if (wait(bus)) break :next; bus = mrd(bus, self.addr); self.step = 0x414; break :next; }, // CP (HL) (cont...)
                    0x414 => { self.dlatch = gd(bus); self.step = 0x415; break :next; }, 
                    0x415 => { self.cp8(self.dlatch); }, 
                    0x416 => { self.step = 0x417; break :next; }, // RET NZ (cont...)
                    0x417 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x418; break :next; }, 
                    0x418 => { self.r[WZL] = gd(bus); self.step = 0x419; break :next; }, 
                    0x419 => { self.step = 0x41A; break :next; }, 
                    0x41A => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x41B; break :next; }, 
                    0x41B => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x41C; break :next; }, 
                    0x41C => { }, 
                    0x41D => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x41E; break :next; }, // POP BC (cont...)
                    0x41E => { self.r[C] = gd(bus); self.step = 0x41F; break :next; }, 
                    0x41F => { self.step = 0x420; break :next; }, 
                    0x420 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x421; break :next; }, 
                    0x421 => { self.r[B] = gd(bus); self.step = 0x422; break :next; }, 
                    0x422 => { }, 
                    0x423 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x424; break :next; }, // JP NZ,nn (cont...)
                    0x424 => { self.r[WZL] = gd(bus); self.step = 0x425; break :next; }, 
                    0x425 => { self.step = 0x426; break :next; }, 
                    0x426 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x427; break :next; }, 
                    0x427 => { self.r[WZH] = gd(bus); if (self.testNZ()) self.pc = self.WZ(); self.step = 0x428; break :next; }, 
                    0x428 => { }, 
                    0x429 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x42A; break :next; }, // JP nn (cont...)
                    0x42A => { self.r[WZL] = gd(bus); self.step = 0x42B; break :next; }, 
                    0x42B => { self.step = 0x42C; break :next; }, 
                    0x42C => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x42D; break :next; }, 
                    0x42D => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x42E; break :next; }, 
                    0x42E => { }, 
                    0x42F => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x430; break :next; }, // CALL NZ,nn (cont...)
                    0x430 => { self.r[WZL] = gd(bus); self.step = 0x431; break :next; }, 
                    0x431 => { self.step = 0x432; break :next; }, 
                    0x432 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x433; break :next; }, 
                    0x433 => { self.r[WZH] = gd(bus); if (self.gotoNZ(0x434 + 7)) break: next; self.step = 0x434; break :next; }, 
                    0x434 => { self.decSP(); self.step = 0x435; break :next; }, 
                    0x435 => { self.step = 0x436; break :next; }, 
                    0x436 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x437; break :next; }, 
                    0x437 => { self.step = 0x438; break :next; }, 
                    0x438 => { self.step = 0x439; break :next; }, 
                    0x439 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x43A; break :next; }, 
                    0x43A => { self.step = 0x43B; break :next; }, 
                    0x43B => { }, 
                    0x43C => { self.step = 0x43D; break :next; }, // PUSH BC (cont...)
                    0x43D => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[B]); self.decSP(); self.step = 0x43E; break :next; }, 
                    0x43E => { self.step = 0x43F; break :next; }, 
                    0x43F => { self.step = 0x440; break :next; }, 
                    0x440 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[C]); self.step = 0x441; break :next; }, 
                    0x441 => { self.step = 0x442; break :next; }, 
                    0x442 => { }, 
                    0x443 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x444; break :next; }, // ADD n (cont...)
                    0x444 => { self.dlatch = gd(bus); self.step = 0x445; break :next; }, 
                    0x445 => { self.add8(self.dlatch); }, 
                    0x446 => { self.step = 0x447; break :next; }, // RST 0 (cont...)
                    0x447 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x448; break :next; }, 
                    0x448 => { self.step = 0x449; break :next; }, 
                    0x449 => { self.step = 0x44A; break :next; }, 
                    0x44A => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x0; self.setWZ(self.pc); self.step = 0x44B; break :next; }, 
                    0x44B => { self.step = 0x44C; break :next; }, 
                    0x44C => { }, 
                    0x44D => { self.step = 0x44E; break :next; }, // RET Z (cont...)
                    0x44E => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x44F; break :next; }, 
                    0x44F => { self.r[WZL] = gd(bus); self.step = 0x450; break :next; }, 
                    0x450 => { self.step = 0x451; break :next; }, 
                    0x451 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x452; break :next; }, 
                    0x452 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x453; break :next; }, 
                    0x453 => { }, 
                    0x454 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x455; break :next; }, // RET (cont...)
                    0x455 => { self.r[WZL] = gd(bus); self.step = 0x456; break :next; }, 
                    0x456 => { self.step = 0x457; break :next; }, 
                    0x457 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x458; break :next; }, 
                    0x458 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x459; break :next; }, 
                    0x459 => { }, 
                    0x45A => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x45B; break :next; }, // JP Z,nn (cont...)
                    0x45B => { self.r[WZL] = gd(bus); self.step = 0x45C; break :next; }, 
                    0x45C => { self.step = 0x45D; break :next; }, 
                    0x45D => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x45E; break :next; }, 
                    0x45E => { self.r[WZH] = gd(bus); if (self.testZ()) self.pc = self.WZ(); self.step = 0x45F; break :next; }, 
                    0x45F => { }, 
                    0x460 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x461; break :next; }, // CALL Z,nn (cont...)
                    0x461 => { self.r[WZL] = gd(bus); self.step = 0x462; break :next; }, 
                    0x462 => { self.step = 0x463; break :next; }, 
                    0x463 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x464; break :next; }, 
                    0x464 => { self.r[WZH] = gd(bus); if (self.gotoZ(0x465 + 7)) break: next; self.step = 0x465; break :next; }, 
                    0x465 => { self.decSP(); self.step = 0x466; break :next; }, 
                    0x466 => { self.step = 0x467; break :next; }, 
                    0x467 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x468; break :next; }, 
                    0x468 => { self.step = 0x469; break :next; }, 
                    0x469 => { self.step = 0x46A; break :next; }, 
                    0x46A => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x46B; break :next; }, 
                    0x46B => { self.step = 0x46C; break :next; }, 
                    0x46C => { }, 
                    0x46D => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x46E; break :next; }, // CALL nn (cont...)
                    0x46E => { self.r[WZL] = gd(bus); self.step = 0x46F; break :next; }, 
                    0x46F => { self.step = 0x470; break :next; }, 
                    0x470 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x471; break :next; }, 
                    0x471 => { self.r[WZH] = gd(bus); self.step = 0x472; break :next; }, 
                    0x472 => { self.decSP(); self.step = 0x473; break :next; }, 
                    0x473 => { self.step = 0x474; break :next; }, 
                    0x474 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x475; break :next; }, 
                    0x475 => { self.step = 0x476; break :next; }, 
                    0x476 => { self.step = 0x477; break :next; }, 
                    0x477 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x478; break :next; }, 
                    0x478 => { self.step = 0x479; break :next; }, 
                    0x479 => { }, 
                    0x47A => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x47B; break :next; }, // ADC n (cont...)
                    0x47B => { self.dlatch = gd(bus); self.step = 0x47C; break :next; }, 
                    0x47C => { self.adc8(self.dlatch); }, 
                    0x47D => { self.step = 0x47E; break :next; }, // RST 8 (cont...)
                    0x47E => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x47F; break :next; }, 
                    0x47F => { self.step = 0x480; break :next; }, 
                    0x480 => { self.step = 0x481; break :next; }, 
                    0x481 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x8; self.setWZ(self.pc); self.step = 0x482; break :next; }, 
                    0x482 => { self.step = 0x483; break :next; }, 
                    0x483 => { }, 
                    0x484 => { self.step = 0x485; break :next; }, // RET NC (cont...)
                    0x485 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x486; break :next; }, 
                    0x486 => { self.r[WZL] = gd(bus); self.step = 0x487; break :next; }, 
                    0x487 => { self.step = 0x488; break :next; }, 
                    0x488 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x489; break :next; }, 
                    0x489 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x48A; break :next; }, 
                    0x48A => { }, 
                    0x48B => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x48C; break :next; }, // POP DE (cont...)
                    0x48C => { self.r[E] = gd(bus); self.step = 0x48D; break :next; }, 
                    0x48D => { self.step = 0x48E; break :next; }, 
                    0x48E => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x48F; break :next; }, 
                    0x48F => { self.r[D] = gd(bus); self.step = 0x490; break :next; }, 
                    0x490 => { }, 
                    0x491 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x492; break :next; }, // JP NC,nn (cont...)
                    0x492 => { self.r[WZL] = gd(bus); self.step = 0x493; break :next; }, 
                    0x493 => { self.step = 0x494; break :next; }, 
                    0x494 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x495; break :next; }, 
                    0x495 => { self.r[WZH] = gd(bus); if (self.testNC()) self.pc = self.WZ(); self.step = 0x496; break :next; }, 
                    0x496 => { }, 
                    0x497 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x498; break :next; }, // OUT (n),A (cont...)
                    0x498 => { self.r[WZL] = gd(bus); self.r[WZH] = self.r[A]; self.step = 0x499; break :next; }, 
                    0x499 => { self.step = 0x49A; break :next; }, 
                    0x49A => { bus = iowr(bus, self.WZ(), self.r[A]); self.step = 0x49B; break :next; }, 
                    0x49B => { if (wait(bus)) break :next; self.r[WZL] +%=1; self.step = 0x49C; break :next; }, 
                    0x49C => { self.step = 0x49D; break :next; }, 
                    0x49D => { }, 
                    0x49E => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x49F; break :next; }, // CALL NC,nn (cont...)
                    0x49F => { self.r[WZL] = gd(bus); self.step = 0x4A0; break :next; }, 
                    0x4A0 => { self.step = 0x4A1; break :next; }, 
                    0x4A1 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4A2; break :next; }, 
                    0x4A2 => { self.r[WZH] = gd(bus); if (self.gotoNC(0x4A3 + 7)) break: next; self.step = 0x4A3; break :next; }, 
                    0x4A3 => { self.decSP(); self.step = 0x4A4; break :next; }, 
                    0x4A4 => { self.step = 0x4A5; break :next; }, 
                    0x4A5 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x4A6; break :next; }, 
                    0x4A6 => { self.step = 0x4A7; break :next; }, 
                    0x4A7 => { self.step = 0x4A8; break :next; }, 
                    0x4A8 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x4A9; break :next; }, 
                    0x4A9 => { self.step = 0x4AA; break :next; }, 
                    0x4AA => { }, 
                    0x4AB => { self.step = 0x4AC; break :next; }, // PUSH DE (cont...)
                    0x4AC => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[D]); self.decSP(); self.step = 0x4AD; break :next; }, 
                    0x4AD => { self.step = 0x4AE; break :next; }, 
                    0x4AE => { self.step = 0x4AF; break :next; }, 
                    0x4AF => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[E]); self.step = 0x4B0; break :next; }, 
                    0x4B0 => { self.step = 0x4B1; break :next; }, 
                    0x4B1 => { }, 
                    0x4B2 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4B3; break :next; }, // SUB n (cont...)
                    0x4B3 => { self.dlatch = gd(bus); self.step = 0x4B4; break :next; }, 
                    0x4B4 => { self.sub8(self.dlatch); }, 
                    0x4B5 => { self.step = 0x4B6; break :next; }, // RST 10 (cont...)
                    0x4B6 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x4B7; break :next; }, 
                    0x4B7 => { self.step = 0x4B8; break :next; }, 
                    0x4B8 => { self.step = 0x4B9; break :next; }, 
                    0x4B9 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x10; self.setWZ(self.pc); self.step = 0x4BA; break :next; }, 
                    0x4BA => { self.step = 0x4BB; break :next; }, 
                    0x4BB => { }, 
                    0x4BC => { self.step = 0x4BD; break :next; }, // RET C (cont...)
                    0x4BD => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x4BE; break :next; }, 
                    0x4BE => { self.r[WZL] = gd(bus); self.step = 0x4BF; break :next; }, 
                    0x4BF => { self.step = 0x4C0; break :next; }, 
                    0x4C0 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x4C1; break :next; }, 
                    0x4C1 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x4C2; break :next; }, 
                    0x4C2 => { }, 
                    0x4C3 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4C4; break :next; }, // JP C,nn (cont...)
                    0x4C4 => { self.r[WZL] = gd(bus); self.step = 0x4C5; break :next; }, 
                    0x4C5 => { self.step = 0x4C6; break :next; }, 
                    0x4C6 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4C7; break :next; }, 
                    0x4C7 => { self.r[WZH] = gd(bus); if (self.testC()) self.pc = self.WZ(); self.step = 0x4C8; break :next; }, 
                    0x4C8 => { }, 
                    0x4C9 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4CA; break :next; }, // IN A,(n) (cont...)
                    0x4CA => { self.r[WZL] = gd(bus); self.r[WZH] = self.r[A]; self.step = 0x4CB; break :next; }, 
                    0x4CB => { self.step = 0x4CC; break :next; }, 
                    0x4CC => { self.step = 0x4CD; break :next; }, 
                    0x4CD => { if (wait(bus)) break :next; bus = iord(bus, self.WZ()); self.incWZ(); self.step = 0x4CE; break :next; }, 
                    0x4CE => { self.r[A] = gd(bus); self.step = 0x4CF; break :next; }, 
                    0x4CF => { }, 
                    0x4D0 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4D1; break :next; }, // CALL C,nn (cont...)
                    0x4D1 => { self.r[WZL] = gd(bus); self.step = 0x4D2; break :next; }, 
                    0x4D2 => { self.step = 0x4D3; break :next; }, 
                    0x4D3 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4D4; break :next; }, 
                    0x4D4 => { self.r[WZH] = gd(bus); if (self.gotoC(0x4D5 + 7)) break: next; self.step = 0x4D5; break :next; }, 
                    0x4D5 => { self.decSP(); self.step = 0x4D6; break :next; }, 
                    0x4D6 => { self.step = 0x4D7; break :next; }, 
                    0x4D7 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x4D8; break :next; }, 
                    0x4D8 => { self.step = 0x4D9; break :next; }, 
                    0x4D9 => { self.step = 0x4DA; break :next; }, 
                    0x4DA => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x4DB; break :next; }, 
                    0x4DB => { self.step = 0x4DC; break :next; }, 
                    0x4DC => { }, 
                    0x4DD => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4DE; break :next; }, // SBC n (cont...)
                    0x4DE => { self.dlatch = gd(bus); self.step = 0x4DF; break :next; }, 
                    0x4DF => { self.sbc8(self.dlatch); }, 
                    0x4E0 => { self.step = 0x4E1; break :next; }, // RST 18 (cont...)
                    0x4E1 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x4E2; break :next; }, 
                    0x4E2 => { self.step = 0x4E3; break :next; }, 
                    0x4E3 => { self.step = 0x4E4; break :next; }, 
                    0x4E4 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x18; self.setWZ(self.pc); self.step = 0x4E5; break :next; }, 
                    0x4E5 => { self.step = 0x4E6; break :next; }, 
                    0x4E6 => { }, 
                    0x4E7 => { self.step = 0x4E8; break :next; }, // RET PO (cont...)
                    0x4E8 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x4E9; break :next; }, 
                    0x4E9 => { self.r[WZL] = gd(bus); self.step = 0x4EA; break :next; }, 
                    0x4EA => { self.step = 0x4EB; break :next; }, 
                    0x4EB => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x4EC; break :next; }, 
                    0x4EC => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x4ED; break :next; }, 
                    0x4ED => { }, 
                    0x4EE => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x4EF; break :next; }, // POP HL (cont...)
                    0x4EF => { self.r[L + self.rixy] = gd(bus); self.step = 0x4F0; break :next; }, 
                    0x4F0 => { self.step = 0x4F1; break :next; }, 
                    0x4F1 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x4F2; break :next; }, 
                    0x4F2 => { self.r[H + self.rixy] = gd(bus); self.step = 0x4F3; break :next; }, 
                    0x4F3 => { }, 
                    0x4F4 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4F5; break :next; }, // JP PO,nn (cont...)
                    0x4F5 => { self.r[WZL] = gd(bus); self.step = 0x4F6; break :next; }, 
                    0x4F6 => { self.step = 0x4F7; break :next; }, 
                    0x4F7 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x4F8; break :next; }, 
                    0x4F8 => { self.r[WZH] = gd(bus); if (self.testPO()) self.pc = self.WZ(); self.step = 0x4F9; break :next; }, 
                    0x4F9 => { }, 
                    0x4FA => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.step = 0x4FB; break :next; }, // EX (SP),HL (cont...)
                    0x4FB => { self.r[WZL] = gd(bus); self.step = 0x4FC; break :next; }, 
                    0x4FC => { self.step = 0x4FD; break :next; }, 
                    0x4FD => { if (wait(bus)) break :next; bus = mrd(bus, self.SP() +% 1); self.step = 0x4FE; break :next; }, 
                    0x4FE => { self.r[WZH] = gd(bus); self.step = 0x4FF; break :next; }, 
                    0x4FF => { self.step = 0x500; break :next; }, 
                    0x500 => { self.step = 0x501; break :next; }, 
                    0x501 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP() +% 1, self.r[H + self.rixy]); self.step = 0x502; break :next; }, 
                    0x502 => { self.step = 0x503; break :next; }, 
                    0x503 => { self.step = 0x504; break :next; }, 
                    0x504 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[L + self.rixy]); self.setHLIXY(self.WZ()); self.step = 0x505; break :next; }, 
                    0x505 => { self.step = 0x506; break :next; }, 
                    0x506 => { self.step = 0x507; break :next; }, 
                    0x507 => { self.step = 0x508; break :next; }, 
                    0x508 => { }, 
                    0x509 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x50A; break :next; }, // CALL PO,nn (cont...)
                    0x50A => { self.r[WZL] = gd(bus); self.step = 0x50B; break :next; }, 
                    0x50B => { self.step = 0x50C; break :next; }, 
                    0x50C => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x50D; break :next; }, 
                    0x50D => { self.r[WZH] = gd(bus); if (self.gotoPO(0x50E + 7)) break: next; self.step = 0x50E; break :next; }, 
                    0x50E => { self.decSP(); self.step = 0x50F; break :next; }, 
                    0x50F => { self.step = 0x510; break :next; }, 
                    0x510 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x511; break :next; }, 
                    0x511 => { self.step = 0x512; break :next; }, 
                    0x512 => { self.step = 0x513; break :next; }, 
                    0x513 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x514; break :next; }, 
                    0x514 => { self.step = 0x515; break :next; }, 
                    0x515 => { }, 
                    0x516 => { self.step = 0x517; break :next; }, // PUSH HL (cont...)
                    0x517 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[H + self.rixy]); self.decSP(); self.step = 0x518; break :next; }, 
                    0x518 => { self.step = 0x519; break :next; }, 
                    0x519 => { self.step = 0x51A; break :next; }, 
                    0x51A => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[L + self.rixy]); self.step = 0x51B; break :next; }, 
                    0x51B => { self.step = 0x51C; break :next; }, 
                    0x51C => { }, 
                    0x51D => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x51E; break :next; }, // AND n (cont...)
                    0x51E => { self.dlatch = gd(bus); self.step = 0x51F; break :next; }, 
                    0x51F => { self.and8(self.dlatch); }, 
                    0x520 => { self.step = 0x521; break :next; }, // RST 20 (cont...)
                    0x521 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x522; break :next; }, 
                    0x522 => { self.step = 0x523; break :next; }, 
                    0x523 => { self.step = 0x524; break :next; }, 
                    0x524 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x20; self.setWZ(self.pc); self.step = 0x525; break :next; }, 
                    0x525 => { self.step = 0x526; break :next; }, 
                    0x526 => { }, 
                    0x527 => { self.step = 0x528; break :next; }, // RET PE (cont...)
                    0x528 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x529; break :next; }, 
                    0x529 => { self.r[WZL] = gd(bus); self.step = 0x52A; break :next; }, 
                    0x52A => { self.step = 0x52B; break :next; }, 
                    0x52B => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x52C; break :next; }, 
                    0x52C => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x52D; break :next; }, 
                    0x52D => { }, 
                    0x52E => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x52F; break :next; }, // JP PE,nn (cont...)
                    0x52F => { self.r[WZL] = gd(bus); self.step = 0x530; break :next; }, 
                    0x530 => { self.step = 0x531; break :next; }, 
                    0x531 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x532; break :next; }, 
                    0x532 => { self.r[WZH] = gd(bus); if (self.testPE()) self.pc = self.WZ(); self.step = 0x533; break :next; }, 
                    0x533 => { }, 
                    0x534 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x535; break :next; }, // CALL PE,nn (cont...)
                    0x535 => { self.r[WZL] = gd(bus); self.step = 0x536; break :next; }, 
                    0x536 => { self.step = 0x537; break :next; }, 
                    0x537 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x538; break :next; }, 
                    0x538 => { self.r[WZH] = gd(bus); if (self.gotoPE(0x539 + 7)) break: next; self.step = 0x539; break :next; }, 
                    0x539 => { self.decSP(); self.step = 0x53A; break :next; }, 
                    0x53A => { self.step = 0x53B; break :next; }, 
                    0x53B => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x53C; break :next; }, 
                    0x53C => { self.step = 0x53D; break :next; }, 
                    0x53D => { self.step = 0x53E; break :next; }, 
                    0x53E => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x53F; break :next; }, 
                    0x53F => { self.step = 0x540; break :next; }, 
                    0x540 => { }, 
                    0x541 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x542; break :next; }, // XOR n (cont...)
                    0x542 => { self.dlatch = gd(bus); self.step = 0x543; break :next; }, 
                    0x543 => { self.xor8(self.dlatch); }, 
                    0x544 => { self.step = 0x545; break :next; }, // RST 28 (cont...)
                    0x545 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x546; break :next; }, 
                    0x546 => { self.step = 0x547; break :next; }, 
                    0x547 => { self.step = 0x548; break :next; }, 
                    0x548 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x28; self.setWZ(self.pc); self.step = 0x549; break :next; }, 
                    0x549 => { self.step = 0x54A; break :next; }, 
                    0x54A => { }, 
                    0x54B => { self.step = 0x54C; break :next; }, // RET P (cont...)
                    0x54C => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x54D; break :next; }, 
                    0x54D => { self.r[WZL] = gd(bus); self.step = 0x54E; break :next; }, 
                    0x54E => { self.step = 0x54F; break :next; }, 
                    0x54F => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x550; break :next; }, 
                    0x550 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x551; break :next; }, 
                    0x551 => { }, 
                    0x552 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x553; break :next; }, // POP AF (cont...)
                    0x553 => { self.r[F] = gd(bus); self.step = 0x554; break :next; }, 
                    0x554 => { self.step = 0x555; break :next; }, 
                    0x555 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x556; break :next; }, 
                    0x556 => { self.r[A] = gd(bus); self.step = 0x557; break :next; }, 
                    0x557 => { }, 
                    0x558 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x559; break :next; }, // JP P,nn (cont...)
                    0x559 => { self.r[WZL] = gd(bus); self.step = 0x55A; break :next; }, 
                    0x55A => { self.step = 0x55B; break :next; }, 
                    0x55B => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x55C; break :next; }, 
                    0x55C => { self.r[WZH] = gd(bus); if (self.testP()) self.pc = self.WZ(); self.step = 0x55D; break :next; }, 
                    0x55D => { }, 
                    0x55E => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x55F; break :next; }, // CALL P,nn (cont...)
                    0x55F => { self.r[WZL] = gd(bus); self.step = 0x560; break :next; }, 
                    0x560 => { self.step = 0x561; break :next; }, 
                    0x561 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x562; break :next; }, 
                    0x562 => { self.r[WZH] = gd(bus); if (self.gotoP(0x563 + 7)) break: next; self.step = 0x563; break :next; }, 
                    0x563 => { self.decSP(); self.step = 0x564; break :next; }, 
                    0x564 => { self.step = 0x565; break :next; }, 
                    0x565 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x566; break :next; }, 
                    0x566 => { self.step = 0x567; break :next; }, 
                    0x567 => { self.step = 0x568; break :next; }, 
                    0x568 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x569; break :next; }, 
                    0x569 => { self.step = 0x56A; break :next; }, 
                    0x56A => { }, 
                    0x56B => { self.step = 0x56C; break :next; }, // PUSH AF (cont...)
                    0x56C => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[A]); self.decSP(); self.step = 0x56D; break :next; }, 
                    0x56D => { self.step = 0x56E; break :next; }, 
                    0x56E => { self.step = 0x56F; break :next; }, 
                    0x56F => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.r[F]); self.step = 0x570; break :next; }, 
                    0x570 => { self.step = 0x571; break :next; }, 
                    0x571 => { }, 
                    0x572 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x573; break :next; }, // OR n (cont...)
                    0x573 => { self.dlatch = gd(bus); self.step = 0x574; break :next; }, 
                    0x574 => { self.or8(self.dlatch); }, 
                    0x575 => { self.step = 0x576; break :next; }, // RST 30 (cont...)
                    0x576 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x577; break :next; }, 
                    0x577 => { self.step = 0x578; break :next; }, 
                    0x578 => { self.step = 0x579; break :next; }, 
                    0x579 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x30; self.setWZ(self.pc); self.step = 0x57A; break :next; }, 
                    0x57A => { self.step = 0x57B; break :next; }, 
                    0x57B => { }, 
                    0x57C => { self.step = 0x57D; break :next; }, // RET M (cont...)
                    0x57D => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x57E; break :next; }, 
                    0x57E => { self.r[WZL] = gd(bus); self.step = 0x57F; break :next; }, 
                    0x57F => { self.step = 0x580; break :next; }, 
                    0x580 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x581; break :next; }, 
                    0x581 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x582; break :next; }, 
                    0x582 => { }, 
                    0x583 => { self.step = 0x584; break :next; }, // LD SP,HL (cont...)
                    0x584 => { }, 
                    0x585 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x586; break :next; }, // JP M,nn (cont...)
                    0x586 => { self.r[WZL] = gd(bus); self.step = 0x587; break :next; }, 
                    0x587 => { self.step = 0x588; break :next; }, 
                    0x588 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x589; break :next; }, 
                    0x589 => { self.r[WZH] = gd(bus); if (self.testM()) self.pc = self.WZ(); self.step = 0x58A; break :next; }, 
                    0x58A => { }, 
                    0x58B => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x58C; break :next; }, // CALL M,nn (cont...)
                    0x58C => { self.r[WZL] = gd(bus); self.step = 0x58D; break :next; }, 
                    0x58D => { self.step = 0x58E; break :next; }, 
                    0x58E => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x58F; break :next; }, 
                    0x58F => { self.r[WZH] = gd(bus); if (self.gotoM(0x590 + 7)) break: next; self.step = 0x590; break :next; }, 
                    0x590 => { self.decSP(); self.step = 0x591; break :next; }, 
                    0x591 => { self.step = 0x592; break :next; }, 
                    0x592 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x593; break :next; }, 
                    0x593 => { self.step = 0x594; break :next; }, 
                    0x594 => { self.step = 0x595; break :next; }, 
                    0x595 => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = self.WZ(); self.step = 0x596; break :next; }, 
                    0x596 => { self.step = 0x597; break :next; }, 
                    0x597 => { }, 
                    0x598 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x599; break :next; }, // CP n (cont...)
                    0x599 => { self.dlatch = gd(bus); self.step = 0x59A; break :next; }, 
                    0x59A => { self.cp8(self.dlatch); }, 
                    0x59B => { self.step = 0x59C; break :next; }, // RST 38 (cont...)
                    0x59C => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCH()); self.decSP(); self.step = 0x59D; break :next; }, 
                    0x59D => { self.step = 0x59E; break :next; }, 
                    0x59E => { self.step = 0x59F; break :next; }, 
                    0x59F => { if (wait(bus)) break :next; bus = mwr(bus, self.SP(), self.PCL()); self.pc = 0x38; self.setWZ(self.pc); self.step = 0x5A0; break :next; }, 
                    0x5A0 => { self.step = 0x5A1; break :next; }, 
                    0x5A1 => { }, 
                    0x5A2 => { self.step = 0x5A3; break :next; }, // IN B,(C) (cont...)
                    0x5A3 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x5A4; break :next; }, 
                    0x5A4 => { self.dlatch = gd(bus); self.step = 0x5A5; break :next; }, 
                    0x5A5 => { self.r[B] = self.in(self.dlatch); }, 
                    0x5A6 => { bus = iowr(bus, self.BC(), self.r[B]); self.step = 0x5A7; break :next; }, // OUT (C),B (cont...)
                    0x5A7 => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x5A8; break :next; }, 
                    0x5A8 => { self.step = 0x5A9; break :next; }, 
                    0x5A9 => { }, 
                    0x5AA => { self.step = 0x5AB; break :next; }, // SBC HL,BC (cont...)
                    0x5AB => { self.step = 0x5AC; break :next; }, 
                    0x5AC => { self.step = 0x5AD; break :next; }, 
                    0x5AD => { self.step = 0x5AE; break :next; }, 
                    0x5AE => { self.step = 0x5AF; break :next; }, 
                    0x5AF => { self.step = 0x5B0; break :next; }, 
                    0x5B0 => { }, 
                    0x5B1 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x5B2; break :next; }, // LD (nn),BC (cont...)
                    0x5B2 => { self.r[WZL] = gd(bus); self.step = 0x5B3; break :next; }, 
                    0x5B3 => { self.step = 0x5B4; break :next; }, 
                    0x5B4 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x5B5; break :next; }, 
                    0x5B5 => { self.r[WZH] = gd(bus); self.step = 0x5B6; break :next; }, 
                    0x5B6 => { self.step = 0x5B7; break :next; }, 
                    0x5B7 => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[C]); self.incWZ(); self.step = 0x5B8; break :next; }, 
                    0x5B8 => { self.step = 0x5B9; break :next; }, 
                    0x5B9 => { self.step = 0x5BA; break :next; }, 
                    0x5BA => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[B]); self.step = 0x5BB; break :next; }, 
                    0x5BB => { self.step = 0x5BC; break :next; }, 
                    0x5BC => { }, 
                    0x5BD => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x5BE; break :next; }, // RETN (cont...)
                    0x5BE => { self.r[WZL] = gd(bus); self.step = 0x5BF; break :next; }, 
                    0x5BF => { self.step = 0x5C0; break :next; }, 
                    0x5C0 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x5C1; break :next; }, 
                    0x5C1 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x5C2; break :next; }, 
                    0x5C2 => { self.iff1 = self.iff2; }, 
                    0x5C3 => { self.setI(self.r[A]); }, // LD I,A (cont...)
                    0x5C4 => { self.step = 0x5C5; break :next; }, // IN C,(C) (cont...)
                    0x5C5 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x5C6; break :next; }, 
                    0x5C6 => { self.dlatch = gd(bus); self.step = 0x5C7; break :next; }, 
                    0x5C7 => { self.r[C] = self.in(self.dlatch); }, 
                    0x5C8 => { bus = iowr(bus, self.BC(), self.r[C]); self.step = 0x5C9; break :next; }, // OUT (C),C (cont...)
                    0x5C9 => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x5CA; break :next; }, 
                    0x5CA => { self.step = 0x5CB; break :next; }, 
                    0x5CB => { }, 
                    0x5CC => { self.step = 0x5CD; break :next; }, // ADC HL,BC (cont...)
                    0x5CD => { self.step = 0x5CE; break :next; }, 
                    0x5CE => { self.step = 0x5CF; break :next; }, 
                    0x5CF => { self.step = 0x5D0; break :next; }, 
                    0x5D0 => { self.step = 0x5D1; break :next; }, 
                    0x5D1 => { self.step = 0x5D2; break :next; }, 
                    0x5D2 => { }, 
                    0x5D3 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x5D4; break :next; }, // LD BC,(nn) (cont...)
                    0x5D4 => { self.r[WZL] = gd(bus); self.step = 0x5D5; break :next; }, 
                    0x5D5 => { self.step = 0x5D6; break :next; }, 
                    0x5D6 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x5D7; break :next; }, 
                    0x5D7 => { self.r[WZH] = gd(bus); self.step = 0x5D8; break :next; }, 
                    0x5D8 => { self.step = 0x5D9; break :next; }, 
                    0x5D9 => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.incWZ(); self.step = 0x5DA; break :next; }, 
                    0x5DA => { self.r[C] = gd(bus); self.step = 0x5DB; break :next; }, 
                    0x5DB => { self.step = 0x5DC; break :next; }, 
                    0x5DC => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.step = 0x5DD; break :next; }, 
                    0x5DD => { self.r[B] = gd(bus); self.step = 0x5DE; break :next; }, 
                    0x5DE => { }, 
                    0x5DF => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x5E0; break :next; }, // RETI (cont...)
                    0x5E0 => { self.r[WZL] = gd(bus); self.step = 0x5E1; break :next; }, 
                    0x5E1 => { self.step = 0x5E2; break :next; }, 
                    0x5E2 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x5E3; break :next; }, 
                    0x5E3 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x5E4; break :next; }, 
                    0x5E4 => { self.iff1 = self.iff2; }, 
                    0x5E5 => { self.setR(self.r[A]); }, // LD R,A (cont...)
                    0x5E6 => { self.step = 0x5E7; break :next; }, // IN D,(C) (cont...)
                    0x5E7 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x5E8; break :next; }, 
                    0x5E8 => { self.dlatch = gd(bus); self.step = 0x5E9; break :next; }, 
                    0x5E9 => { self.r[D] = self.in(self.dlatch); }, 
                    0x5EA => { bus = iowr(bus, self.BC(), self.r[D]); self.step = 0x5EB; break :next; }, // OUT (C),D (cont...)
                    0x5EB => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x5EC; break :next; }, 
                    0x5EC => { self.step = 0x5ED; break :next; }, 
                    0x5ED => { }, 
                    0x5EE => { self.step = 0x5EF; break :next; }, // SBC HL,DE (cont...)
                    0x5EF => { self.step = 0x5F0; break :next; }, 
                    0x5F0 => { self.step = 0x5F1; break :next; }, 
                    0x5F1 => { self.step = 0x5F2; break :next; }, 
                    0x5F2 => { self.step = 0x5F3; break :next; }, 
                    0x5F3 => { self.step = 0x5F4; break :next; }, 
                    0x5F4 => { }, 
                    0x5F5 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x5F6; break :next; }, // LD (nn),DE (cont...)
                    0x5F6 => { self.r[WZL] = gd(bus); self.step = 0x5F7; break :next; }, 
                    0x5F7 => { self.step = 0x5F8; break :next; }, 
                    0x5F8 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x5F9; break :next; }, 
                    0x5F9 => { self.r[WZH] = gd(bus); self.step = 0x5FA; break :next; }, 
                    0x5FA => { self.step = 0x5FB; break :next; }, 
                    0x5FB => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[E]); self.incWZ(); self.step = 0x5FC; break :next; }, 
                    0x5FC => { self.step = 0x5FD; break :next; }, 
                    0x5FD => { self.step = 0x5FE; break :next; }, 
                    0x5FE => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[D]); self.step = 0x5FF; break :next; }, 
                    0x5FF => { self.step = 0x600; break :next; }, 
                    0x600 => { }, 
                    0x601 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x602; break :next; }, // RETI (cont...)
                    0x602 => { self.r[WZL] = gd(bus); self.step = 0x603; break :next; }, 
                    0x603 => { self.step = 0x604; break :next; }, 
                    0x604 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x605; break :next; }, 
                    0x605 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x606; break :next; }, 
                    0x606 => { self.iff1 = self.iff2; }, 
                    0x607 => { self.r[A] = self.I(); self.r[F] = self.sziff2Flags(self.I()); }, // LD A,I (cont...)
                    0x608 => { self.step = 0x609; break :next; }, // IN E,(C) (cont...)
                    0x609 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x60A; break :next; }, 
                    0x60A => { self.dlatch = gd(bus); self.step = 0x60B; break :next; }, 
                    0x60B => { self.r[E] = self.in(self.dlatch); }, 
                    0x60C => { bus = iowr(bus, self.BC(), self.r[E]); self.step = 0x60D; break :next; }, // OUT (C),E (cont...)
                    0x60D => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x60E; break :next; }, 
                    0x60E => { self.step = 0x60F; break :next; }, 
                    0x60F => { }, 
                    0x610 => { self.step = 0x611; break :next; }, // ADC HL,DE (cont...)
                    0x611 => { self.step = 0x612; break :next; }, 
                    0x612 => { self.step = 0x613; break :next; }, 
                    0x613 => { self.step = 0x614; break :next; }, 
                    0x614 => { self.step = 0x615; break :next; }, 
                    0x615 => { self.step = 0x616; break :next; }, 
                    0x616 => { }, 
                    0x617 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x618; break :next; }, // LD DE,(nn) (cont...)
                    0x618 => { self.r[WZL] = gd(bus); self.step = 0x619; break :next; }, 
                    0x619 => { self.step = 0x61A; break :next; }, 
                    0x61A => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x61B; break :next; }, 
                    0x61B => { self.r[WZH] = gd(bus); self.step = 0x61C; break :next; }, 
                    0x61C => { self.step = 0x61D; break :next; }, 
                    0x61D => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.incWZ(); self.step = 0x61E; break :next; }, 
                    0x61E => { self.r[E] = gd(bus); self.step = 0x61F; break :next; }, 
                    0x61F => { self.step = 0x620; break :next; }, 
                    0x620 => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.step = 0x621; break :next; }, 
                    0x621 => { self.r[D] = gd(bus); self.step = 0x622; break :next; }, 
                    0x622 => { }, 
                    0x623 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x624; break :next; }, // RETI (cont...)
                    0x624 => { self.r[WZL] = gd(bus); self.step = 0x625; break :next; }, 
                    0x625 => { self.step = 0x626; break :next; }, 
                    0x626 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x627; break :next; }, 
                    0x627 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x628; break :next; }, 
                    0x628 => { self.iff1 = self.iff2; }, 
                    0x629 => { self.r[A] = self.R(); self.r[F] = self.sziff2Flags(self.R()); }, // LD A,R (cont...)
                    0x62A => { self.step = 0x62B; break :next; }, // IN H,(C) (cont...)
                    0x62B => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x62C; break :next; }, 
                    0x62C => { self.dlatch = gd(bus); self.step = 0x62D; break :next; }, 
                    0x62D => { self.r[H] = self.in(self.dlatch); }, 
                    0x62E => { bus = iowr(bus, self.BC(), self.r[H]); self.step = 0x62F; break :next; }, // OUT (C),H (cont...)
                    0x62F => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x630; break :next; }, 
                    0x630 => { self.step = 0x631; break :next; }, 
                    0x631 => { }, 
                    0x632 => { self.step = 0x633; break :next; }, // SBC HL,HL (cont...)
                    0x633 => { self.step = 0x634; break :next; }, 
                    0x634 => { self.step = 0x635; break :next; }, 
                    0x635 => { self.step = 0x636; break :next; }, 
                    0x636 => { self.step = 0x637; break :next; }, 
                    0x637 => { self.step = 0x638; break :next; }, 
                    0x638 => { }, 
                    0x639 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x63A; break :next; }, // LD (nn),HL (cont...)
                    0x63A => { self.r[WZL] = gd(bus); self.step = 0x63B; break :next; }, 
                    0x63B => { self.step = 0x63C; break :next; }, 
                    0x63C => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x63D; break :next; }, 
                    0x63D => { self.r[WZH] = gd(bus); self.step = 0x63E; break :next; }, 
                    0x63E => { self.step = 0x63F; break :next; }, 
                    0x63F => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[L]); self.incWZ(); self.step = 0x640; break :next; }, 
                    0x640 => { self.step = 0x641; break :next; }, 
                    0x641 => { self.step = 0x642; break :next; }, 
                    0x642 => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[H]); self.step = 0x643; break :next; }, 
                    0x643 => { self.step = 0x644; break :next; }, 
                    0x644 => { }, 
                    0x645 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x646; break :next; }, // RETI (cont...)
                    0x646 => { self.r[WZL] = gd(bus); self.step = 0x647; break :next; }, 
                    0x647 => { self.step = 0x648; break :next; }, 
                    0x648 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x649; break :next; }, 
                    0x649 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x64A; break :next; }, 
                    0x64A => { self.iff1 = self.iff2; }, 
                    0x64B => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.step = 0x64C; break :next; }, // RRD (cont...)
                    0x64C => { self.dlatch = gd(bus); self.step = 0x64D; break :next; }, 
                    0x64D => { self.dlatch = self.rrd(self.dlatch); self.step = 0x64E; break :next; }, 
                    0x64E => { self.step = 0x64F; break :next; }, 
                    0x64F => { self.step = 0x650; break :next; }, 
                    0x650 => { self.step = 0x651; break :next; }, 
                    0x651 => { self.step = 0x652; break :next; }, 
                    0x652 => { if (wait(bus)) break :next; bus = mwr(bus, self.HL(), self.dlatch); self.setWZ(self.HL() +% 1); self.step = 0x653; break :next; }, 
                    0x653 => { self.step = 0x654; break :next; }, 
                    0x654 => { }, 
                    0x655 => { self.step = 0x656; break :next; }, // IN L,(C) (cont...)
                    0x656 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x657; break :next; }, 
                    0x657 => { self.dlatch = gd(bus); self.step = 0x658; break :next; }, 
                    0x658 => { self.r[L] = self.in(self.dlatch); }, 
                    0x659 => { bus = iowr(bus, self.BC(), self.r[L]); self.step = 0x65A; break :next; }, // OUT (C),L (cont...)
                    0x65A => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x65B; break :next; }, 
                    0x65B => { self.step = 0x65C; break :next; }, 
                    0x65C => { }, 
                    0x65D => { self.step = 0x65E; break :next; }, // ADC HL,HL (cont...)
                    0x65E => { self.step = 0x65F; break :next; }, 
                    0x65F => { self.step = 0x660; break :next; }, 
                    0x660 => { self.step = 0x661; break :next; }, 
                    0x661 => { self.step = 0x662; break :next; }, 
                    0x662 => { self.step = 0x663; break :next; }, 
                    0x663 => { }, 
                    0x664 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x665; break :next; }, // LD HL,(nn) (cont...)
                    0x665 => { self.r[WZL] = gd(bus); self.step = 0x666; break :next; }, 
                    0x666 => { self.step = 0x667; break :next; }, 
                    0x667 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x668; break :next; }, 
                    0x668 => { self.r[WZH] = gd(bus); self.step = 0x669; break :next; }, 
                    0x669 => { self.step = 0x66A; break :next; }, 
                    0x66A => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.incWZ(); self.step = 0x66B; break :next; }, 
                    0x66B => { self.r[L] = gd(bus); self.step = 0x66C; break :next; }, 
                    0x66C => { self.step = 0x66D; break :next; }, 
                    0x66D => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.step = 0x66E; break :next; }, 
                    0x66E => { self.r[H] = gd(bus); self.step = 0x66F; break :next; }, 
                    0x66F => { }, 
                    0x670 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x671; break :next; }, // RETI (cont...)
                    0x671 => { self.r[WZL] = gd(bus); self.step = 0x672; break :next; }, 
                    0x672 => { self.step = 0x673; break :next; }, 
                    0x673 => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x674; break :next; }, 
                    0x674 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x675; break :next; }, 
                    0x675 => { self.iff1 = self.iff2; }, 
                    0x676 => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.step = 0x677; break :next; }, // RLD (cont...)
                    0x677 => { self.dlatch = gd(bus); self.step = 0x678; break :next; }, 
                    0x678 => { self.dlatch = self.rld(self.dlatch); self.step = 0x679; break :next; }, 
                    0x679 => { self.step = 0x67A; break :next; }, 
                    0x67A => { self.step = 0x67B; break :next; }, 
                    0x67B => { self.step = 0x67C; break :next; }, 
                    0x67C => { self.step = 0x67D; break :next; }, 
                    0x67D => { if (wait(bus)) break :next; bus = mwr(bus, self.HL(), self.dlatch); self.setWZ(self.HL() +% 1); self.step = 0x67E; break :next; }, 
                    0x67E => { self.step = 0x67F; break :next; }, 
                    0x67F => { }, 
                    0x680 => { self.step = 0x681; break :next; }, // IN (C) (cont...)
                    0x681 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x682; break :next; }, 
                    0x682 => { self.dlatch = gd(bus); self.step = 0x683; break :next; }, 
                    0x683 => { _ = self.in(self.dlatch); }, 
                    0x684 => { bus = iowr(bus, self.BC(), 0); self.step = 0x685; break :next; }, // OUT (C) (cont...)
                    0x685 => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x686; break :next; }, 
                    0x686 => { self.step = 0x687; break :next; }, 
                    0x687 => { }, 
                    0x688 => { self.step = 0x689; break :next; }, // SBC HL,SP (cont...)
                    0x689 => { self.step = 0x68A; break :next; }, 
                    0x68A => { self.step = 0x68B; break :next; }, 
                    0x68B => { self.step = 0x68C; break :next; }, 
                    0x68C => { self.step = 0x68D; break :next; }, 
                    0x68D => { self.step = 0x68E; break :next; }, 
                    0x68E => { }, 
                    0x68F => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x690; break :next; }, // LD (nn),SP (cont...)
                    0x690 => { self.r[WZL] = gd(bus); self.step = 0x691; break :next; }, 
                    0x691 => { self.step = 0x692; break :next; }, 
                    0x692 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x693; break :next; }, 
                    0x693 => { self.r[WZH] = gd(bus); self.step = 0x694; break :next; }, 
                    0x694 => { self.step = 0x695; break :next; }, 
                    0x695 => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[SPL]); self.incWZ(); self.step = 0x696; break :next; }, 
                    0x696 => { self.step = 0x697; break :next; }, 
                    0x697 => { self.step = 0x698; break :next; }, 
                    0x698 => { if (wait(bus)) break :next; bus = mwr(bus, self.WZ(), self.r[SPH]); self.step = 0x699; break :next; }, 
                    0x699 => { self.step = 0x69A; break :next; }, 
                    0x69A => { }, 
                    0x69B => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x69C; break :next; }, // RETI (cont...)
                    0x69C => { self.r[WZL] = gd(bus); self.step = 0x69D; break :next; }, 
                    0x69D => { self.step = 0x69E; break :next; }, 
                    0x69E => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x69F; break :next; }, 
                    0x69F => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x6A0; break :next; }, 
                    0x6A0 => { self.iff1 = self.iff2; }, 
                    0x6A1 => { self.step = 0x6A2; break :next; }, // IN A,(C) (cont...)
                    0x6A2 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.setWZ(self.BC() +% 1); self.step = 0x6A3; break :next; }, 
                    0x6A3 => { self.dlatch = gd(bus); self.step = 0x6A4; break :next; }, 
                    0x6A4 => { self.r[A] = self.in(self.dlatch); }, 
                    0x6A5 => { bus = iowr(bus, self.BC(), self.r[A]); self.step = 0x6A6; break :next; }, // OUT (C),A (cont...)
                    0x6A6 => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); self.step = 0x6A7; break :next; }, 
                    0x6A7 => { self.step = 0x6A8; break :next; }, 
                    0x6A8 => { }, 
                    0x6A9 => { self.step = 0x6AA; break :next; }, // ADC HL,SP (cont...)
                    0x6AA => { self.step = 0x6AB; break :next; }, 
                    0x6AB => { self.step = 0x6AC; break :next; }, 
                    0x6AC => { self.step = 0x6AD; break :next; }, 
                    0x6AD => { self.step = 0x6AE; break :next; }, 
                    0x6AE => { self.step = 0x6AF; break :next; }, 
                    0x6AF => { }, 
                    0x6B0 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x6B1; break :next; }, // LD SP,(nn) (cont...)
                    0x6B1 => { self.r[WZL] = gd(bus); self.step = 0x6B2; break :next; }, 
                    0x6B2 => { self.step = 0x6B3; break :next; }, 
                    0x6B3 => { if (wait(bus)) break :next; bus = mrd(bus, self.pc); self.incPC(); self.step = 0x6B4; break :next; }, 
                    0x6B4 => { self.r[WZH] = gd(bus); self.step = 0x6B5; break :next; }, 
                    0x6B5 => { self.step = 0x6B6; break :next; }, 
                    0x6B6 => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.incWZ(); self.step = 0x6B7; break :next; }, 
                    0x6B7 => { self.r[SPL] = gd(bus); self.step = 0x6B8; break :next; }, 
                    0x6B8 => { self.step = 0x6B9; break :next; }, 
                    0x6B9 => { if (wait(bus)) break :next; bus = mrd(bus, self.WZ()); self.step = 0x6BA; break :next; }, 
                    0x6BA => { self.r[SPH] = gd(bus); self.step = 0x6BB; break :next; }, 
                    0x6BB => { }, 
                    0x6BC => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x6BD; break :next; }, // RETI (cont...)
                    0x6BD => { self.r[WZL] = gd(bus); self.step = 0x6BE; break :next; }, 
                    0x6BE => { self.step = 0x6BF; break :next; }, 
                    0x6BF => { if (wait(bus)) break :next; bus = mrd(bus, self.SP()); self.incSP(); self.step = 0x6C0; break :next; }, 
                    0x6C0 => { self.r[WZH] = gd(bus); self.pc = self.WZ(); self.step = 0x6C1; break :next; }, 
                    0x6C1 => { self.iff1 = self.iff2; }, 
                    0x6C2 => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.incHL(); self.step = 0x6C3; break :next; }, // LDI (cont...)
                    0x6C3 => { self.dlatch = gd(bus); self.step = 0x6C4; break :next; }, 
                    0x6C4 => { self.step = 0x6C5; break :next; }, 
                    0x6C5 => { if (wait(bus)) break :next; bus = mwr(bus, self.DE(), self.dlatch); self.incDE(); self.step = 0x6C6; break :next; }, 
                    0x6C6 => { self.step = 0x6C7; break :next; }, 
                    0x6C7 => { _ = self.ldildd(); self.step = 0x6C8; break :next; }, 
                    0x6C8 => { self.step = 0x6C9; break :next; }, 
                    0x6C9 => { }, 
                    0x6CA => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.incHL(); self.step = 0x6CB; break :next; }, // CPI (cont...)
                    0x6CB => { self.dlatch = gd(bus); self.step = 0x6CC; break :next; }, 
                    0x6CC => { self.incWZ(); _ = self.cpicpd(); self.step = 0x6CD; break :next; }, 
                    0x6CD => { self.step = 0x6CE; break :next; }, 
                    0x6CE => { self.step = 0x6CF; break :next; }, 
                    0x6CF => { self.step = 0x6D0; break :next; }, 
                    0x6D0 => { self.step = 0x6D1; break :next; }, 
                    0x6D1 => { }, 
                    0x6D2 => { self.step = 0x6D3; break :next; }, // INI (cont...)
                    0x6D3 => { self.step = 0x6D4; break :next; }, 
                    0x6D4 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.step = 0x6D5; break :next; }, 
                    0x6D5 => { self.dlatch = gd(bus); self.setWZ(self.BC() +% 1); self.r[B] -%= 1; self.step = 0x6D6; break :next; }, 
                    0x6D6 => { self.step = 0x6D7; break :next; }, 
                    0x6D7 => { if (wait(bus)) break :next; bus = mwr(bus, self.HL(), self.dlatch); self.incHL(); _ = self.iniind(self.r[C] +% 1); self.step = 0x6D8; break :next; }, 
                    0x6D8 => { self.step = 0x6D9; break :next; }, 
                    0x6D9 => { }, 
                    0x6DA => { self.step = 0x6DB; break :next; }, // OUTI (cont...)
                    0x6DB => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.incHL(); self.step = 0x6DC; break :next; }, 
                    0x6DC => { self.dlatch = gd(bus); self.r[B] -%= 1; self.step = 0x6DD; break :next; }, 
                    0x6DD => { self.step = 0x6DE; break :next; }, 
                    0x6DE => { bus = iowr(bus, self.BC(), self.dlatch); self.step = 0x6DF; break :next; }, 
                    0x6DF => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); _ = self.outioutd(); self.step = 0x6E0; break :next; }, 
                    0x6E0 => { self.step = 0x6E1; break :next; }, 
                    0x6E1 => { }, 
                    0x6E2 => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.decHL(); self.step = 0x6E3; break :next; }, // LDD (cont...)
                    0x6E3 => { self.dlatch = gd(bus); self.step = 0x6E4; break :next; }, 
                    0x6E4 => { self.step = 0x6E5; break :next; }, 
                    0x6E5 => { if (wait(bus)) break :next; bus = mwr(bus, self.DE(), self.dlatch); self.decDE(); self.step = 0x6E6; break :next; }, 
                    0x6E6 => { self.step = 0x6E7; break :next; }, 
                    0x6E7 => { _ = self.ldildd(); self.step = 0x6E8; break :next; }, 
                    0x6E8 => { self.step = 0x6E9; break :next; }, 
                    0x6E9 => { }, 
                    0x6EA => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.decHL(); self.step = 0x6EB; break :next; }, // CPD (cont...)
                    0x6EB => { self.dlatch = gd(bus); self.step = 0x6EC; break :next; }, 
                    0x6EC => { self.decWZ(); _ = self.cpicpd(); self.step = 0x6ED; break :next; }, 
                    0x6ED => { self.step = 0x6EE; break :next; }, 
                    0x6EE => { self.step = 0x6EF; break :next; }, 
                    0x6EF => { self.step = 0x6F0; break :next; }, 
                    0x6F0 => { self.step = 0x6F1; break :next; }, 
                    0x6F1 => { }, 
                    0x6F2 => { self.step = 0x6F3; break :next; }, // IND (cont...)
                    0x6F3 => { self.step = 0x6F4; break :next; }, 
                    0x6F4 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.step = 0x6F5; break :next; }, 
                    0x6F5 => { self.dlatch = gd(bus); self.setWZ(self.BC() -% 1); self.r[B] -%= 1; self.step = 0x6F6; break :next; }, 
                    0x6F6 => { self.step = 0x6F7; break :next; }, 
                    0x6F7 => { if (wait(bus)) break :next; bus = mwr(bus, self.HL(), self.dlatch); self.decHL(); _ = self.iniind(self.r[C] -% 1); self.step = 0x6F8; break :next; }, 
                    0x6F8 => { self.step = 0x6F9; break :next; }, 
                    0x6F9 => { }, 
                    0x6FA => { self.step = 0x6FB; break :next; }, // OUTD (cont...)
                    0x6FB => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.decHL(); self.step = 0x6FC; break :next; }, 
                    0x6FC => { self.dlatch = gd(bus); self.r[B] -%= 1; self.step = 0x6FD; break :next; }, 
                    0x6FD => { self.step = 0x6FE; break :next; }, 
                    0x6FE => { bus = iowr(bus, self.BC(), self.dlatch); self.step = 0x6FF; break :next; }, 
                    0x6FF => { if (wait(bus)) break :next; self.setWZ(self.BC() -% 1); _ = self.outioutd(); self.step = 0x700; break :next; }, 
                    0x700 => { self.step = 0x701; break :next; }, 
                    0x701 => { }, 
                    0x702 => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.incHL(); self.step = 0x703; break :next; }, // LDIR (cont...)
                    0x703 => { self.dlatch = gd(bus); self.step = 0x704; break :next; }, 
                    0x704 => { self.step = 0x705; break :next; }, 
                    0x705 => { if (wait(bus)) break :next; bus = mwr(bus, self.DE(), self.dlatch); self.incDE(); self.step = 0x706; break :next; }, 
                    0x706 => { self.step = 0x707; break :next; }, 
                    0x707 => { if (self.gotoFalse(self.ldildd(), 0x708 + 5)) break :next; self.step = 0x708; break :next; }, 
                    0x708 => { self.step = 0x709; break :next; }, 
                    0x709 => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x70A; break :next; }, 
                    0x70A => { self.step = 0x70B; break :next; }, 
                    0x70B => { self.step = 0x70C; break :next; }, 
                    0x70C => { self.step = 0x70D; break :next; }, 
                    0x70D => { self.step = 0x70E; break :next; }, 
                    0x70E => { }, 
                    0x70F => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.incHL(); self.step = 0x710; break :next; }, // CPIR (cont...)
                    0x710 => { self.dlatch = gd(bus); self.step = 0x711; break :next; }, 
                    0x711 => { self.incWZ(); if (self.gotoFalse(self.cpicpd(), 0x712 + 5)) break :next; self.step = 0x712; break :next; }, 
                    0x712 => { self.step = 0x713; break :next; }, 
                    0x713 => { self.step = 0x714; break :next; }, 
                    0x714 => { self.step = 0x715; break :next; }, 
                    0x715 => { self.step = 0x716; break :next; }, 
                    0x716 => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x717; break :next; }, 
                    0x717 => { self.step = 0x718; break :next; }, 
                    0x718 => { self.step = 0x719; break :next; }, 
                    0x719 => { self.step = 0x71A; break :next; }, 
                    0x71A => { self.step = 0x71B; break :next; }, 
                    0x71B => { }, 
                    0x71C => { self.step = 0x71D; break :next; }, // INIR (cont...)
                    0x71D => { self.step = 0x71E; break :next; }, 
                    0x71E => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.step = 0x71F; break :next; }, 
                    0x71F => { self.dlatch = gd(bus); self.setWZ(self.BC() +% 1); self.r[B] -%= 1; self.step = 0x720; break :next; }, 
                    0x720 => { self.step = 0x721; break :next; }, 
                    0x721 => { if (wait(bus)) break :next; bus = mwr(bus, self.HL(), self.dlatch); self.incHL(); if (self.gotoFalse(self.iniind(self.r[C] +% 1), 0x722 + 5)) break :next; self.step = 0x722; break :next; }, 
                    0x722 => { self.step = 0x723; break :next; }, 
                    0x723 => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x724; break :next; }, 
                    0x724 => { self.step = 0x725; break :next; }, 
                    0x725 => { self.step = 0x726; break :next; }, 
                    0x726 => { self.step = 0x727; break :next; }, 
                    0x727 => { self.step = 0x728; break :next; }, 
                    0x728 => { }, 
                    0x729 => { self.step = 0x72A; break :next; }, // OTIR (cont...)
                    0x72A => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.incHL(); self.step = 0x72B; break :next; }, 
                    0x72B => { self.dlatch = gd(bus); self.r[B] -%= 1; self.step = 0x72C; break :next; }, 
                    0x72C => { self.step = 0x72D; break :next; }, 
                    0x72D => { bus = iowr(bus, self.BC(), self.dlatch); self.step = 0x72E; break :next; }, 
                    0x72E => { if (wait(bus)) break :next; self.setWZ(self.BC() +% 1); if (self.gotoFalse(self.outioutd(), 0x72F + 5)) break :next; self.step = 0x72F; break :next; }, 
                    0x72F => { self.step = 0x730; break :next; }, 
                    0x730 => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x731; break :next; }, 
                    0x731 => { self.step = 0x732; break :next; }, 
                    0x732 => { self.step = 0x733; break :next; }, 
                    0x733 => { self.step = 0x734; break :next; }, 
                    0x734 => { self.step = 0x735; break :next; }, 
                    0x735 => { }, 
                    0x736 => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.decHL(); self.step = 0x737; break :next; }, // LDDR (cont...)
                    0x737 => { self.dlatch = gd(bus); self.step = 0x738; break :next; }, 
                    0x738 => { self.step = 0x739; break :next; }, 
                    0x739 => { if (wait(bus)) break :next; bus = mwr(bus, self.DE(), self.dlatch); self.decDE(); self.step = 0x73A; break :next; }, 
                    0x73A => { self.step = 0x73B; break :next; }, 
                    0x73B => { if (self.gotoFalse(self.ldildd(), 0x73C + 5)) break :next; self.step = 0x73C; break :next; }, 
                    0x73C => { self.step = 0x73D; break :next; }, 
                    0x73D => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x73E; break :next; }, 
                    0x73E => { self.step = 0x73F; break :next; }, 
                    0x73F => { self.step = 0x740; break :next; }, 
                    0x740 => { self.step = 0x741; break :next; }, 
                    0x741 => { self.step = 0x742; break :next; }, 
                    0x742 => { }, 
                    0x743 => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.decHL(); self.step = 0x744; break :next; }, // CPDR (cont...)
                    0x744 => { self.dlatch = gd(bus); self.step = 0x745; break :next; }, 
                    0x745 => { self.decWZ(); if (self.gotoFalse(self.cpicpd(), 0x746 + 5)) break :next; self.step = 0x746; break :next; }, 
                    0x746 => { self.step = 0x747; break :next; }, 
                    0x747 => { self.step = 0x748; break :next; }, 
                    0x748 => { self.step = 0x749; break :next; }, 
                    0x749 => { self.step = 0x74A; break :next; }, 
                    0x74A => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x74B; break :next; }, 
                    0x74B => { self.step = 0x74C; break :next; }, 
                    0x74C => { self.step = 0x74D; break :next; }, 
                    0x74D => { self.step = 0x74E; break :next; }, 
                    0x74E => { self.step = 0x74F; break :next; }, 
                    0x74F => { }, 
                    0x750 => { self.step = 0x751; break :next; }, // INDR (cont...)
                    0x751 => { self.step = 0x752; break :next; }, 
                    0x752 => { if (wait(bus)) break :next; bus = iord(bus, self.BC()); self.step = 0x753; break :next; }, 
                    0x753 => { self.dlatch = gd(bus); self.setWZ(self.BC() -% 1); self.r[B] -%= 1; self.step = 0x754; break :next; }, 
                    0x754 => { self.step = 0x755; break :next; }, 
                    0x755 => { if (wait(bus)) break :next; bus = mwr(bus, self.HL(), self.dlatch); self.decHL(); if (self.gotoFalse(self.iniind(self.r[C] -% 1), 0x756 + 5)) break :next; self.step = 0x756; break :next; }, 
                    0x756 => { self.step = 0x757; break :next; }, 
                    0x757 => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x758; break :next; }, 
                    0x758 => { self.step = 0x759; break :next; }, 
                    0x759 => { self.step = 0x75A; break :next; }, 
                    0x75A => { self.step = 0x75B; break :next; }, 
                    0x75B => { self.step = 0x75C; break :next; }, 
                    0x75C => { }, 
                    0x75D => { self.step = 0x75E; break :next; }, // OTDR (cont...)
                    0x75E => { if (wait(bus)) break :next; bus = mrd(bus, self.HL()); self.decHL(); self.step = 0x75F; break :next; }, 
                    0x75F => { self.dlatch = gd(bus); self.r[B] -%= 1; self.step = 0x760; break :next; }, 
                    0x760 => { self.step = 0x761; break :next; }, 
                    0x761 => { bus = iowr(bus, self.BC(), self.dlatch); self.step = 0x762; break :next; }, 
                    0x762 => { if (wait(bus)) break :next; self.setWZ(self.BC() -% 1); if (self.gotoFalse(self.outioutd(), 0x763 + 5)) break :next; self.step = 0x763; break :next; }, 
                    0x763 => { self.step = 0x764; break :next; }, 
                    0x764 => { self.decPC(); self.setWZ(self.pc); self.decPC(); self.step = 0x765; break :next; }, 
                    0x765 => { self.step = 0x766; break :next; }, 
                    0x766 => { self.step = 0x767; break :next; }, 
                    0x767 => { self.step = 0x768; break :next; }, 
                    0x768 => { self.step = 0x769; break :next; }, 
                    0x769 => { }, 
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
