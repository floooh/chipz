//! op structure declarations
const op = @import("accumulate.zig").op;
const f = @import("format.zig").f;
const types = @import("types.zig");
const R = types.R;
const RP = types.RP;
const RP2 = types.RP2;
const ALU = types.ALU;
const CC = types.CC;
const r = types.r;
const rr = types.rr;
const rp = types.rp;
const rpl = types.rpl;
const rph = types.rph;
const rp2l = types.rp2l;
const rp2h = types.rp2h;
const alu = types.alu;
const cc = types.cc;
const mc = @import("accumulate.zig").mc;
const mcycles = @import("mcycles.zig");
const endFetch = mcycles.endFetch;
const endOverlapped = mcycles.endOverlapped;
const endBreak = mcycles.endBreak;
const tick = mcycles.tick;
const mread = mcycles.mread;
const imm = mcycles.imm;
const mwrite = mcycles.mwrite;

pub fn nop(code: u8) void {
    op(code, .{
        .dasm = "NOP",
        .mcycles = mc(&.{
            endFetch(),
        }),
    });
}

pub fn halt(code: u8) void {
    op(code, .{
        .dasm = "HALT",
        .mcycles = mc(&.{
            endOverlapped("bus = self.halt(bus)"),
        }),
    });
}

pub fn @"LD (HL),r"(code: u8, z: u3) void {
    op(code, .{
        .dasm = f("LD (HL),{s}", .{R.dasm(z)}),
        .indirect = true,
        .mcycles = mc(&.{
            mwrite("self.addr", rr(z), null),
            endFetch(),
        }),
    });
}

pub fn @"LD r,(HL)"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("LD {s},(HL)", .{R.dasm(y)}),
        .indirect = true,
        .mcycles = mc(&.{
            mread("self.addr", rr(y), null, null),
            endFetch(),
        }),
    });
}

pub fn @"LD r,r"(code: u8, y: u3, z: u3) void {
    op(code, .{
        .dasm = f("LD {s},{s}", .{ R.dasm(y), R.dasm(z) }),
        .mcycles = mc(&.{
            endOverlapped(f("{s} = {s}", .{ r(y), r(z) })),
        }),
    });
}

pub fn @"LD r,n"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("LD {s},n", .{R.dasm(y)}),
        .mcycles = mc(&.{
            imm(r(y), null),
            endFetch(),
        }),
    });
}

pub fn @"LD (HL),n"(code: u8) void {
    op(code, .{
        .dasm = "LD (HL),n",
        .indirect = true,
        .mcycles = mc(&.{
            imm("self.dlatch", null),
            mwrite("self.addr", "self.dlatch", null),
            endFetch(),
        }),
    });
}

pub fn @"ALU (HL)"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("{s} (HL)", .{ALU.dasm(y)}),
        .indirect = true,
        .mcycles = mc(&.{
            mread("self.addr", "self.dlatch", null, null),
            endOverlapped(f("{s}(self.dlatch)", .{alu(y)})),
        }),
    });
}

pub fn @"ALU r"(code: u8, y: u3, z: u3) void {
    op(code, .{
        .dasm = f("{s} {s}", .{ ALU.dasm(y), R.dasm(z) }),
        .mcycles = mc(&.{
            endOverlapped(f("{s}({s})", .{ alu(y), r(z) })),
        }),
    });
}

pub fn @"ALU n"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("{s} n", .{ALU.dasm(y)}),
        .mcycles = mc(&.{
            imm("self.dlatch", null),
            endOverlapped(f("{s}(self.dlatch)", .{alu(y)})),
        }),
    });
}

pub fn @"LD RP,nn"(code: u8, p: u2) void {
    op(code, .{
        .dasm = f("LD {s},nn", .{RP.dasm(p)}),
        .mcycles = mc(&.{
            imm(rpl(p), null),
            imm(rph(p), null),
            endFetch(),
        }),
    });
}

pub fn @"LD A,(BC)"(code: u8) void {
    op(code, .{
        .dasm = "LD A,(BC)",
        .mcycles = mc(&.{
            mread("self.BC()", r(R.A), null, "self.setWZ(self.BC() +% 1)"),
            endFetch(),
        }),
    });
}

pub fn @"LD A,(DE)"(code: u8) void {
    op(code, .{
        .dasm = "LD A,(DE)",
        .mcycles = mc(&.{
            mread("self.DE()", r(R.A), null, "self.setWZ(self.DE() +% 1)"),
            endFetch(),
        }),
    });
}

pub fn @"LD HL,(nn)"(code: u8) void {
    op(code, .{
        .dasm = "LD HL,(nn)",
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", null),
            mread("self.WZ()", r(R.L), "self.incWZ()", null),
            mread("self.WZ()", r(R.H), null, null),
            endFetch(),
        }),
    });
}

pub fn @"LD A,(nn)"(code: u8) void {
    op(code, .{
        .dasm = "LD A,(nn)",
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", null),
            mread("self.WZ()", r(R.A), "self.incWZ()", null),
            endFetch(),
        }),
    });
}

pub fn @"LD (BC),A"(code: u8) void {
    op(code, .{
        .dasm = "LD (BC),A",
        .mcycles = mc(&.{
            mwrite("self.BC()", r(R.A), "self.r[WZL]=self.r[C] +% 1; self.r[WZH]=self.r[A]"),
            endFetch(),
        }),
    });
}

pub fn @"LD (DE),A"(code: u8) void {
    op(code, .{
        .dasm = "LD (DE),A",
        .mcycles = mc(&.{
            mwrite("self.DE()", r(R.A), "self.r[WZL]=self.r[E] +% 1; self.r[WZH]=self.r[A]"),
            endFetch(),
        }),
    });
}

pub fn @"LD (nn),HL"(code: u8) void {
    op(code, .{
        .dasm = "LD (HL),nn",
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", null),
            mwrite("self.WZ()", r(R.L), "self.incWZ()"),
            mwrite("self.WZ()", r(R.H), null),
            endFetch(),
        }),
    });
}

pub fn @"LD (nn),A"(code: u8) void {
    op(code, .{
        .dasm = "LD (HL),A",
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", null),
            mwrite("self.WZ()", r(R.A), "self.incWZ(); self.r[WZH]=self.r[A]"),
            endFetch(),
        }),
    });
}

pub fn @"INC r"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("INC {s}", .{R.dasm(y)}),
        .mcycles = mc(&.{
            endOverlapped(f("{s}=self.inc8({s})", .{ r(y), r(y) })),
        }),
    });
}

pub fn @"INC (HL)"(code: u8) void {
    op(code, .{
        .dasm = "INC (HL)",
        .indirect = true,
        .mcycles = mc(&.{
            mread("self.addr", "self.dlatch", null, null),
            tick("self.dlatch=self.inc8(self.dlatch)"),
            mwrite("self.addr", "self.dlatch", null),
            endFetch(),
        }),
    });
}

pub fn @"DEC r"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("DEC {s}", .{R.dasm(y)}),
        .mcycles = mc(&.{
            endOverlapped(f("{s}=self.dec8({s})", .{ r(y), r(y) })),
        }),
    });
}

pub fn @"DEC (HL)"(code: u8) void {
    op(code, .{
        .dasm = "DEC (HL)",
        .indirect = true,
        .mcycles = mc(&.{
            mread("self.addr", "self.dlatch", null, null),
            tick("self.dlatch=self.dec8(self.dlatch)"),
            mwrite("self.addr", "self.dlatch", null),
            endFetch(),
        }),
    });
}

pub fn rlca(code: u8) void {
    op(code, .{
        .dasm = "RLCA",
        .mcycles = mc(&.{
            endOverlapped("self.rlca()"),
        }),
    });
}

pub fn rrca(code: u8) void {
    op(code, .{
        .dasm = "RRCA",
        .mcycles = mc(&.{
            endOverlapped("self.rrca()"),
        }),
    });
}

pub fn rla(code: u8) void {
    op(code, .{
        .dasm = "RLA",
        .mcycles = mc(&.{
            endOverlapped("self.rla()"),
        }),
    });
}

pub fn rra(code: u8) void {
    op(code, .{
        .dasm = "RRA",
        .mcycles = mc(&.{
            endOverlapped("self.rra()"),
        }),
    });
}

pub fn daa(code: u8) void {
    op(code, .{
        .dasm = "DDA",
        .mcycles = mc(&.{
            endOverlapped("self.daa()"),
        }),
    });
}

pub fn cpl(code: u8) void {
    op(code, .{
        .dasm = "CPL",
        .mcycles = mc(&.{
            endOverlapped("self.cpl()"),
        }),
    });
}

pub fn scf(code: u8) void {
    op(code, .{
        .dasm = "SCF",
        .mcycles = mc(&.{
            endOverlapped("self.scf()"),
        }),
    });
}

pub fn ccf(code: u8) void {
    op(code, .{
        .dasm = "CCF",
        .mcycles = mc(&.{
            endOverlapped("self.ccf()"),
        }),
    });
}

pub fn dd(code: u8) void {
    op(code, .{
        .dasm = "DD Prefix",
        .mcycles = mc(&.{
            endBreak("bus = self.fetchDD(bus)"),
        }),
    });
}

pub fn fd(code: u8) void {
    op(code, .{
        .dasm = "FD Prefix",
        .mcycles = mc(&.{
            endBreak("bus = self.fetchFD(bus)"),
        }),
    });
}

pub fn @"EX AF,AF'"(code: u8) void {
    op(code, .{
        .dasm = "EX AF,AF'",
        .mcycles = mc(&.{
            endOverlapped("self.exafaf2()"),
        }),
    });
}

pub fn @"EX DE,HL"(code: u8) void {
    op(code, .{
        .dasm = "EX DE,HL",
        .mcycles = mc(&.{
            endOverlapped("self.exdehl()"),
        }),
    });
}

pub fn @"EX (SP),HL"(code: u8) void {
    op(code, .{
        .dasm = "EX (SP),HL",
        .mcycles = mc(&.{
            mread("self.SP()", "self.r[WZL]", null, null),
            mread("self.SP() +% 1", "self.r[WZH]", null, null),
            tick(null),
            mwrite("self.SP() +% 1", r(R.H), null),
            mwrite("self.SP()", r(R.L), "self.setHLIXY(self.WZ())"),
            tick(null),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn exx(code: u8) void {
    op(code, .{
        .dasm = "EXX",
        .mcycles = mc(&.{
            endOverlapped("self.exx()"),
        }),
    });
}

pub fn push(code: u8, p: u2) void {
    op(code, .{
        .dasm = f("PUSH {s}", .{RP2.dasm(p)}),
        .mcycles = mc(&.{
            tick("self.decSP()"),
            mwrite("self.SP()", rp2h(p), "self.decSP()"),
            mwrite("self.SP()", rp2l(p), null),
            endFetch(),
        }),
    });
}

pub fn pop(code: u8, p: u2) void {
    op(code, .{
        .dasm = f("POP {s}", .{RP2.dasm(p)}),
        .mcycles = mc(&.{
            mread("self.SP()", rp2l(p), "self.incSP()", null),
            mread("self.SP()", rp2h(p), "self.incSP()", null),
            endFetch(),
        }),
    });
}

pub fn djnz(code: u8) void {
    op(code, .{
        .dasm = "DJNZ",
        .mcycles = mc(&.{
            tick("self.r[B] -%= 1"),
            imm("self.dlatch", "if (self.gotoZero(self.r[B], $NEXTSTEP + 5)) break :next"),
            tick("self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc)"),
            tick(null),
            tick(null),
            tick(null),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn @"JR cc,d"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("JR {s},d", .{CC.dasm(y - 4)}),
        .mcycles = mc(&.{
            imm("self.dlatch", f("if (self.goto{s}($NEXTSTEP + 5)) break :next", .{cc(y - 4)})),
            tick("self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc)"),
            tick(null),
            tick(null),
            tick(null),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn ret(code: u8) void {
    op(code, .{
        .dasm = "RET",
        .mcycles = mc(&.{
            mread("self.SP()", "self.r[WZL]", "self.incSP()", null),
            mread("self.SP()", "self.r[WZH]", "self.incSP()", "self.pc = self.WZ()"),
            endFetch(),
        }),
    });
}

pub fn @"RET cc"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("RET {s}", .{CC.dasm(y)}),
        .mcycles = mc(&.{
            tick(f("if (self.goto{s}($NEXTSTEP + 6)) break :next", .{cc(y)})),
            mread("self.SP()", "self.r[WZL]", "self.incSP()", null),
            mread("self.SP()", "self.r[WZH]", "self.incSP()", "self.pc = self.WZ()"),
            endFetch(),
        }),
    });
}

pub fn @"CALL nn"(code: u8) void {
    op(code, .{
        .dasm = "CALL nn",
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", null),
            tick("self.decSP()"),
            mwrite("self.SP()", "self.PCH()", "self.decSP()"),
            mwrite("self.SP()", "self.PCL()", "self.pc = self.WZ()"),
            endFetch(),
        }),
    });
}

pub fn @"CALL cc,nn"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("CALL {s},nn", .{CC.dasm(y)}),
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", f("if (self.goto{s}($NEXTSTEP + 7)) break: next", .{cc(y)})),
            tick("self.decSP()"),
            mwrite("self.SP()", "self.PCH()", "self.decSP()"),
            mwrite("self.SP()", "self.PCL()", "self.pc = self.WZ()"),
            endFetch(),
        }),
    });
}

pub fn @"JR d"(code: u8) void {
    op(code, .{
        .dasm = "JR d",
        .mcycles = mc(&.{
            imm("self.dlatch", null),
            tick("self.pc +%= dimm8(self.dlatch); self.setWZ(self.pc)"),
            tick(null),
            tick(null),
            tick(null),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn @"JP nn"(code: u8) void {
    op(code, .{
        .dasm = "JP nn",
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", "self.pc = self.WZ()"),
            endFetch(),
        }),
    });
}

pub fn @"JP cc,nn"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("JP {s},nn", .{CC.dasm(y)}),
        .mcycles = mc(&.{
            imm("self.r[WZL]", null),
            imm("self.r[WZH]", f("if (self.test{s}()) self.pc = self.WZ()", .{cc(y)})),
            endFetch(),
        }),
    });
}

pub fn @"JP HL"(code: u8) void {
    op(code, .{
        .dasm = "JP HL",
        .mcycles = mc(&.{
            endOverlapped("self.pc = self.HLIXY()"),
        }),
    });
}

pub fn @"INC rp"(code: u8, p: u2) void {
    op(code, .{
        .dasm = f("INC {s}", .{RP.dasm(p)}),
        .mcycles = mc(&.{
            tick(f("self.set{s}(self.{s}() +% 1)", .{ rp(p), rp(p) })),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn @"DEC rp"(code: u8, p: u2) void {
    op(code, .{
        .dasm = f("DEC {s}", .{RP.dasm(p)}),
        .mcycles = mc(&.{
            tick(f("self.set{s}(self.{s}() -% 1)", .{ rp(p), rp(p) })),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn @"ADD HL,rp"(code: u8, p: u2) void {
    op(code, .{
        .dasm = f("ADD HL,{s}", .{RP.dasm(p)}),
        .mcycles = mc(&.{
            tick(f("self.add16(self.{s}())", .{rp(p)})),
            tick(null),
            tick(null),
            tick(null),
            tick(null),
            tick(null),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn @"RST n"(code: u8, y: u3) void {
    const y8 = @as(usize, y) * 8;
    op(code, .{
        .dasm = f("RST {X}", .{y8}),
        .mcycles = mc(&.{
            tick("self.decSP()"),
            mwrite("self.SP()", "self.PCH()", "self.decSP()"),
            mwrite("self.SP()", "self.PCL()", f("self.pc = 0x{X}; self.setWZ(self.pc)", .{y8})),
            endFetch(),
        }),
    });
}

pub fn @"LD SP,HL"(code: u8) void {
    op(code, .{
        .dasm = "LD SP,HL",
        .mcycles = mc(&.{
            tick("self.setSP(self.HLIXY())"),
            tick(null),
            endFetch(),
        }),
    });
}

pub fn di(code: u8) void {
    op(code, .{
        .dasm = "DI",
        .mcycles = mc(&.{
            endOverlapped("self.iff1 = false; self.iff2 = false"),
        }),
    });
}

pub fn ei(code: u8) void {
    op(code, .{
        .dasm = "EI",
        .mcycles = mc(&.{
            endBreak("self.iff1 = false; self.iff2 = false; bus = self.fetch(bus); self.iff1 = true; self.iff2 = true"),
        }),
    });
}
