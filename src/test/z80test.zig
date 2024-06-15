// zig fmt: off
const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const bits = chips.bits;
const z80 = chips.z80;

const Z80 = z80.Z80(z80.DefaultPins, u64);

const A = z80.A;
const F = z80.F;
const B = z80.B;
const C = z80.C;
const D = z80.D;
const E = z80.E;
const L = z80.L;
const H = z80.H;

const CF = z80.CF;
const NF = z80.NF;
const VF = z80.VF;
const PF = z80.PF;
const XF = z80.XF;
const HF = z80.HF;
const YF = z80.YF;
const ZF = z80.ZF;
const SF = z80.SF;

var cpu: Z80 = undefined;
var bus: u64 = 0;
var mem = [_]u8{0} ** 0x10000;
var out_port: u16 = 0;
var out_byte: u8 = 0;

const MREQ = z80.DefaultPins.MREQ;
const IORQ = z80.DefaultPins.IORQ;
const RD = z80.DefaultPins.RD;
const WR = z80.DefaultPins.WR;
const HALT = z80.DefaultPins.HALT;

fn T(cond: bool) void {
    assert(cond);
}

fn flags(f: u8) bool {
    // don't check undocumented flags
    return (cpu.r[F] & ~@as(u8, XF|YF)) == f;
}

fn start(msg: []const u8) void {
    std.debug.print("=> {s} ... ", .{msg});
}

fn ok() void {
    std.debug.print("ok\n", .{});
}

fn init(start_addr: u16, bytes: []const u8) void {
    cpu = Z80{};
    cpu.r[z80.F] = 0;
    cpu.af2 = 0xFF00;
    cpu.bc2 = 0xFFFF;
    cpu.de2 = 0xFFFF;
    cpu.hl2 = 0xFFFF;
    copy(start_addr, bytes);
    cpu.prefetch(start_addr);
    _ = step();
}

fn copy(start_addr: u16, bytes: []const u8) void {
    std.mem.copyForwards(u8, mem[start_addr..(start_addr+bytes.len)], bytes);
}

fn mem16(addr: u16) u16 {
    const l: u16 = mem[addr];
    const h: u16 = mem[addr +% 1];
    return (h<<8) | l;
}

fn tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if (bits.tst(bus, MREQ)) {
        if (bits.tst(bus, RD)) {
            bus = Z80.setData(bus, mem[addr]);
        } else if (bits.tst(bus, WR)) {
            mem[addr] = Z80.getData(bus);
        }
    } else if (bits.tst(bus, IORQ)) {
        if (bits.tst(bus, RD)) {
            bus = Z80.setData(bus, @truncate((Z80.getAddr(bus) & 0xFF) * 2));
        } else if (bits.tst(bus, WR)) {
            out_port = Z80.getAddr(bus);
            out_byte = Z80.getData(bus);
        }
    }
    // FIXME: IORQ
}

fn step() usize {
    var num_ticks: usize = 1;
    tick();
    while (!cpu.opdone(bus)) {
        tick();
        num_ticks += 1;
    }
    return num_ticks;
}

fn @"LD A,R/I"() void {
    start("LD A,R/I");
    const prog = [_]u8{
        0xED, 0x57,         // LD A,I
        0x97,               // SUB A
        0xED, 0x5F,         // LD A,R
    };
    init(0, &prog);
    cpu.iff1 = true;
    cpu.iff2 = true;
    cpu.setR(0x34);
    cpu.setI(0x01);
    cpu.r[F] = CF;
    T(9 == step()); T(0x01 == cpu.r[A]); T(flags(PF|CF));
    T(4 == step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(9 == step()); T(0x39 == cpu.r[A]); T(flags(PF));
    ok();
}

fn @"LD R/I,A"() void {
    start("LD R/I,A");
    const prog = [_]u8{
        0x3E, 0x45,     // LD A,0x45
        0xED, 0x47,     // LD I,A
        0xED, 0x4F,     // LD R,A
    };
    init(0, &prog);
    T(7==step()); T(0x45 == cpu.r[A]);
    T(9==step()); T(0x45 == cpu.I());
    T(9==step()); T(0x45 == cpu.R());
    ok();
}

fn RST() void {
    start("RST");
    const prog = [_]u8{
        0x31, 0x00, 0x01,   // LD SP,0x0100
        0xCF,               // RST 8h
        0x00, 0x00, 0x00, 0x00,
        0xFF,               // RST 38h
    };
    init(0, &prog);
    T(10 == step()); T(cpu.SP() == 0x0100);
    T(11 == step()); T(cpu.pc == 0x0009); T(cpu.SP() == 0x00FE); T(cpu.WZ() == 0x0008); T(mem16(0x00FE) == 0x0004);
    T(11 == step()); T(cpu.pc == 0x0039); T(cpu.SP() == 0x00FC); T(cpu.WZ() == 0x0038); T(mem16(0x00FC) == 0x0009);
    ok();
}

fn NOP() void {
    start("NOP");
    const prog = [_]u8{0};
    init(0, &prog);
    T(4 == step());
    T(4 == step());
    ok();
}

fn @"LD r,s/n"() void {
    start("LD r,s/n");
    const prog = [_]u8{
        0x3E, 0x12, // LD A,0x12
        0x47, // LD B,A
        0x4F, // LD C,A
        0x57, // LD D,A
        0x5F, // LD E,A
        0x67, // LD H,A
        0x6F, // LD L,A
        0x7F, // LD A,A
        0x06, 0x13, // LD B,0x13
        0x40, // LD B,B
        0x48, // LD C,B
        0x50, // LD D,B
        0x58, // LD E,B
        0x60, // LD H,B
        0x68, // LD L,B
        0x78, // LD A,B
        0x0E, 0x14, // LD C,0x14
        0x41, // LD B,C
        0x49, // LD C,C
        0x51, // LD D,C
        0x59, // LD E,C
        0x61, // LD H,C
        0x69, // LD L,C
        0x79, // LD A,C
        0x16, 0x15, // LD D,0x15
        0x42, // LD B,D
        0x4A, // LD C,D
        0x52, // LD D,D
        0x5A, // LD E,D
        0x62, // LD H,D
        0x6A, // LD L,D
        0x7A, // LD A,D
        0x1E, 0x16, // LD E,0x16
        0x43, // LD B,E
        0x4B, // LD C,E
        0x53, // LD D,E
        0x5B, // LD E,E
        0x63, // LD H,E
        0x6B, // LD L,E
        0x7B, // LD A,E
        0x26, 0x17, // LD H,0x17
        0x44, // LD B,H
        0x4C, // LD C,H
        0x54, // LD D,H
        0x5C, // LD E,H
        0x64, // LD H,H
        0x6C, // LD L,H
        0x7C, // LD A,H
        0x2E, 0x18, // LD L,0x18
        0x45, // LD B,L
        0x4D, // LD C,L
        0x55, // LD D,L
        0x5D, // LD E,L
        0x65, // LD H,L
        0x6D, // LD L,L
        0x7D, // LD A,L
    };
    init(0, &prog);
    T(7==step()); T(0x12==cpu.r[A]);
    T(4==step()); T(0x12==cpu.r[B]);
    T(4==step()); T(0x12==cpu.r[C]);
    T(4==step()); T(0x12==cpu.r[D]);
    T(4==step()); T(0x12==cpu.r[E]);
    T(4==step()); T(0x12==cpu.r[H]);
    T(4==step()); T(0x12==cpu.r[L]);
    T(4==step()); T(0x12==cpu.r[A]);
    T(7==step()); T(0x13==cpu.r[B]);
    T(4==step()); T(0x13==cpu.r[B]);
    T(4==step()); T(0x13==cpu.r[C]);
    T(4==step()); T(0x13==cpu.r[D]);
    T(4==step()); T(0x13==cpu.r[E]);
    T(4==step()); T(0x13==cpu.r[H]);
    T(4==step()); T(0x13==cpu.r[L]);
    T(4==step()); T(0x13==cpu.r[A]);
    T(7==step()); T(0x14==cpu.r[C]);
    T(4==step()); T(0x14==cpu.r[B]);
    T(4==step()); T(0x14==cpu.r[C]);
    T(4==step()); T(0x14==cpu.r[D]);
    T(4==step()); T(0x14==cpu.r[E]);
    T(4==step()); T(0x14==cpu.r[H]);
    T(4==step()); T(0x14==cpu.r[L]);
    T(4==step()); T(0x14==cpu.r[A]);
    T(7==step()); T(0x15==cpu.r[D]);
    T(4==step()); T(0x15==cpu.r[B]);
    T(4==step()); T(0x15==cpu.r[C]);
    T(4==step()); T(0x15==cpu.r[D]);
    T(4==step()); T(0x15==cpu.r[E]);
    T(4==step()); T(0x15==cpu.r[H]);
    T(4==step()); T(0x15==cpu.r[L]);
    T(4==step()); T(0x15==cpu.r[A]);
    T(7==step()); T(0x16==cpu.r[E]);
    T(4==step()); T(0x16==cpu.r[B]);
    T(4==step()); T(0x16==cpu.r[C]);
    T(4==step()); T(0x16==cpu.r[D]);
    T(4==step()); T(0x16==cpu.r[E]);
    T(4==step()); T(0x16==cpu.r[H]);
    T(4==step()); T(0x16==cpu.r[L]);
    T(4==step()); T(0x16==cpu.r[A]);
    T(7==step()); T(0x17==cpu.r[H]);
    T(4==step()); T(0x17==cpu.r[B]);
    T(4==step()); T(0x17==cpu.r[C]);
    T(4==step()); T(0x17==cpu.r[D]);
    T(4==step()); T(0x17==cpu.r[E]);
    T(4==step()); T(0x17==cpu.r[H]);
    T(4==step()); T(0x17==cpu.r[L]);
    T(4==step()); T(0x17==cpu.r[A]);
    T(7==step()); T(0x18==cpu.r[L]);
    T(4==step()); T(0x18==cpu.r[B]);
    T(4==step()); T(0x18==cpu.r[C]);
    T(4==step()); T(0x18==cpu.r[D]);
    T(4==step()); T(0x18==cpu.r[E]);
    T(4==step()); T(0x18==cpu.r[H]);
    T(4==step()); T(0x18==cpu.r[L]);
    T(4==step()); T(0x18==cpu.r[A]);
    ok();
}

fn @"LD r,(HL)"() void {
    start("LD r,(HL)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,   // LD HL,0x1000
        0x3E, 0x33,         // LD A,0x33
        0x77,               // LD (HL),A
        0x3E, 0x22,         // LD A,0x22
        0x46,               // LD B,(HL)
        0x4E,               // LD C,(HL)
        0x56,               // LD D,(HL)
        0x5E,               // LD E,(HL)
        0x66,               // LD H,(HL)
        0x26, 0x10,         // LD H,0x10
        0x6E,               // LD L,(HL)
        0x2E, 0x00,         // LD L,0x00
        0x7E,               // LD A,(HL)
    };
    init(0, &prog);
    T(10==step()); T(0x1000 == cpu.HL());
    T(7==step()); T(0x33 == cpu.r[A]);
    T(7==step()); T(0x33 == mem[0x1000]);
    T(7==step()); T(0x22 == cpu.r[A]);
    T(7==step()); T(0x33 == cpu.r[B]);
    T(7==step()); T(0x33 == cpu.r[C]);
    T(7==step()); T(0x33 == cpu.r[D]);
    T(7==step()); T(0x33 == cpu.r[E]);
    T(7==step()); T(0x33 == cpu.r[H]);
    T(7==step()); T(0x10 == cpu.r[H]);
    T(7==step()); T(0x33 == cpu.r[L]);
    T(7==step()); T(0x00 == cpu.r[L]);
    T(7==step()); T(0x33 == cpu.r[A]);
    ok();
}

fn @"LD (HL),r"() void {
    start("LD (HL),r");
    const prog = [_]u8{
        0x21, 0x00, 0x10,   // LD HL,0x1000
        0x3E, 0x12,         // LD A,0x12
        0x77,               // LD (HL),A
        0x06, 0x13,         // LD B,0x13
        0x70,               // LD (HL),B
        0x0E, 0x14,         // LD C,0x14
        0x71,               // LD (HL),C
        0x16, 0x15,         // LD D,0x15
        0x72,               // LD (HL),D
        0x1E, 0x16,         // LD E,0x16
        0x73,               // LD (HL),E
        0x74,               // LD (HL),H
        0x75,               // LD (HL),L
    };
    init(0, &prog);
    T(10==step()); T(0x1000 == cpu.HL());
    T(7==step()); T(0x12 == cpu.r[A]);
    T(7==step()); T(0x12 == mem[0x1000]);
    T(7==step()); T(0x13 == cpu.r[B]);
    T(7==step()); T(0x13 == mem[0x1000]);
    T(7==step()); T(0x14 == cpu.r[C]);
    T(7==step()); T(0x14 == mem[0x1000]);
    T(7==step()); T(0x15 == cpu.r[D]);
    T(7==step()); T(0x15 == mem[0x1000]);
    T(7==step()); T(0x16 == cpu.r[E]);
    T(7==step()); T(0x16 == mem[0x1000]);
    T(7==step()); T(0x10 == mem[0x1000]);
    T(7==step()); T(0x00 == mem[0x1000]);
    ok();
}

fn @"LD (IX/IY+d),r"() void {
    start("LD (IX/IY+d),r");
    const prog = [_]u8{
        0xDD, 0x21, 0x03, 0x10,     // LD IX,0x1003
        0x3E, 0x12,                 // LD A,0x12
        0xDD, 0x77, 0x00,           // LD (IX+0),A
        0x06, 0x13,                 // LD B,0x13
        0xDD, 0x70, 0x01,           // LD (IX+1),B
        0x0E, 0x14,                 // LD C,0x14
        0xDD, 0x71, 0x02,           // LD (IX+2),C
        0x16, 0x15,                 // LD D,0x15
        0xDD, 0x72, 0xFF,           // LD (IX-1),D
        0x1E, 0x16,                 // LD E,0x16
        0xDD, 0x73, 0xFE,           // LD (IX-2),E
        0x26, 0x17,                 // LD H,0x17
        0xDD, 0x74, 0x03,           // LD (IX+3),H
        0x2E, 0x18,                 // LD L,0x18
        0xDD, 0x75, 0xFD,           // LD (IX-3),L
        0xFD, 0x21, 0x03, 0x10,     // LD IY,0x1003
        0x3E, 0x12,                 // LD A,0x12
        0xFD, 0x77, 0x00,           // LD (IY+0),A
        0x06, 0x13,                 // LD B,0x13
        0xFD, 0x70, 0x01,           // LD (IY+1),B
        0x0E, 0x14,                 // LD C,0x14
        0xFD, 0x71, 0x02,           // LD (IY+2),C
        0x16, 0x15,                 // LD D,0x15
        0xFD, 0x72, 0xFF,           // LD (IY-1),D
        0x1E, 0x16,                 // LD E,0x16
        0xFD, 0x73, 0xFE,           // LD (IY-2),E
        0x26, 0x17,                 // LD H,0x17
        0xFD, 0x74, 0x03,           // LD (IY+3),H
        0x2E, 0x18,                 // LD L,0x18
        0xFD, 0x75, 0xFD,           // LD (IY-3),L
    };
    init(0, &prog);
    T(14 == step()); T(0x1003 == cpu.IX());
    T(7  == step()); T(0x12 == cpu.r[A]);
    T(19 == step()); T(0x12 == mem[0x1003]); T(cpu.WZ() == 0x1003);
    T(7  == step()); T(0x13 == cpu.r[B]);
    T(19 == step()); T(0x13 == mem[0x1004]); T(cpu.WZ() == 0x1004);
    T(7  == step()); T(0x14 == cpu.r[C]);
    T(19 == step()); T(0x14 == mem[0x1005]); T(cpu.WZ() == 0x1005);
    T(7  == step()); T(0x15 == cpu.r[D]);
    T(19 == step()); T(0x15 == mem[0x1002]); T(cpu.WZ() == 0x1002);
    T(7  == step()); T(0x16 == cpu.r[E]);
    T(19 == step()); T(0x16 == mem[0x1001]); T(cpu.WZ() == 0x1001);
    T(7  == step()); T(0x17 == cpu.r[H]);
    T(19 == step()); T(0x17 == mem[0x1006]); T(cpu.WZ() == 0x1006);
    T(7  == step()); T(0x18 == cpu.r[L]);
    T(19 == step()); T(0x18 == mem[0x1000]); T(cpu.WZ() == 0x1000);
    T(14 == step()); T(0x1003 == cpu.IY());
    T(7  == step()); T(0x12 == cpu.r[A]);
    T(19 == step()); T(0x12 == mem[0x1003]); T(cpu.WZ() == 0x1003);
    T(7  == step()); T(0x13 == cpu.r[B]);
    T(19 == step()); T(0x13 == mem[0x1004]); T(cpu.WZ() == 0x1004);
    T(7  == step()); T(0x14 == cpu.r[C]);
    T(19 == step()); T(0x14 == mem[0x1005]); T(cpu.WZ() == 0x1005);
    T(7  == step()); T(0x15 == cpu.r[D]);
    T(19 == step()); T(0x15 == mem[0x1002]); T(cpu.WZ() == 0x1002);
    T(7  == step()); T(0x16 == cpu.r[E]);
    T(19 == step()); T(0x16 == mem[0x1001]); T(cpu.WZ() == 0x1001);
    T(7  == step()); T(0x17 == cpu.r[H]);
    T(19 == step()); T(0x17 == mem[0x1006]); T(cpu.WZ() == 0x1006);
    T(7  == step()); T(0x18 == cpu.r[L]);
    T(19 == step()); T(0x18 == mem[0x1000]); T(cpu.WZ() == 0x1000);
    ok();
}

fn @"LD (HL),n"() void {
    start("LD (HL),n");
    const prog = [_]u8{
        0x21, 0x00, 0x20,   // LD HL,0x2000
        0x36, 0x33,         // LD (HL),0x33
        0x21, 0x00, 0x10,   // LD HL,0x1000
        0x36, 0x65,         // LD (HL),0x65
    };
    init(0, &prog);
    T(10==step()); T(0x2000 == cpu.HL());
    T(10==step()); T(0x33 == mem[0x2000]);
    T(10==step()); T(0x1000 == cpu.HL());
    T(10==step()); T(0x65 == mem[0x1000]);
    ok();
}

fn @"LD (IX/IY+d),n"() void {
    start("LD (IX/IY+d),n");
    const prog = [_]u8{
        0xDD, 0x21, 0x00, 0x20,     // LD IX,0x2000
        0xDD, 0x36, 0x02, 0x33,     // LD (IX+2),0x33
        0xDD, 0x36, 0xFE, 0x11,     // LD (IX-2),0x11
        0xFD, 0x21, 0x00, 0x10,     // LD IY,0x1000
        0xFD, 0x36, 0x01, 0x22,     // LD (IY+1),0x22
        0xFD, 0x36, 0xFF, 0x44,     // LD (IY-1),0x44
    };
    init(0, &prog);
    T(14==step()); T(0x2000 == cpu.IX());
    T(19==step()); T(0x33 == mem[0x2002]); T(cpu.WZ() == 0x2002);
    T(19==step()); T(0x11 == mem[0x1FFE]); T(cpu.WZ() == 0x1FFE);
    T(14==step()); T(0x1000 == cpu.IY());
    T(19==step()); T(0x22 == mem[0x1001]); T(cpu.WZ() == 0x1001);
    T(19==step()); T(0x44 == mem[0x0FFF]); T(cpu.WZ() == 0x0FFF);
    ok();
}

fn @"LD A,(BC/DE/nn)"() void {
    start("LD A,(BC/DE/nn)");
    const prog = [_]u8{
        0x01, 0x00, 0x10,   // LD BC,0x1000
        0x11, 0x01, 0x10,   // LD DE,0x1001
        0x0A,               // LD A,(BC)
        0x1A,               // LD A,(DE)
        0x3A, 0x02, 0x10,   // LD A,(0x1002)
    };
    init(0, &prog);
    const data = [_]u8{ 0x11, 0x22, 0x33 };
    copy(0x1000, &data);
    T(10==step()); T(0x1000 == cpu.BC());
    T(10==step()); T(0x1001 == cpu.DE());
    T(7==step()); T(0x11 == cpu.r[A]); T(0x1001 == cpu.WZ());
    T(7==step()); T(0x22 == cpu.r[A]); T(0x1002 == cpu.WZ());
    T(13==step()); T(0x33 == cpu.r[A]); T(0x1003 == cpu.WZ());
    ok();
}

fn @"LD (BC/DE/nn),A"() void {
    start("LD (BC/DE/nn),A");
    const prog = [_]u8{
        0x01, 0x00, 0x10,   // LD BC,0x1000
        0x11, 0x01, 0x10,   // LD DE,0x1001
        0x3E, 0x77,         // LD A,0x77
        0x02,               // LD (BC),A
        0x12,               // LD (DE),A
        0x32, 0x02, 0x10,   // LD (0x1002),A
    };
    init(0, &prog);
    T(10==step()); T(0x1000 == cpu.BC());
    T(10==step()); T(0x1001 == cpu.DE());
    T(7==step());  T(0x77 == cpu.r[A]);
    T(7==step());  T(0x77 == mem[0x1000]); T(0x7701 == cpu.WZ());
    T(7==step());  T(0x77 == mem[0x1001]); T(0x7702 == cpu.WZ());
    T(13==step()); T(0x77 == mem[0x1002]); T(0x7703 == cpu.WZ());
    ok();
}

fn @"LD dd/IX/IY,nn"() void {
    start("LD dd/IX/IY,nn");
    const prog = [_]u8{
        0x01, 0x34, 0x12,       // LD BC,0x1234
        0x11, 0x78, 0x56,       // LD DE,0x5678
        0x21, 0xBC, 0x9A,       // LD HL,0x9ABC
        0x31, 0x68, 0x13,       // LD SP,0x1368
        0xDD, 0x21, 0x21, 0x43, // LD IX,0x4321
        0xFD, 0x21, 0x65, 0x87, // LD IY,0x8765
    };
    init(0, &prog);
    T(10==step()); T(0x1234 == cpu.BC());
    T(10==step()); T(0x5678 == cpu.DE());
    T(10==step()); T(0x9ABC == cpu.HL());
    T(10==step()); T(0x1368 == cpu.SP());
    T(14==step()); T(0x4321 == cpu.IX());
    T(14==step()); T(0x8765 == cpu.IY());
    ok();
}

fn @"LD dd/IX/IY,(nn)"() void {
    start("LD dd/IX/IY,(nn)");
    const prog = [_]u8{
        0x2A, 0x00, 0x10,           // LD HL,(0x1000)
        0xED, 0x4B, 0x01, 0x10,     // LD BC,(0x1001)
        0xED, 0x5B, 0x02, 0x10,     // LD DE,(0x1002)
        0xED, 0x6B, 0x03, 0x10,     // LD HL,(0x1003) undocumented 'long' version
        0xED, 0x7B, 0x04, 0x10,     // LD SP,(0x1004)
        0xDD, 0x2A, 0x05, 0x10,     // LD IX,(0x1005)
        0xFD, 0x2A, 0x06, 0x10,     // LD IY,(0x1006)
    };
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    };
    init(0, &prog);
    copy(0x1000, &data);
    T(16==step()); T(0x0201 == cpu.HL()); T(0x1001 == cpu.WZ());
    T(20==step()); T(0x0302 == cpu.BC()); T(0x1002 == cpu.WZ());
    T(20==step()); T(0x0403 == cpu.DE()); T(0x1003 == cpu.WZ());
    T(20==step()); T(0x0504 == cpu.HL()); T(0x1004 == cpu.WZ());
    T(20==step()); T(0x0605 == cpu.SP()); T(0x1005 == cpu.WZ());
    T(20==step()); T(0x0706 == cpu.IX()); T(0x1006 == cpu.WZ());
    T(20==step()); T(0x0807 == cpu.IY()); T(0x1007 == cpu.WZ());
    ok();
}

fn @"LD (nn),dd/IX/IY"() void {
    start("LD (nn),dd/IX/IY");
    const prog = [_]u8{
        0x21, 0x01, 0x02,           // LD HL,0x0201
        0x22, 0x00, 0x10,           // LD (0x1000),HL
        0x01, 0x34, 0x12,           // LD BC,0x1234
        0xED, 0x43, 0x02, 0x10,     // LD (0x1002),BC
        0x11, 0x78, 0x56,           // LD DE,0x5678
        0xED, 0x53, 0x04, 0x10,     // LD (0x1004),DE
        0x21, 0xBC, 0x9A,           // LD HL,0x9ABC
        0xED, 0x63, 0x06, 0x10,     // LD (0x1006),HL undocumented 'long' version
        0x31, 0x68, 0x13,           // LD SP,0x1368
        0xED, 0x73, 0x08, 0x10,     // LD (0x1008),SP
        0xDD, 0x21, 0x21, 0x43,     // LD IX,0x4321
        0xDD, 0x22, 0x0A, 0x10,     // LD (0x100A),IX
        0xFD, 0x21, 0x65, 0x87,     // LD IY,0x8765
        0xFD, 0x22, 0x0C, 0x10,     // LD (0x100C),IY
    };
    init(0, &prog);
    T(10==step()); T(0x0201 == cpu.HL());
    T(16==step()); T(0x0201 == mem16(0x1000)); T(0x1001 == cpu.WZ());
    T(10==step()); T(0x1234 == cpu.BC());
    T(20==step()); T(0x1234 == mem16(0x1002)); T(0x1003 == cpu.WZ());
    T(10==step()); T(0x5678 == cpu.DE());
    T(20==step()); T(0x5678 == mem16(0x1004)); T(0x1005 == cpu.WZ());
    T(10==step()); T(0x9ABC == cpu.HL());
    T(20==step()); T(0x9ABC == mem16(0x1006)); T(0x1007 == cpu.WZ());
    T(10==step()); T(0x1368 == cpu.SP());
    T(20==step()); T(0x1368 == mem16(0x1008)); T(0x1009 == cpu.WZ());
    T(14==step()); T(0x4321 == cpu.IX());
    T(20==step()); T(0x4321 == mem16(0x100A)); T(0x100B == cpu.WZ());
    T(14==step()); T(0x8765 == cpu.IY());
    T(20==step()); T(0x8765 == mem16(0x100C)); T(0x100D == cpu.WZ());
    ok();
}

fn @"LD SP,HL/IX/IY"() void {
    start("LD SP,HL/IX/IY");
    const prog = [_]u8{
        0x21, 0x34, 0x12,           // LD HL,0x1234
        0xDD, 0x21, 0x78, 0x56,     // LD IX,0x5678
        0xFD, 0x21, 0xBC, 0x9A,     // LD IY,0x9ABC
        0xF9,                       // LD SP,HL
        0xDD, 0xF9,                 // LD SP,IX
        0xFD, 0xF9,                 // LD SP,IY
    };
    init(0, &prog);
    T(10 == step()); T(0x1234 == cpu.HL());
    T(14 == step()); T(0x5678 == cpu.IX());
    T(14 == step()); T(0x9ABC == cpu.IY());
    T(6  == step()); T(0x1234 == cpu.SP());
    T(10 == step()); T(0x5678 == cpu.SP());
    T(10 == step()); T(0x9ABC == cpu.SP());
    ok();
}

fn @"PUSH/POP qq/IX/IY"() void {
    start("PUSH/POP qq/IX/IY");
    const prog = [_]u8{
        0x01, 0x34, 0x12,       // LD BC,0x1234
        0x11, 0x78, 0x56,       // LD DE,0x5678
        0x21, 0xBC, 0x9A,       // LD HL,0x9ABC
        0x3E, 0xEF,             // LD A,0xEF
        0xDD, 0x21, 0x45, 0x23, // LD IX,0x2345
        0xFD, 0x21, 0x89, 0x67, // LD IY,0x6789
        0x31, 0x00, 0x01,       // LD SP,0x0100
        0xF5,                   // PUSH AF
        0xC5,                   // PUSH BC
        0xD5,                   // PUSH DE
        0xE5,                   // PUSH HL
        0xDD, 0xE5,             // PUSH IX
        0xFD, 0xE5,             // PUSH IY
        0xF1,                   // POP AF
        0xC1,                   // POP BC
        0xD1,                   // POP DE
        0xE1,                   // POP HL
        0xDD, 0xE1,             // POP IX
        0xFD, 0xE1,             // POP IY
    };
    init(0, &prog);
    T(10 == step()); T(0x1234 == cpu.BC());
    T(10 == step()); T(0x5678 == cpu.DE());
    T(10 == step()); T(0x9ABC == cpu.HL());
    T(7  == step()); T(0xEF00 == cpu.AF());
    T(14 == step()); T(0x2345 == cpu.IX());
    T(14 == step()); T(0x6789 == cpu.IY());
    T(10 == step()); T(0x0100 == cpu.SP());
    T(11 == step()); T(0xEF00 == mem16(0x00FE)); T(0x00FE == cpu.SP());
    T(11 == step()); T(0x1234 == mem16(0x00FC)); T(0x00FC == cpu.SP());
    T(11 == step()); T(0x5678 == mem16(0x00FA)); T(0x00FA == cpu.SP());
    T(11 == step()); T(0x9ABC == mem16(0x00F8)); T(0x00F8 == cpu.SP());
    T(15 == step()); T(0x2345 == mem16(0x00F6)); T(0x00F6 == cpu.SP());
    T(15 == step()); T(0x6789 == mem16(0x00F4)); T(0x00F4 == cpu.SP());
    T(10 == step()); T(0x6789 == cpu.AF()); T(0x00F6 == cpu.SP());
    T(10 == step()); T(0x2345 == cpu.BC()); T(0x00F8 == cpu.SP());
    T(10 == step()); T(0x9ABC == cpu.DE()); T(0x00FA == cpu.SP());
    T(10 == step()); T(0x5678 == cpu.HL()); T(0x00FC == cpu.SP());
    T(14 == step()); T(0x1234 == cpu.IX()); T(0x00FE == cpu.SP());
    T(14 == step()); T(0xEF00 == cpu.IY()); T(0x0100 == cpu.SP());
    ok();
}

fn EX() void {
    start("EXX / EX DE,HL / EX AF,AF' / EX (SP),HL/IX/IY");
    const prog = [_]u8{
        0x21, 0x34, 0x12,       // LD HL,0x1234
        0x11, 0x78, 0x56,       // LD DE,0x5678
        0xEB,                   // EX DE,HL
        0x3E, 0x11,             // LD A,0x11
        0x08,                   // EX AF,AF'
        0x3E, 0x22,             // LD A,0x22
        0x08,                   // EX AF,AF'
        0x01, 0xBC, 0x9A,       // LD BC,0x9ABC
        0xD9,                   // EXX
        0x21, 0x11, 0x11,       // LD HL,0x1111
        0x11, 0x22, 0x22,       // LD DE,0x2222
        0x01, 0x33, 0x33,       // LD BC,0x3333
        0xD9,                   // EXX
        0x31, 0x00, 0x01,       // LD SP,0x0100
        0xD5,                   // PUSH DE
        0xE3,                   // EX (SP),HL
        0xDD, 0x21, 0x99, 0x88, // LD IX,0x8899
        0xDD, 0xE3,             // EX (SP),IX
        0xFD, 0x21, 0x77, 0x66, // LD IY,0x6677
        0xFD, 0xE3,             // EX (SP),IY
    };
    init (0, &prog);
    T(10 == step()); T(0x1234 == cpu.HL());
    T(10 == step()); T(0x5678 == cpu.DE());
    T(4  == step()); T(0x1234 == cpu.DE()); T(0x5678 == cpu.HL());
    T(7  == step()); T(0x1100 == cpu.AF()); T(0xFF00 == cpu.af2);
    T(4  == step()); T(0xFF00 == cpu.AF()); T(0x1100 == cpu.af2);
    T(7  == step()); T(0x2200 == cpu.AF()); T(0x1100 == cpu.af2);
    T(4  == step()); T(0x1100 == cpu.AF()); T(0x2200 == cpu.af2);
    T(10 == step()); T(0x9ABC == cpu.BC());
    T(4  == step());
    T(0xFFFF == cpu.HL()); T(0x5678 == cpu.hl2);
    T(0xFFFF == cpu.DE()); T(0x1234 == cpu.de2);
    T(0xFFFF == cpu.BC()); T(0x9ABC == cpu.bc2);
    T(10 == step()); T(0x1111 == cpu.HL());
    T(10 == step()); T(0x2222 == cpu.DE());
    T(10 == step()); T(0x3333 == cpu.BC());
    T(4  == step());
    T(0x5678 == cpu.HL()); T(0x1111 == cpu.hl2);
    T(0x1234 == cpu.DE()); T(0x2222 == cpu.de2);
    T(0x9ABC == cpu.BC()); T(0x3333 == cpu.bc2);
    T(10 == step()); T(0x0100 == cpu.SP());
    T(11 == step()); T(0x1234 == mem16(0x00FE));
    T(19 == step()); T(0x1234 == cpu.HL()); T(cpu.WZ() == cpu.HL()); T(0x5678 == mem16(0x00FE));
    T(14 == step()); T(0x8899 == cpu.IX());
    T(23 == step()); T(0x5678 == cpu.IX()); T(cpu.WZ() == cpu.IX()); T(0x8899 == mem16(0x00FE));
    T(14 == step()); T(0x6677 == cpu.IY());
    T(23 == step()); T(0x8899 == cpu.IY()); T(cpu.WZ() == cpu.IY()); T(0x6677 == mem16(0x00FE));
    ok();
}

fn @"ADD A,r/n"() void {
    start("ADD A,r/n");
    const prog = [_]u8{
        0x3E, 0x0F,     // LD A,0x0F
        0x87,           // ADD A,A
        0x06, 0xE0,     // LD B,0xE0
        0x80,           // ADD A,B
        0x3E, 0x81,     // LD A,0x81
        0x0E, 0x80,     // LD C,0x80
        0x81,           // ADD A,C
        0x16, 0xFF,     // LD D,0xFF
        0x82,           // ADD A,D
        0x1E, 0x40,     // LD E,0x40
        0x83,           // ADD A,E
        0x26, 0x80,     // LD H,0x80
        0x84,           // ADD A,H
        0x2E, 0x33,     // LD L,0x33
        0x85,           // ADD A,L
        0xC6, 0x44,     // ADD A,0x44
    };
    init(0, &prog);
    T(7==step()); T(0x0F == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x1E == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xE0 == cpu.r[B]);
    T(4==step()); T(0xFE == cpu.r[A]); T(flags(SF));
    T(7==step()); T(0x81 == cpu.r[A]);
    T(7==step()); T(0x80 == cpu.r[C]);
    T(4==step()); T(0x01 == cpu.r[A]); T(flags(VF|CF));
    T(7==step()); T(0xFF == cpu.r[D]);
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|HF|CF));
    T(7==step()); T(0x40 == cpu.r[E]);
    T(4==step()); T(0x40 == cpu.r[A]); T(flags(0));
    T(7==step()); T(0x80 == cpu.r[H]);
    T(4==step()); T(0xC0 == cpu.r[A]); T(flags(SF));
    T(7==step()); T(0x33 == cpu.r[L]);
    T(4==step()); T(0xF3 == cpu.r[A]); T(flags(SF));
    T(7==step()); T(0x37 == cpu.r[A]); T(flags(CF));
    ok();
}

fn @"ADD A,(HL/IX+d/IY+d)"() void {
    start("ADD A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10, // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10, // LD IY,0x1003
        0x3E, 0x00,             // LD A,0x00
        0x86,                   // ADD A,(HL)
        0xDD, 0x86, 0x01,       // ADD A,(IX+1)
        0xFD, 0x86, 0xFF,       // ADD A,(IY-1)
    };
    const data = [_]u8{
        0x41, 0x61, 0x81,
    };
    init(0, &prog);
    copy(0x1000, &data);
    T(10 == step()); T(0x1000 == cpu.HL());
    T(14 == step()); T(0x1000 == cpu.IX());
    T(14 == step()); T(0x1003 == cpu.IY());
    T(7  == step()); T(0x00 == cpu.r[A]);
    T(7  == step()); T(0x41 == cpu.r[A]); T(flags(0));
    T(19 == step()); T(0xA2 == cpu.r[A]); T(flags(SF|VF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0x23 == cpu.r[A]); T(flags(VF|CF)); T(cpu.WZ() == 0x1002);
    ok();
}

fn @"ADC A,r/n"() void {
    start("ADC A,r/n");
    const prog = [_]u8 {
        0x3E, 0x00,         // LD A,0x00
        0x06, 0x41,         // LD B,0x41
        0x0E, 0x61,         // LD C,0x61
        0x16, 0x81,         // LD D,0x81
        0x1E, 0x41,         // LD E,0x41
        0x26, 0x61,         // LD H,0x61
        0x2E, 0x81,         // LD L,0x81
        0x8F,               // ADC A,A
        0x88,               // ADC A,B
        0x89,               // ADC A,C
        0x8A,               // ADC A,D
        0x8B,               // ADC A,E
        0x8C,               // ADC A,H
        0x8D,               // ADC A,L
        0xCE, 0x01,         // ADC A,0x01
    };
    init(0, &prog);
    T(7==step()); T(0x00 == cpu.r[A]);
    T(7==step()); T(0x41 == cpu.r[B]);
    T(7==step()); T(0x61 == cpu.r[C]);
    T(7==step()); T(0x81 == cpu.r[D]);
    T(7==step()); T(0x41 == cpu.r[E]);
    T(7==step()); T(0x61 == cpu.r[H]);
    T(7==step()); T(0x81 == cpu.r[L]);
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF));
    T(4==step()); T(0x41 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0xA2 == cpu.r[A]); T(flags(SF|VF));
    T(4==step()); T(0x23 == cpu.r[A]); T(flags(VF|CF));
    T(4==step()); T(0x65 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0xC6 == cpu.r[A]); T(flags(SF|VF));
    T(4==step()); T(0x47 == cpu.r[A]); T(flags(VF|CF));
    T(7==step()); T(0x49 == cpu.r[A]); T(flags(0));
    ok();
}

fn @"ADC A,(HL/IX+d/IY+d)"() void {
    start("ADC A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10, // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10, // LD IY,0x1003
        0x3E, 0x00,             // LD A,0x00
        0x86,                   // ADD A,(HL)
        0xDD, 0x8E, 0x01,       // ADC A,(IX+1)
        0xFD, 0x8E, 0xFF,       // ADC A,(IY-1)
        0xDD, 0x8E, 0x03,       // ADC A,(IX+3)
    };
    const data = [_]u8{
        0x41, 0x61, 0x81, 0x02
    };
    init(0, &prog);
    copy(0x1000, &data);
    T(10 == step()); T(0x1000 == cpu.HL());
    T(14 == step()); T(0x1000 == cpu.IX());
    T(14 == step()); T(0x1003 == cpu.IY());
    T(7  == step()); T(0x00 == cpu.r[A]);
    T(7  == step()); T(0x41 == cpu.r[A]); T(flags(0));
    T(19 == step()); T(0xA2 == cpu.r[A]); T(flags(SF|VF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0x23 == cpu.r[A]); T(flags(VF|CF)); T(cpu.WZ() == 0x1002);
    T(19 == step()); T(0x26 == cpu.r[A]); T(flags(0)); T(cpu.WZ() == 0x1003);
    ok();
}

fn @"SUB A,r/n"() void {
    start("SUB A,r/n");
    const prog = [_]u8{
        0x3E, 0x04,     // LD A,0x04
        0x06, 0x01,     // LD B,0x01
        0x0E, 0xF8,     // LD C,0xF8
        0x16, 0x0F,     // LD D,0x0F
        0x1E, 0x79,     // LD E,0x79
        0x26, 0xC0,     // LD H,0xC0
        0x2E, 0xBF,     // LD L,0xBF
        0x97,           // SUB A,A
        0x90,           // SUB A,B
        0x91,           // SUB A,C
        0x92,           // SUB A,D
        0x93,           // SUB A,E
        0x94,           // SUB A,H
        0x95,           // SUB A,L
        0xD6, 0x01,     // SUB A,0x01
        0xD6, 0xFE,     // SUB A,0xFE
    };
    init(0, &prog);
    T(7==step()); T(0x04 == cpu.r[A]);
    T(7==step()); T(0x01 == cpu.r[B]);
    T(7==step()); T(0xF8 == cpu.r[C]);
    T(7==step()); T(0x0F == cpu.r[D]);
    T(7==step()); T(0x79 == cpu.r[E]);
    T(7==step()); T(0xC0 == cpu.r[H]);
    T(7==step()); T(0xBF == cpu.r[L]);
    T(4==step()); T(0x0 == cpu.r[A]); T(flags(ZF|NF));
    T(4==step()); T(0xFF == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(4==step()); T(0x07 == cpu.r[A]); T(flags(NF));
    T(4==step()); T(0xF8 == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(4==step()); T(0x7F == cpu.r[A]); T(flags(HF|VF|NF));
    T(4==step()); T(0xBF == cpu.r[A]); T(flags(SF|VF|NF|CF));
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(7==step()); T(0x01 == cpu.r[A]); T(flags(NF));
    ok();
}

fn @"SUB A,(HL/IX+d/IY+d)"() void {
    start("SUB A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10, // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10, // LD IY,0x1003
        0x3E, 0x00,             // LD A,0x00
        0x96,                   // SUB A,(HL)
        0xDD, 0x96, 0x01,       // SUB A,(IX+1)
        0xFD, 0x96, 0xFE,       // SUB A,(IY-2)
    };
    const data = [_]u8{ 0x41, 0x61, 0x81 };
    init(0, &prog);
    copy(0x1000, &data);
    T(10 == step()); T(0x1000 == cpu.HL());
    T(14 == step()); T(0x1000 == cpu.IX());
    T(14 == step()); T(0x1003 == cpu.IY());
    T(7  == step()); T(0x00 == cpu.r[A]);
    T(7  == step()); T(0xBF == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(19 == step()); T(0x5E == cpu.r[A]); T(flags(VF|NF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0xFD == cpu.r[A]); T(flags(SF|NF|CF)); T(cpu.WZ() == 0x1001);
    ok();
}

fn @"SBC A,r/n"() void {
    start("SBC A,r/n");
    const prog = [_]u8{
        0x3E, 0x04,     // LD A,0x04
        0x06, 0x01,     // LD B,0x01
        0x0E, 0xF8,     // LD C,0xF8
        0x16, 0x0F,     // LD D,0x0F
        0x1E, 0x79,     // LD E,0x79
        0x26, 0xC0,     // LD H,0xC0
        0x2E, 0xBF,     // LD L,0xBF
        0x97,           // SUB A,A
        0x98,           // SBC A,B
        0x99,           // SBC A,C
        0x9A,           // SBC A,D
        0x9B,           // SBC A,E
        0x9C,           // SBC A,H
        0x9D,           // SBC A,L
        0xDE, 0x01,     // SBC A,0x01
        0xDE, 0xFE,     // SBC A,0xFE
    };
    init(0, &prog);
    for (0..7) |_| {
        _ = step();
    }
    T(4==step()); T(0x0 == cpu.r[A]); T(flags(ZF|NF));
    T(4==step()); T(0xFF == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(4==step()); T(0x06 == cpu.r[A]); T(flags(NF));
    T(4==step()); T(0xF7 == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(4==step()); T(0x7D == cpu.r[A]); T(flags(HF|VF|NF));
    T(4==step()); T(0xBD == cpu.r[A]); T(flags(SF|VF|NF|CF));
    T(4==step()); T(0xFD == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(7==step()); T(0xFB == cpu.r[A]); T(flags(SF|NF));
    T(7==step()); T(0xFD == cpu.r[A]); T(flags(SF|HF|NF|CF));
    ok();
}

fn @"SBC A,(HL/IX+d/IY+d)"() void {
    start("SBC A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10, // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10, // LD IY,0x1003
        0x3E, 0x00,             // LD A,0x00
        0x9E,                   // SBC A,(HL)
        0xDD, 0x9E, 0x01,       // SBC A,(IX+1)
        0xFD, 0x9E, 0xFE,       // SBC A,(IY-2)
    };
    const data = [_]u8{ 0x41, 0x61, 0x81 };
    init(0, &prog);
    copy(0x1000, &data);
    T(10 == step()); T(0x1000 == cpu.HL());
    T(14 == step()); T(0x1000 == cpu.IX());
    T(14 == step()); T(0x1003 == cpu.IY());
    T(7  == step()); T(0x00 == cpu.r[A]);
    T(7  == step()); T(0xBF == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(19 == step()); T(0x5D == cpu.r[A]); T(flags(VF|NF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0xFC == cpu.r[A]); T(flags(SF|NF|CF)); T(cpu.WZ() == 0x1001);
    ok();
}

fn @"CP A,r/n"() void {
    start("CP A,r/n");
    const prog = [_]u8{
        0x3E, 0x04,     // LD A,0x04
        0x06, 0x05,     // LD B,0x05
        0x0E, 0x03,     // LD C,0x03
        0x16, 0xff,     // LD D,0xff
        0x1E, 0xaa,     // LD E,0xaa
        0x26, 0x80,     // LD H,0x80
        0x2E, 0x7f,     // LD L,0x7f
        0xBF,           // CP A
        0xB8,           // CP B
        0xB9,           // CP C
        0xBA,           // CP D
        0xBB,           // CP E
        0xBC,           // CP H
        0xBD,           // CP L
        0xFE, 0x04,     // CP 0x04
    };
    init(0, &prog);
    T(7==step()); T(0x04 == cpu.r[A]);
    T(7==step()); T(0x05 == cpu.r[B]);
    T(7==step()); T(0x03 == cpu.r[C]);
    T(7==step()); T(0xff == cpu.r[D]);
    T(7==step()); T(0xaa == cpu.r[E]);
    T(7==step()); T(0x80 == cpu.r[H]);
    T(7==step()); T(0x7f == cpu.r[L]);
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(ZF|NF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(NF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(HF|NF|CF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(HF|NF|CF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(SF|VF|NF|CF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(7==step()); T(0x04 == cpu.r[A]); T(flags(ZF|NF));
    ok();
}

fn @"CP A,(HL/IX+d/IY+d)"() void {
    start("CP A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10, // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10, // LD IY,0x1003
        0x3E, 0x41,             // LD A,0x41
        0xBE,                   // CP (HL)
        0xDD, 0xBE, 0x01,       // CP (IX+1)
        0xFD, 0xBE, 0xFF,       // CP (IY-1)
    };
    const data = [_]u8{ 0x41, 0x61, 0x22 };
    init(0, &prog);
    copy(0x1000, &data);
    T(10 == step()); T(0x1000 == cpu.HL());
    T(14 == step()); T(0x1000 == cpu.IX());
    T(14 == step()); T(0x1003 == cpu.IY());
    T(7  == step()); T(0x41 == cpu.r[A]);
    T(7  == step()); T(0x41 == cpu.r[A]); T(flags(ZF|NF));
    T(19 == step()); T(0x41 == cpu.r[A]); T(flags(SF|NF|CF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0x41 == cpu.r[A]); T(flags(HF|NF)); T(cpu.WZ() == 0x1002);
    ok();
}

fn @"AND A,r/n"() void {
    start("AND A,r/n");
    const prog = [_]u8{
        0x3E, 0xFF,             // LD A,0xFF
        0x06, 0x01,             // LD B,0x01
        0x0E, 0x03,             // LD C,0x02
        0x16, 0x04,             // LD D,0x04
        0x1E, 0x08,             // LD E,0x08
        0x26, 0x10,             // LD H,0x10
        0x2E, 0x20,             // LD L,0x20
        0xA0,                   // AND B
        0xF6, 0xFF,             // OR 0xFF
        0xA1,                   // AND C
        0xF6, 0xFF,             // OR 0xFF
        0xA2,                   // AND D
        0xF6, 0xFF,             // OR 0xFF
        0xA3,                   // AND E
        0xF6, 0xFF,             // OR 0xFF
        0xA4,                   // AND H
        0xF6, 0xFF,             // OR 0xFF
        0xA5,                   // AND L
        0xF6, 0xFF,             // OR 0xFF
        0xE6, 0x40,             // AND 0x40
        0xF6, 0xFF,             // OR 0xFF
        0xE6, 0xAA,             // AND 0xAA
    };
    init(0, &prog);
    for (0..7) |_| {
        _ = step();
    }
    T(4==step()); T(0x01 == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(4==step()); T(0x03 == cpu.r[A]); T(flags(HF|PF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(4==step()); T(0x04 == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(4==step()); T(0x08 == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(4==step()); T(0x10 == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(4==step()); T(0x20 == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(7==step()); T(0x40 == cpu.r[A]); T(flags(HF));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    T(7==step()); T(0xAA == cpu.r[A]); T(flags(SF|HF|PF));
    ok();
}

fn @"AND A,(HL/IX+d/IY+d)"() void {
    start("AND A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,           // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10,     // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10,     // LD IY,0x1003
        0x3E, 0xFF,                 // LD A,0xFF
        0xA6,                       // AND (HL)
        0xDD, 0xA6, 0x01,           // AND (IX+1)
        0xFD, 0xA6, 0xFF,           // AND (IX-1)
    };
    const data = [_]u8{ 0xFE, 0xAA, 0x99 };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..4) |_| {
        _ = step();
    }
    T(7  == step()); T(0xFE == cpu.r[A]); T(flags(SF|HF));
    T(19 == step()); T(0xAA == cpu.r[A]); T(flags(SF|HF|PF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0x88 == cpu.r[A]); T(flags(SF|HF|PF)); T(cpu.WZ() == 0x1002);
    ok();
}

fn @"XOR A,r/n"() void {
    start("XOR A,r/n");
    const prog = [_]u8{
        0x97,           // SUB A
        0x06, 0x01,     // LD B,0x01
        0x0E, 0x03,     // LD C,0x03
        0x16, 0x07,     // LD D,0x07
        0x1E, 0x0F,     // LD E,0x0F
        0x26, 0x1F,     // LD H,0x1F
        0x2E, 0x3F,     // LD L,0x3F
        0xAF,           // XOR A
        0xA8,           // XOR B
        0xA9,           // XOR C
        0xAA,           // XOR D
        0xAB,           // XOR E
        0xAC,           // XOR H
        0xAD,           // XOR L
        0xEE, 0x7F,     // XOR 0x7F
        0xEE, 0xFF,     // XOR 0xFF
    };
    init(0, &prog);
    for (0..7) |_| {
        _ = step();
    }
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|PF));
    T(4==step()); T(0x01 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x02 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x05 == cpu.r[A]); T(flags(PF));
    T(4==step()); T(0x0A == cpu.r[A]); T(flags(PF));
    T(4==step()); T(0x15 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x2A == cpu.r[A]); T(flags(0));
    T(7==step()); T(0x55 == cpu.r[A]); T(flags(PF));
    T(7==step()); T(0xAA == cpu.r[A]); T(flags(SF|PF));
    ok();
}

fn @"OR A,r/n"() void {
    start("OR A,r/n");
    const prog = [_]u8{
        0x97,           // SUB A
        0x06, 0x01,     // LD B,0x01
        0x0E, 0x02,     // LD C,0x02
        0x16, 0x04,     // LD D,0x04
        0x1E, 0x08,     // LD E,0x08
        0x26, 0x10,     // LD H,0x10
        0x2E, 0x20,     // LD L,0x20
        0xB7,           // OR A
        0xB0,           // OR B
        0xB1,           // OR C
        0xB2,           // OR D
        0xB3,           // OR E
        0xB4,           // OR H
        0xB5,           // OR L
        0xF6, 0x40,     // OR 0x40
        0xF6, 0x80,     // OR 0x80
    };
    init(0, &prog);
    for (0..7) |_| {
        _ = step();
    }
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|PF));
    T(4==step()); T(0x01 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x03 == cpu.r[A]); T(flags(PF));
    T(4==step()); T(0x07 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x0F == cpu.r[A]); T(flags(PF));
    T(4==step()); T(0x1F == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x3F == cpu.r[A]); T(flags(PF));
    T(7==step()); T(0x7F == cpu.r[A]); T(flags(0));
    T(7==step()); T(0xFF == cpu.r[A]); T(flags(SF|PF));
    ok();
}

fn @"OR/XOR A,(HL/IX+d/IY+d)"() void {
    start("OR/XOR A,(HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x3E, 0x00,                 // LD A,0x00
        0x21, 0x00, 0x10,           // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10,     // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10,     // LD IY,0x1003
        0xB6,                       // OR (HL)
        0xDD, 0xB6, 0x01,           // OR (IX+1)
        0xFD, 0xB6, 0xFF,           // OR (IY-1)
        0xAE,                       // XOR (HL)
        0xDD, 0xAE, 0x01,           // XOR (IX+1)
        0xFD, 0xAE, 0xFF,           // XOR (IY-1)
    };
    const data = [_]u8{ 0x41, 0x62, 0x84 };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..4) |_| {
        _ = step();
    }
    T(7  == step()); T(0x41 == cpu.r[A]); T(flags(PF));
    T(19 == step()); T(0x63 == cpu.r[A]); T(flags(PF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0xE7 == cpu.r[A]); T(flags(SF|PF)); T(cpu.WZ() == 0x1002);
    T(7  == step()); T(0xA6 == cpu.r[A]); T(flags(SF|PF));
    T(19 == step()); T(0xC4 == cpu.r[A]); T(flags(SF)); T(cpu.WZ() == 0x1001);
    T(19 == step()); T(0x40 == cpu.r[A]); T(flags(0)); T(cpu.WZ() == 0x1002);
    ok();
}

fn @"INC/DEC r"() void {
    start("INC/DEC r");
    const prog = [_]u8 {
        0x3e, 0x00,         // LD A,0x00
        0x06, 0xFF,         // LD B,0xFF
        0x0e, 0x0F,         // LD C,0x0F
        0x16, 0x0E,         // LD D,0x0E
        0x1E, 0x7F,         // LD E,0x7F
        0x26, 0x3E,         // LD H,0x3E
        0x2E, 0x23,         // LD L,0x23
        0x3C,               // INC A
        0x3D,               // DEC A
        0x04,               // INC B
        0x05,               // DEC B
        0x0C,               // INC C
        0x0D,               // DEC C
        0x14,               // INC D
        0x15,               // DEC D
        0xFE, 0x01,         // CP 0x01  // set carry flag (should be preserved)
        0x1C,               // INC E
        0x1D,               // DEC E
        0x24,               // INC H
        0x25,               // DEC H
        0x2C,               // INC L
        0x2D,               // DEC L
    };
    init(0, &prog);
    for (0..7) |_| {
        _ = step();
    }
    T(0x00 == cpu.r[A]);
    T(0xFF == cpu.r[B]);
    T(0x0F == cpu.r[C]);
    T(0x0E == cpu.r[D]);
    T(0x7F == cpu.r[E]);
    T(0x3E == cpu.r[H]);
    T(0x23 == cpu.r[L]);
    T(4==step()); T(0x01 == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(4==step()); T(0x00 == cpu.r[B]); T(flags(ZF|HF));
    T(4==step()); T(0xFF == cpu.r[B]); T(flags(SF|HF|NF));
    T(4==step()); T(0x10 == cpu.r[C]); T(flags(HF));
    T(4==step()); T(0x0F == cpu.r[C]); T(flags(HF|NF));
    T(4==step()); T(0x0F == cpu.r[D]); T(flags(0));
    T(4==step()); T(0x0E == cpu.r[D]); T(flags(NF));
    T(7==step()); T(0x00 == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(4==step()); T(0x80 == cpu.r[E]); T(flags(SF|HF|VF|CF));
    T(4==step()); T(0x7F == cpu.r[E]); T(flags(HF|VF|NF|CF));
    T(4==step()); T(0x3F == cpu.r[H]); T(flags(CF));
    T(4==step()); T(0x3E == cpu.r[H]); T(flags(NF|CF));
    T(4==step()); T(0x24 == cpu.r[L]); T(flags(CF));
    T(4==step()); T(0x23 == cpu.r[L]); T(flags(NF|CF));
    ok();
}

fn @"INC/DEC (HL/IX+d/IY+d)"() void {
    start("INC/DEC (HL/IX+d/IY+d)");
    const prog = [_]u8{
        0x21, 0x00, 0x10,           // LD HL,0x1000
        0xDD, 0x21, 0x00, 0x10,     // LD IX,0x1000
        0xFD, 0x21, 0x03, 0x10,     // LD IY,0x1003
        0x35,                       // DEC (HL)
        0x34,                       // INC (HL)
        0xDD, 0x34, 0x01,           // INC (IX+1)
        0xDD, 0x35, 0x01,           // DEC (IX+1)
        0xFD, 0x34, 0xFF,           // INC (IY-1)
        0xFD, 0x35, 0xFF,           // DEC (IY-1)
    };
    const data = [_]u8{ 0x00, 0x3F, 0x7F };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..3) |_| {
        _ = step();
    }
    T(11==step()); T(0xFF == mem[0x1000]); T(flags(SF|HF|NF));
    T(11==step()); T(0x00 == mem[0x1000]); T(flags(ZF|HF));
    T(23==step()); T(0x40 == mem[0x1001]); T(flags(HF));
    T(23==step()); T(0x3F == mem[0x1001]); T(flags(HF|NF));
    T(23==step()); T(0x80 == mem[0x1002]); T(flags(SF|HF|VF));
    T(23==step()); T(0x7F == mem[0x1002]); T(flags(HF|PF|NF));
    ok();
}

fn @"INC/DEC ss/IX/IY"() void {
    start("INC/DEC ss/IX/IY");
    const prog = [_]u8{
        0x01, 0x00, 0x00,       // LD BC,0x0000
        0x11, 0xFF, 0xFF,       // LD DE,0xffff
        0x21, 0xFF, 0x00,       // LD HL,0x00ff
        0x31, 0x11, 0x11,       // LD SP,0x1111
        0xDD, 0x21, 0xFF, 0x0F, // LD IX,0x0fff
        0xFD, 0x21, 0x34, 0x12, // LD IY,0x1234
        0x0B,                   // DEC BC
        0x03,                   // INC BC
        0x13,                   // INC DE
        0x1B,                   // DEC DE
        0x23,                   // INC HL
        0x2B,                   // DEC HL
        0x33,                   // INC SP
        0x3B,                   // DEC SP
        0xDD, 0x23,             // INC IX
        0xDD, 0x2B,             // DEC IX
        0xFD, 0x23,             // INC IX
        0xFD, 0x2B,             // DEC IX
    };
    init(0, &prog);
    for (0..6) |_| {
        _ = step();
    }
    T(6  == step()); T(0xFFFF == cpu.BC());
    T(6  == step()); T(0x0000 == cpu.BC());
    T(6  == step()); T(0x0000 == cpu.DE());
    T(6  == step()); T(0xFFFF == cpu.DE());
    T(6  == step()); T(0x0100 == cpu.HL());
    T(6  == step()); T(0x00FF == cpu.HL());
    T(6  == step()); T(0x1112 == cpu.SP());
    T(6  == step()); T(0x1111 == cpu.SP());
    T(10 == step()); T(0x1000 == cpu.IX());
    T(10 == step()); T(0x0FFF == cpu.IX());
    T(10 == step()); T(0x1235 == cpu.IY());
    T(10 == step()); T(0x1234 == cpu.IY());
    ok();
}

fn @"RLCA/RLA/RRCA/RRA"() void {
    start("RLCA/RLA/RRCA/RRA");
    const prog = [_]u8{
        0x3E, 0xA0,     // LD A,0xA0
        0x07,           // RLCA
        0x07,           // RLCA
        0x0F,           // RRCA
        0x0F,           // RRCA
        0x17,           // RLA
        0x17,           // RLA
        0x1F,           // RRA
        0x1F,           // RRA
    };
    init(0, &prog);
    cpu.r[F] = 0xFF;
    T(7==step()); T(0xA0 == cpu.r[A]);
    T(4==step()); T(0x41 == cpu.r[A]); T(flags(SF|ZF|VF|CF));
    T(4==step()); T(0x82 == cpu.r[A]); T(flags(SF|ZF|VF));
    T(4==step()); T(0x41 == cpu.r[A]); T(flags(SF|ZF|VF));
    T(4==step()); T(0xA0 == cpu.r[A]); T(flags(SF|ZF|VF|CF));
    T(4==step()); T(0x41 == cpu.r[A]); T(flags(SF|ZF|VF|CF));
    T(4==step()); T(0x83 == cpu.r[A]); T(flags(SF|ZF|VF));
    T(4==step()); T(0x41 == cpu.r[A]); T(flags(SF|ZF|VF|CF));
    T(4==step()); T(0xA0 == cpu.r[A]); T(flags(SF|ZF|VF|CF));
    ok();
}

fn DAA() void {
    start("DAA");
    const prog = [_]u8{
        0x3e, 0x15,         // ld a,0x15
        0x06, 0x27,         // ld b,0x27
        0x80,               // add a,b
        0x27,               // daa
        0x90,               // sub b
        0x27,               // daa
        0x3e, 0x90,         // ld a,0x90
        0x06, 0x15,         // ld b,0x15
        0x80,               // add a,b
        0x27,               // daa
        0x90,               // sub b
        0x27                // daa
    };
    init(0, &prog);
    T(7==step()); T(0x15 == cpu.r[A]);
    T(7==step()); T(0x27 == cpu.r[B]);
    T(4==step()); T(0x3C == cpu.r[A]); T(flags(0));
    T(4==step()); T(0x42 == cpu.r[A]); T(flags(HF|PF));
    T(4==step()); T(0x1B == cpu.r[A]); T(flags(HF|NF));
    T(4==step()); T(0x15 == cpu.r[A]); T(flags(NF));
    T(7==step()); T(0x90 == cpu.r[A]); T(flags(NF));
    T(7==step()); T(0x15 == cpu.r[B]); T(flags(NF));
    T(4==step()); T(0xA5 == cpu.r[A]); T(flags(SF));
    T(4==step()); T(0x05 == cpu.r[A]); T(flags(PF|CF));
    T(4==step()); T(0xF0 == cpu.r[A]); T(flags(SF|NF|CF));
    T(4==step()); T(0x90 == cpu.r[A]); T(flags(SF|PF|NF|CF));
    ok();
}

fn CPL() void {
    start("CPL");
    const prog = [_]u8{
        0x97,               // SUB A
        0x2F,               // CPL
        0x2F,               // CPL
        0xC6, 0xAA,         // ADD A,0xAA
        0x2F,               // CPL
        0x2F,               // CPL
    };
    init(0, &prog);
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(4==step()); T(0xFF == cpu.r[A]); T(flags(ZF|HF|NF));
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|HF|NF));
    T(7==step()); T(0xAA == cpu.r[A]); T(flags(SF));
    T(4==step()); T(0x55 == cpu.r[A]); T(flags(SF|HF|NF));
    T(4==step()); T(0xAA == cpu.r[A]); T(flags(SF|HF|NF));
    ok();
}

fn @"CCF/SCF"() void {
    start("CCF/SCF");
    const prog = [_]u8{
        0x97,           // SUB A
        0x37,           // SCF
        0x3F,           // CCF
        0xD6, 0xCC,     // SUB 0xCC
        0x3F,           // CCF
        0x37,           // SCF
    };
    init(0, &prog);
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|CF));
    T(4==step()); T(0x00 == cpu.r[A]); T(flags(ZF|HF));
    T(7==step()); T(0x34 == cpu.r[A]); T(flags(HF|NF|CF));
    T(4==step()); T(0x34 == cpu.r[A]); T(flags(HF));
    T(4==step()); T(0x34 == cpu.r[A]); T(flags(CF));
    ok();
}

fn HLT() void {
    start("HALT");
    const prog = [_]u8 {
        0x76
    };
    init(0, &prog);
    T(4==step()); T(0x0001 == cpu.pc); T(bits.tst(bus, HALT));
    T(4==step()); T(0x0001 == cpu.pc); T(bits.tst(bus, HALT));
    T(4==step()); T(0x0001 == cpu.pc); T(bits.tst(bus, HALT));
    ok();
}

fn DJNZ() void {
    start("DJNZ");
    const prog = [_]u8{
        0x06, 0x03,         //      LD B,0x03
        0x97,               //      SUB A
        0x3C,               // l0:  INC A
        0x10, 0xFD,         //      DJNZ l0
        0x00,               //      NOP
    };
    init(0x204, &prog);
    T(7  == step()); T(0x03 == cpu.r[B]);
    T(4  == step()); T(0x00 == cpu.r[A]);
    T(4  == step()); T(0x01 == cpu.r[A]);
    T(13 == step()); T(0x02 == cpu.r[B]); T(0x0208 == cpu.pc); T(0x0207 == cpu.WZ());
    T(4  == step()); T(0x02 == cpu.r[A]);
    T(13 == step()); T(0x01 == cpu.r[B]); T(0x0208 == cpu.pc); T(0x0207 == cpu.WZ());
    T(4  == step()); T(0x03 == cpu.r[A]);
    T(8  == step()); T(0x00 == cpu.r[B]); T(0x020B == cpu.pc); T(0x0207 == cpu.WZ());
    ok();
}

pub fn @"JP/JR"() void {
    start("JP/JR");
    const prog = [_]u8{
        0x21, 0x16, 0x02,           //      LD HL,l3
        0xDD, 0x21, 0x19, 0x02,     //      LD IX,l4
        0xFD, 0x21, 0x21, 0x02,     //      LD IY,l5
        0xC3, 0x14, 0x02,           //      JP l0
        0x18, 0x04,                 // l1:  JR l2
        0x18, 0xFC,                 // l0:  JR l1
        0xDD, 0xE9,                 // l3:  JP (IX)
        0xE9,                       // l2:  JP (HL)
        0xFD, 0xE9,                 // l4:  JP (IY)
        0x18, 0x06,                 // l6:  JR l7
        0x00, 0x00, 0x00, 0x00,     //      4x NOP
        0x18, 0xF8,                 // l5:  JR l6
        0x00                        // l7:  NOP
    };
    init(0x204, &prog);
    T(10 == step()); T(0x0216 == cpu.HL());
    T(14 == step()); T(0x0219 == cpu.IX());
    T(14 == step()); T(0x0221 == cpu.IY());
    T(10 == step()); T(0x0215 == cpu.pc); T(0x0214 == cpu.WZ());
    T(12 == step()); T(0x0213 == cpu.pc); T(0x0212 == cpu.WZ());
    T(12 == step()); T(0x0219 == cpu.pc); T(0x0218 == cpu.WZ());
    T(4  == step()); T(0x0217 == cpu.pc); T(0x0218 == cpu.WZ());
    T(8  == step()); T(0x021A == cpu.pc); T(0x0218 == cpu.WZ());
    T(8  == step()); T(0x0222 == cpu.pc); T(0x0218 == cpu.WZ());
    T(12 == step()); T(0x021C == cpu.pc); T(0x021B == cpu.WZ());
    T(12 == step()); T(0x0224 == cpu.pc); T(0x0223 == cpu.WZ());
    ok();
}

fn @"JR cc,d"() void {
    start("JR cc,d");
    const prog = [_]u8{
        0x97,           //      SUB A
        0x20, 0x03,     //      JR NZ,l0
        0x28, 0x01,     //      JR Z,l0
        0x00,           //      NOP
        0xC6, 0x01,     // l0:  ADD A,0x01
        0x28, 0x03,     //      JR Z,l1
        0x20, 0x01,     //      JR NZ,l1
        0x00,           //      NOP
        0xD6, 0x03,     // l1:  SUB 0x03
        0x30, 0x03,     //      JR NC,l2
        0x38, 0x01,     //      JR C,l2
        0x00,           //      NOP
        0x00,           // l2:  NOP
    };
    init(0x204, &prog);
    T(4  == step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(7  == step()); T(0x0208 == cpu.pc);
    T(12 == step()); T(0x020B == cpu.pc); T(0x020A == cpu.WZ());
    T(7  == step()); T(0x01 == cpu.r[A]); T(flags(0));
    T(7  == step()); T(0x020F == cpu.pc);
    T(12 == step()); T(0x0212 == cpu.pc); T(0x0211 == cpu.WZ());
    T(7  == step()); T(0xFE == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(7  == step()); T(0x0216 == cpu.pc);
    T(12 == step()); T(0x0219 == cpu.pc); T(0x0218 == cpu.WZ());
    ok();
}

fn @"CALL/RET"() void {
    start("CALL/RET");
    const prog = [_]u8{
        0xCD, 0x0A, 0x02,       //      CALL l0
        0xCD, 0x0A, 0x02,       //      CALL l0
        0xC9,                   // l0:  RET
    };
    init(0x0204, &prog);
    cpu.setSP(0x0100);
    T(17 == step());
    T(0x020B == cpu.pc); T(0x020A == cpu.WZ()); T(0x00FE == cpu.SP());
    T(0x07 == mem[0x00FE]); T(0x02 == mem[0x00FF]);
    T(10 == step());
    T(0x0208 == cpu.pc); T(0x0207 == cpu.WZ()); T(0x0100 == cpu.SP());
    T(17 == step());
    T(0x020B == cpu.pc); T(0x020A == cpu.WZ()); T(0x00FE == cpu.SP());
    T(0x0A == mem[0x00FE]); T(0x02 == mem[0x00FF]);
    T(10 == step());
    T(0x020B == cpu.pc); T(0x020A == cpu.WZ()); T(0x0100 == cpu.SP());
    ok();
}

fn @"CALL cc/RET cc"() void {
    start("CALL cc/RET cc");
    const prog = [_]u8{
        0x97,               //      SUB A
        0xC4, 0x29, 0x02,   //      CALL NZ,l0
        0xCC, 0x29, 0x02,   //      CALL Z,l0
        0xC6, 0x01,         //      ADD A,0x01
        0xCC, 0x2B, 0x02,   //      CALL Z,l1
        0xC4, 0x2B, 0x02,   //      CALL NZ,l1
        0x07,               //      RLCA
        0xEC, 0x2D, 0x02,   //      CALL PE,l2
        0xE4, 0x2D, 0x02,   //      CALL PO,l2
        0xD6, 0x03,         //      SUB 0x03
        0xF4, 0x2F, 0x02,   //      CALL P,l3
        0xFC, 0x2F, 0x02,   //      CALL M,l3
        0xD4, 0x31, 0x02,   //      CALL NC,l4
        0xDC, 0x31, 0x02,   //      CALL C,l4
        0xC9,               //      RET
        0xC0,               // l0:  RET NZ
        0xC8,               //      RET Z
        0xC8,               // l1:  RET Z
        0xC0,               //      RET NZ
        0xE8,               // l2:  RET PE
        0xE0,               //      RET PO
        0xF0,               // l3:  RET P
        0xF8,               //      RET M
        0xD0,               // l4:  RET NC
        0xD8,               //      RET C
    };
    init(0x204, &prog);
    cpu.setSP(0x100);
    T(4  == step()); T(0x00 == cpu.r[A]);
    T(10 == step()); T(0x0209 == cpu.pc); T(0x0229 == cpu.WZ());
    T(17 == step()); T(0x022A == cpu.pc); T(0x0229 == cpu.WZ());
    T(5  == step()); T(0x022B == cpu.pc); T(0x0229 == cpu.WZ());
    T(11 == step()); T(0x020C == cpu.pc); T(0x020B == cpu.WZ());
    T(7  == step()); T(0x01 == cpu.r[A]);
    T(10 == step()); T(0x0211 == cpu.pc);
    T(17 == step()); T(0x022C == cpu.pc);
    T(5  == step()); T(0x022D == cpu.pc);
    T(11 == step()); T(0x0214 == cpu.pc);
    T(4  == step()); T(0x02 == cpu.r[A]);
    T(10 == step()); T(0x0218 == cpu.pc);
    T(17 == step()); T(0x022E == cpu.pc);
    T(5  == step()); T(0x022F == cpu.pc);
    T(11 == step()); T(0x021B == cpu.pc);
    T(7  == step()); T(0xFF == cpu.r[A]);
    T(10 == step()); T(0x0220 == cpu.pc);
    T(17 == step()); T(0x0230 == cpu.pc);
    T(5  == step()); T(0x0231 == cpu.pc);
    T(11 == step()); T(0x0223 == cpu.pc);
    T(10 == step()); T(0x0226 == cpu.pc);
    T(17 == step()); T(0x0232 == cpu.pc);
    T(5  == step()); T(0x0233 == cpu.pc);
    T(11 == step()); T(0x0229 == cpu.pc);
    ok();
}

fn @"ADD/ADC/SBC HL/IX/IY,dd"() void {
    start("ADD/ADC/SBC HL,dd");
    const prog = [_]u8{
        0x21, 0xFC, 0x00,       // LD HL,0x00FC
        0x01, 0x08, 0x00,       // LD BC,0x0008
        0x11, 0xFF, 0xFF,       // LD DE,0xFFFF
        0x09,                   // ADD HL,BC
        0x19,                   // ADD HL,DE
        0xED, 0x4A,             // ADC HL,BC
        0x29,                   // ADD HL,HL
        0x19,                   // ADD HL,DE
        0xED, 0x42,             // SBC HL,BC
        0xDD, 0x21, 0xFC, 0x00, // LD IX,0x00FC
        0x31, 0x00, 0x10,       // LD SP,0x1000
        0xDD, 0x09,             // ADD IX, BC
        0xDD, 0x19,             // ADD IX, DE
        0xDD, 0x29,             // ADD IX, IX
        0xDD, 0x39,             // ADD IX, SP
        0xFD, 0x21, 0xFF, 0xFF, // LD IY,0xFFFF
        0xFD, 0x09,             // ADD IY,BC
        0xFD, 0x19,             // ADD IY,DE
        0xFD, 0x29,             // ADD IY,IY
        0xFD, 0x39,             // ADD IY,SP
    };
    init(0, &prog);
    T(10==step()); T(0x00FC == cpu.HL());
    T(10==step()); T(0x0008 == cpu.BC());
    T(10==step()); T(0xFFFF == cpu.DE());
    T(11==step()); T(0x0104 == cpu.HL()); T(flags(0)); T(0x00FD == cpu.WZ());
    T(11==step()); T(0x0103 == cpu.HL()); T(flags(HF|CF)); T(0x0105 == cpu.WZ());
    T(15==step()); T(0x010C == cpu.HL()); T(flags(0)); T(0x0104 == cpu.WZ());
    T(11==step()); T(0x0218 == cpu.HL()); T(flags(0)); T(0x010D == cpu.WZ());
    T(11==step()); T(0x0217 == cpu.HL()); T(flags(HF|CF)); T(0x0219 == cpu.WZ());
    T(15==step()); T(0x020E == cpu.HL()); T(flags(NF)); T(0x0218 == cpu.WZ());
    T(14==step()); T(0x00FC == cpu.IX());
    T(10==step()); T(0x1000 == cpu.SP());
    T(15==step()); T(0x0104 == cpu.IX()); T(flags(0)); T(0x00FD == cpu.WZ());
    T(15==step()); T(0x0103 == cpu.IX()); T(flags(HF|CF)); T(0x0105 == cpu.WZ());
    T(15==step()); T(0x0206 == cpu.IX()); T(flags(0)); T(0x0104 == cpu.WZ());
    T(15==step()); T(0x1206 == cpu.IX()); T(flags(0)); T(0x0207 == cpu.WZ());
    T(14==step()); T(0xFFFF == cpu.IY());
    T(15==step()); T(0x0007 == cpu.IY()); T(flags(HF|CF)); T(0x0000 == cpu.WZ());
    T(15==step()); T(0x0006 == cpu.IY()); T(flags(HF|CF)); T(0x0008 == cpu.WZ());
    T(15==step()); T(0x000C == cpu.IY()); T(flags(0)); T(0x0007 == cpu.WZ());
    T(15==step()); T(0x100C == cpu.IY()); T(flags(0)); T(0x000D == cpu.WZ());
    ok();
}

fn IN() void {
    start("IN");
    const prog = [_]u8{
        0x3E, 0x01,         // LD A,0x01
        0xDB, 0x03,         // IN A,(0x03)
        0xDB, 0x04,         // IN A,(0x04)
        0x01, 0x02, 0x02,   // LD BC,0x0202
        0xED, 0x78,         // IN A,(C)
        0x01, 0xFF, 0x05,   // LD BC,0x05FF
        0xED, 0x50,         // IN D,(C)
        0x01, 0x05, 0x05,   // LD BC,0x0505
        0xED, 0x58,         // IN E,(C)
        0x01, 0x06, 0x01,   // LD BC,0x0106
        0xED, 0x60,         // IN H,(C)
        0x01, 0x00, 0x10,   // LD BC,0x0000
        0xED, 0x68,         // IN L,(C)
        0xED, 0x40,         // IN B,(C)
        0xED, 0x48,         // IN C,(c)
    };
    init(0, &prog);
    cpu.r[F] |= CF|HF;
    T(7  == step()); T(0x01 == cpu.r[A]); T(flags(HF|CF));
    T(11 == step()); T(0x06 == cpu.r[A]); T(flags(HF|CF)); T(0x0104 == cpu.WZ());
    T(11 == step()); T(0x08 == cpu.r[A]); T(flags(HF|CF)); T(0x0605 == cpu.WZ());
    T(10 == step()); T(0x0202 == cpu.BC());
    T(12 == step()); T(0x04 == cpu.r[A]); T(flags(CF)); T(0x0203 == cpu.WZ());
    T(10 == step()); T(0x05FF == cpu.BC());
    T(12 == step()); T(0xFE == cpu.r[D]); T(flags(SF|CF)); T(0x0600 == cpu.WZ());
    T(10 == step()); T(0x0505 == cpu.BC());
    T(12 == step()); T(0x0A == cpu.r[E]); T(flags(PF|CF)); T(0x0506 == cpu.WZ());
    T(10 == step()); T(0x0106 == cpu.BC());
    T(12 == step()); T(0x0C == cpu.r[H]); T(flags(PF|CF)); T(0x0107 == cpu.WZ());
    T(10 == step()); T(0x1000 == cpu.BC());
    T(12 == step()); T(0x00 == cpu.r[L]); T(flags(ZF|PF|CF)); T(0x1001 == cpu.WZ());
    T(12 == step()); T(0x00 == cpu.r[B]); T(flags(ZF|PF|CF)); T(0x1001 == cpu.WZ());
    T(12 == step()); T(0x00 == cpu.r[C]); T(flags(ZF|PF|CF)); T(0x0001 == cpu.WZ());
    ok();
}

fn OUT() void {
    start("OUT");
    const prog = [_]u8{
        0x3E, 0x01,         // LD A,0x01
        0xD3, 0x01,         // OUT (0x01),A
        0xD3, 0xFF,         // OUT (0xFF),A
        0x01, 0x34, 0x12,   // LD BC,0x1234
        0x11, 0x78, 0x56,   // LD DE,0x5678
        0x21, 0xCD, 0xAB,   // LD HL,0xABCD
        0xED, 0x79,         // OUT (C),A
        0xED, 0x41,         // OUT (C),B
        0xED, 0x49,         // OUT (C),C
        0xED, 0x51,         // OUT (C),D
        0xED, 0x59,         // OUT (C),E
        0xED, 0x61,         // OUT (C),H
        0xED, 0x69,         // OUT (C),L
        0xED, 0x71,         // OUT (C),0 (undocumented)
    };
    init(0, &prog);
    T(7  == step()); T(0x01 == cpu.r[A]);
    T(11 == step()); T(0x0101 == out_port); T(0x01 == out_byte); T(0x0102 == cpu.WZ());
    T(11 == step()); T(0x01FF == out_port); T(0x01 == out_byte); T(0x0100 == cpu.WZ());
    T(10 == step()); T(0x1234 == cpu.BC());
    T(10 == step()); T(0x5678 == cpu.DE());
    T(10 == step()); T(0xABCD == cpu.HL());
    T(12 == step()); T(0x1234 == out_port); T(0x01 == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0x12 == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0x34 == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0x56 == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0x78 == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0xAB == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0xCD == out_byte); T(0x1235 == cpu.WZ());
    T(12 == step()); T(0x1234 == out_port); T(0x00 == out_byte); T(0x1235 == cpu.WZ());
    ok();
}

fn @"JP cc,nn"() void {
    start("JP cc,nn");
    const prog = [_]u8{
        0x97,               //          SUB A
        0xC2, 0x0C, 0x02,   //          JP NZ,label0
        0xCA, 0x0C, 0x02,   //          JP Z,label0
        0x00,               //          NOP
        0xC6, 0x01,         // label0:  ADD A,0x01
        0xCA, 0x15, 0x02,   //          JP Z,label1
        0xC2, 0x15, 0x02,   //          JP NZ,label1
        0x00,               //          NOP
        0x07,               // label1:  RLCA
        0xEA, 0x1D, 0x02,   //          JP PE,label2
        0xE2, 0x1D, 0x02,   //          JP PO,label2
        0x00,               //          NOP
        0xC6, 0xFD,         // label2:  ADD A,0xFD
        0xF2, 0x26, 0x02,   //          JP P,label3
        0xFA, 0x26, 0x02,   //          JP M,label3
        0x00,               //          NOP
        0xD2, 0x2D, 0x02,   // label3:  JP NC,label4
        0xDA, 0x2D, 0x02,   //          JP C,label4
        0x00,               //          NOP
        0x00,               //          NOP
    };
    init(0x204, &prog);
    T(4  == step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(10 == step()); T(0x0209 == cpu.pc); T(0x020C == cpu.WZ());
    T(10 == step()); T(0x020D == cpu.pc); T(0x020C == cpu.WZ());
    T(7  == step()); T(0x01 == cpu.r[A]); T(flags(0));
    T(10 == step()); T(0x0212 == cpu.pc);
    T(10 == step()); T(0x0216 == cpu.pc);
    T(4  == step()); T(0x02 == cpu.r[A]); T(flags(0));
    T(10 == step()); T(0x021A == cpu.pc);
    T(10 == step()); T(0x021E == cpu.pc);
    T(7  == step()); T(0xFF == cpu.r[A]); T(flags(SF));
    T(10 == step()); T(0x0223 == cpu.pc);
    T(10 == step()); T(0x0227 == cpu.pc);
    T(10 == step()); T(0x022E == cpu.pc);
    ok();
}

fn NEG() void {
    start("NEG");
    const prog = [_]u8{
        0x3E, 0x01,         // LD A,0x01
        0xED, 0x44,         // NEG
        0xC6, 0x01,         // ADD A,0x01
        0xED, 0x4C,         // a duplicate NEG
        0xD6, 0x80,         // SUB A,0x80
        0xED, 0x54,         // another duplicate NEG
        0xC6, 0x40,         // ADD A,0x40
        0xED, 0x5C,         // and another duplicate NEG
    };
    init(0, &prog);
    T(7==step()); T(0x01 == cpu.r[A]);
    T(8==step()); T(0xFF == cpu.r[A]); T(flags(SF|HF|NF|CF));
    T(7==step()); T(0x00 == cpu.r[A]); T(flags(ZF|HF|CF));
    T(8==step()); T(0x00 == cpu.r[A]); T(flags(ZF|NF));
    T(7==step()); T(0x80 == cpu.r[A]); T(flags(SF|PF|NF|CF));
    T(8==step()); T(0x80 == cpu.r[A]); T(flags(SF|PF|NF|CF));
    T(7==step()); T(0xC0 == cpu.r[A]); T(flags(SF));
    T(8==step()); T(0x40 == cpu.r[A]); T(flags(NF|CF));
    ok();
}

fn @"DI/EI/IM"() void {
    start("DI/EI/IM");
    const prog = [_]u8{
        0xF3,           // DI
        0xFB,           // EI
        0x00,           // NOP
        0xF3,           // DI
        0xFB,           // EI
        0x00,           // NOP
        0xED, 0x46,     // IM 0
        0xED, 0x56,     // IM 1
        0xED, 0x5E,     // IM 2
        0xED, 0x46,     // IM 0
    };
    init(0, &prog);
    T(4==step()); T(!cpu.iff2); T(!cpu.iff2);
    T(4==step()); T(cpu.iff1);  T(cpu.iff2);
    T(4==step()); T(cpu.iff1);  T(cpu.iff2);
    T(4==step()); T(!cpu.iff1); T(!cpu.iff2);
    T(4==step()); T(cpu.iff1);  T(cpu.iff2);
    T(4==step()); T(cpu.iff1);  T(cpu.iff2);
    T(8==step()); T(0 == cpu.im);
    T(8==step()); T(1 == cpu.im);
    T(8==step()); T(2 == cpu.im);
    T(8==step()); T(0 == cpu.im);
    ok();
}

fn @"RLD/RRD"() void {
    start("RLD/RRD");
    const prog = [_]u8{
        0x3E, 0x12,         // LD A,0x12
        0x21, 0x00, 0x10,   // LD HL,0x1000
        0x36, 0x34,         // LD (HL),0x34
        0xED, 0x67,         // RRD
        0xED, 0x6F,         // RLD
        0x7E,               // LD A,(HL)
        0x3E, 0xFE,         // LD A,0xFE
        0x36, 0x00,         // LD (HL),0x00
        0xED, 0x6F,         // RLD
        0xED, 0x67,         // RRD
        0x7E,               // LD A,(HL)
        0x3E, 0x01,         // LD A,0x01
        0x36, 0x00,         // LD (HL),0x00
        0xED, 0x6F,         // RLD
        0xED, 0x67,         // RRD
        0x7E
    };
    init(0, &prog);
    T(7  == step()); T(0x12 == cpu.r[A]);
    T(10 == step()); T(0x1000 == cpu.HL());
    T(10 == step()); T(0x34 == mem[0x1000]);
    T(18 == step()); T(0x14 == cpu.r[A]); T(0x23 == mem[0x1000]); T(0x1001 == cpu.WZ());
    T(18 == step()); T(0x12 == cpu.r[A]); T(0x34 == mem[0x1000]); T(0x1001 == cpu.WZ());
    T(7  == step()); T(0x34 == cpu.r[A]);
    T(7  == step()); T(0xFE == cpu.r[A]);
    T(10 == step()); T(0x00 == mem[0x1000]);
    T(18 == step()); T(0xF0 == cpu.r[A]); T(0x0E == mem[0x1000]); T(flags(SF|PF)); T(0x1001 == cpu.WZ());
    T(18 == step()); T(0xFE == cpu.r[A]); T(0x00 == mem[0x1000]); T(flags(SF)); T(0x1001 == cpu.WZ());
    T(7  == step()); T(0x00 == cpu.r[A]);
    T(7  == step()); T(0x01 == cpu.r[A]);
    T(10 == step()); T(0x00 == mem[0x1000]);
    cpu.r[F] |= CF;
    T(18 == step()); T(0x00 == cpu.r[A]); T(0x01 == mem[0x1000]); T(flags(ZF|PF|CF)); T(0x1001 == cpu.WZ());
    T(18 == step()); T(0x01 == cpu.r[A]); T(0x00 == mem[0x1000]); T(flags(CF)); T(0x1001 == cpu.WZ());
    T(7  == step()); T(0x00 == cpu.r[A]);
    ok();
}

fn LDI() void {
    start("LDI");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0x11, 0x00, 0x20,       // LD DE,0x2000
        0x01, 0x03, 0x00,       // LD BC,0x0003
        0xED, 0xA0,             // LDI
        0xED, 0xA0,             // LDI
        0xED, 0xA0,             // LDI
    };
    const data = [_]u8{
        0x01, 0x02, 0x03,
    };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..3) |_| {
        _ = step();
    }
    T(16 == step());
    T(0x1001 == cpu.HL());
    T(0x2001 == cpu.DE());
    T(0x0002 == cpu.BC());
    T(0x01 == mem[0x2000]);
    T(flags(PF));
    T(16 == step());
    T(0x1002 == cpu.HL());
    T(0x2002 == cpu.DE());
    T(0x0001 == cpu.BC());
    T(0x02 == mem[0x2001]);
    T(flags(PF));
    T(16 == step());
    T(0x1003 == cpu.HL());
    T(0x2003 == cpu.DE());
    T(0x0000 == cpu.BC());
    T(0x03 == mem[0x2002]);
    T(flags(0));
    ok();
}

fn LDD() void {
    start("LDD");
    const prog = [_]u8{
        0x21, 0x02, 0x10,       // LD HL,0x1002
        0x11, 0x02, 0x20,       // LD DE,0x2002
        0x01, 0x03, 0x00,       // LD BC,0x0003
        0xED, 0xA8,             // LDD
        0xED, 0xA8,             // LDD
        0xED, 0xA8,             // LDD
    };
    const data = [_]u8{
        0x01, 0x02, 0x03,
    };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..3) |_| {
        _ = step();
    }
    T(16 == step());
    T(0x1001 == cpu.HL());
    T(0x2001 == cpu.DE());
    T(0x0002 == cpu.BC());
    T(0x03 == mem[0x2002]);
    T(flags(PF));
    T(16 == step());
    T(0x1000 == cpu.HL());
    T(0x2000 == cpu.DE());
    T(0x0001 == cpu.BC());
    T(0x02 == mem[0x2001]);
    T(flags(PF));
    T(16 == step());
    T(0x0FFF == cpu.HL());
    T(0x1FFF == cpu.DE());
    T(0x0000 == cpu.BC());
    T(0x01 == mem[0x2000]);
    T(flags(0));
    ok();
}

fn LDIR() void {
    start("LDIR");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // LD HL,0x1000
        0x11, 0x00, 0x20,       // LD DE,0x2000
        0x01, 0x03, 0x00,       // LD BC,0x0003
        0xED, 0xB0,             // LDIR
        0x3E, 0x33,             // LD A,0x33
    };
    const data = [_]u8{
        0x01, 0x02, 0x03,
    };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..3) |_| {
        _ = step();
    }
    T(21 == step());
    T(0x1001 == cpu.HL());
    T(0x2001 == cpu.DE());
    T(0x0002 == cpu.BC());
    T(0x000A == cpu.WZ());
    T(0x000A == cpu.pc);
    T(0x01 == mem[0x2000]);
    T(flags(PF));
    T(21 == step());
    T(0x1002 == cpu.HL());
    T(0x2002 == cpu.DE());
    T(0x0001 == cpu.BC());
    T(0x000A == cpu.WZ());
    T(0x000A == cpu.pc);
    T(0x02 == mem[0x2001]);
    T(flags(PF));
    T(16 == step());
    T(0x1003 == cpu.HL());
    T(0x2003 == cpu.DE());
    T(0x0000 == cpu.BC());
    T(0x000A == cpu.WZ());
    T(0x000C == cpu.pc);
    T(0x02 == mem[0x2001]);
    T(0x03 == mem[0x2002]);
    T(flags(0));
    T(7 == step()); T(0x33 == cpu.r[A]);
    ok();
}

fn LDDR() void {
    start("LDDR");
    const prog = [_]u8{
        0x21, 0x02, 0x10,       // LD HL,0x1002
        0x11, 0x02, 0x20,       // LD DE,0x2002
        0x01, 0x03, 0x00,       // LD BC,0x0003
        0xED, 0xB8,             // LDDR
        0x3E, 0x33,             // LD A,0x33
    };
    const data = [_]u8{
        0x01, 0x02, 0x03,
    };
    init(0, &prog);
    copy(0x1000, &data);
    for (0..3) |_| {
        _ = step();
    }
    T(21 == step());
    T(0x1001 == cpu.HL());
    T(0x2001 == cpu.DE());
    T(0x0002 == cpu.BC());
    T(0x000A == cpu.WZ());
    T(0x000A == cpu.pc);
    T(0x03 == mem[0x2002]);
    T(flags(PF));
    T(21 == step());
    T(0x1000 == cpu.HL());
    T(0x2000 == cpu.DE());
    T(0x0001 == cpu.BC());
    T(0x000A == cpu.WZ());
    T(0x000A == cpu.pc);
    T(0x02 == mem[0x2001]);
    T(flags(PF));
    T(16 == step());
    T(0x0FFF == cpu.HL());
    T(0x1FFF == cpu.DE());
    T(0x0000 == cpu.BC());
    T(0x000A == cpu.WZ());
    T(0x000C == cpu.pc);
    T(0x01 == mem[0x2000]);
    T(flags(0));
    T(7 == step()); T(0x33 == cpu.r[A]);
    ok();
}

fn CPI() void {
    start("CPI");
    const prog = [_]u8{
        0x21, 0x00, 0x10,       // ld hl,0x1000
        0x01, 0x04, 0x00,       // ld bc,0x0004
        0x3e, 0x03,             // ld a,0x03
        0xed, 0xa1,             // cpi
        0xed, 0xa1,             // cpi
        0xed, 0xa1,             // cpi
        0xed, 0xa1,             // cpi
    };
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04
    };
    init(0, &prog);
    copy(0x1000, &data);
    cpu.setWZ(0x1111);
    for (0..3) |_| {
        _ = step();
    }
    T(16 == step());
    T(0x1001 == cpu.HL());
    T(0x0003 == cpu.BC());
    T(0x1112 == cpu.WZ());
    T(flags(PF|NF));
    cpu.r[F] |= CF;
    T(16 == step());
    T(0x1002 == cpu.HL());
    T(0x0002 == cpu.BC());
    T(0x1113 == cpu.WZ());
    T(flags(PF|NF|CF));
    T(16 == step());
    T(0x1003 == cpu.HL());
    T(0x0001 == cpu.BC());
    T(0x1114 == cpu.WZ());
    T(flags(ZF|PF|NF|CF));
    T(16 == step());
    T(0x1004 == cpu.HL());
    T(0x0000 == cpu.BC());
    T(0x1115 == cpu.WZ());
    T(flags(SF|HF|NF|CF));
    ok();
}

fn CPD() void {
    start("CPD");
    const prog = [_]u8{
        0x21, 0x03, 0x10,       // ld hl,0x1004
        0x01, 0x04, 0x00,       // ld bc,0x0004
        0x3e, 0x02,             // ld a,0x03
        0xed, 0xa9,             // cpi
        0xed, 0xa9,             // cpi
        0xed, 0xa9,             // cpi
        0xed, 0xa9,             // cpi
    };
    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04
    };
    init(0, &prog);
    copy(0x1000, &data);
    cpu.setWZ(0x1111);
    for (0..3) |_| {
        _ = step();
    }
    T(16 == step());
    T(0x1002 == cpu.HL());
    T(0x0003 == cpu.BC());
    T(0x1110 == cpu.WZ());
    T(flags(SF|HF|PF|NF));
    cpu.r[F] |= CF;
    T(16 == step());
    T(0x1001 == cpu.HL());
    T(0x0002 == cpu.BC());
    T(0x110F == cpu.WZ());
    T(flags(SF|HF|PF|NF|CF));
    T(16 == step());
    T(0x1000 == cpu.HL());
    T(0x0001 == cpu.BC());
    T(0x110E == cpu.WZ());
    T(flags(ZF|PF|NF|CF));
    T(16 == step());
    T(0x0FFF == cpu.HL());
    T(0x0000 == cpu.BC());
    T(0x110D == cpu.WZ());
    T(flags(NF|CF));
    ok();
}

pub fn main() void {
    NOP();
    @"LD r,s/n"();
    @"LD r,(HL)"();
    @"LD (HL),r"();
    @"LD (IX/IY+d),r"();
    @"LD (HL),n"();
    @"LD (IX/IY+d),n"();
    @"LD A,(BC/DE/nn)"();
    @"LD (BC/DE/nn),A"();
    @"LD dd/IX/IY,nn"();
    @"LD dd/IX/IY,(nn)"();
    @"LD (nn),dd/IX/IY"();
    @"ADD A,r/n"();
    @"ADD A,(HL/IX+d/IY+d)"();
    @"ADC A,r/n"();
    @"ADC A,(HL/IX+d/IY+d)"();
    @"SUB A,r/n"();
    @"SUB A,(HL/IX+d/IY+d)"();
    @"SBC A,r/n"();
    @"SBC A,(HL/IX+d/IY+d)"();
    @"CP A,r/n"();
    @"CP A,(HL/IX+d/IY+d)"();
    @"AND A,r/n"();
    @"AND A,(HL/IX+d/IY+d)"();
    @"XOR A,r/n"();
    @"OR A,r/n"();
    @"OR/XOR A,(HL/IX+d/IY+d)"();
    @"INC/DEC r"();
    @"INC/DEC (HL/IX+d/IY+d)"();
    @"RLCA/RLA/RRCA/RRA"();
    DAA();
    CPL();
    @"CCF/SCF"();
    HLT();
    EX();
    @"PUSH/POP qq/IX/IY"();
    DJNZ();
    @"JP/JR"();
    @"JR cc,d"();
    @"INC/DEC ss/IX/IY"();
    @"RST"();
    @"LD SP,HL/IX/IY"();
    @"CALL/RET"();
    @"CALL cc/RET cc"();
    @"JP cc,nn"();
    @"LD A,R/I"();
    @"LD R/I,A"();
    @"ADD/ADC/SBC HL/IX/IY,dd"();
    NEG();
    @"DI/EI/IM"();
    IN();
    OUT();
    @"RLD/RRD"();
    LDI();
    LDD();
    LDIR();
    LDDR();
    CPI();
    CPD();
}
