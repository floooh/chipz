//------------------------------------------------------------------------------
//  z80timing.zig
//
//  Test Z80 instruction timing.
// zig fmt: off
//------------------------------------------------------------------------------
const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const bits = chips.bits;
const z80 = chips.z80;

const T = assert;
const Bus = u64;
const Z80 = z80.Z80(z80.DefaultPins, Bus);

var cpu: Z80 = undefined;
var bus: Bus = 0;
var mem = [_]u8{0} ** 0x10000;
var io = [_]u8{0} ** 0x10000;

const CTRL = Z80.CTRL;
const M1 = Z80.M1;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RD = Z80.RD;
const WR = Z80.WR;
const RFSH = Z80.RFSH;

fn tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if (bus & MREQ != 0) {
        if (bus & RD != 0) {
            bus = Z80.setData(bus, mem[addr]);
        } else if (bus & WR != 0) {
            mem[addr] = Z80.getData(bus);
        }
    } else if (bus & IORQ != 0) {
        if ((bus & RD) != 0) {
            bus = Z80.setData(bus, io[addr]);
        } else if (bus & WR != 0) {
            io[addr] = Z80.getData(bus);
        }
    }
}

fn start(msg: []const u8) void {
    std.debug.print("=> {s} ... ", .{msg});
}

fn ok() void {
    std.debug.print("ok\n", .{});
}

fn pins_none() u1 {
    return if (bus & CTRL == 0) 1 else 0;
}

fn pins_m1() u1 {
    return if (bus & CTRL == M1 | MREQ | RD) 1 else 0;
}

fn pins_rfsh() u1 {
    return if (bus & CTRL == MREQ | RFSH) 1 else 0;
}

fn pins_mread() u1 {
    return if (bus & CTRL == MREQ | RD) 1 else 0;
}

fn pins_mwrite() u1 {
    return if (bus & CTRL == MREQ | WR) 1 else 0;
}

fn pins_ioread() u1 {
    return if (bus & CTRL == IORQ | RD) 1 else 0;
}

fn pins_iowrite() u1 {
    return if (bus & CTRL == IORQ | WR) 1 else 0;
}

fn none_cycle(num: usize) bool {
    var success: u1 = 1;
    for (0..num) |_| {
        tick(); success &= pins_none();
    }
    return success == 1;
}

fn m1_cycle() bool {
    var success: u1 = 1;
    tick(); success = pins_m1();
    tick(); success = pins_none();
    tick(); success = pins_rfsh();
    tick(); success = pins_none();
    return success == 1;
}

fn mread_cycle() bool {
    var success: u1 = 1;
    tick(); success &= pins_none();
    tick(); success &= pins_mread();
    tick(); success &= pins_none();
    return success == 1;
}

fn mwrite_cycle() bool {
    var success: u1 = 1;
    tick(); success &= pins_none();
    tick(); success &= pins_mwrite();
    tick(); success &= pins_none();
    return success == 1;
}

fn ioread_cycle() bool {
    var success: u1 = 1;
    tick(); success &= pins_none();
    tick(); success &= pins_none();
    tick(); success &= pins_ioread();
    tick(); success &= pins_none();
    return success == 1;
}

fn iowrite_cycle() bool {
    var success: u1 = 1;
    tick(); success &= pins_none();
    tick(); success &= pins_iowrite();
    tick(); success &= pins_none();
    tick(); success &= pins_none();
    return success == 1;
}

fn finish() bool {
    // run 2x NOP
    var success: u1 = 1;
    for (0..2) |_| {
        tick(); success &= pins_m1();
        tick(); success &= pins_none();
        tick(); success &= pins_rfsh();
        tick(); success &= pins_none();
    }
    return success == 1;
}

fn copy(start_addr: u16, bytes: []const u8) void {
    std.mem.copyForwards(u8, mem[start_addr..], bytes);
}

fn init(bytes: []const u8) void {
    mem = std.mem.zeroes(@TypeOf(mem));
    bus = 0;
    cpu = Z80{};
    copy(0, bytes);
    cpu.prefetch(0);
}

fn @"LD r,(HL) / LD (HL),r"() void {
    start("LD r,(HL) / LD (HL),r");
    const prog = [_]u8{
        0x7E,       // LD A,(HL)
        0x70,       // LD (HL),B
        0x00, 0x00, // 2x NOP
    };
    init(&prog);

    // LD A,(HL)
    T(m1_cycle());
    T(mread_cycle());

    // LD (HL),B
    T(m1_cycle());
    T(mwrite_cycle());
    T(finish());

    ok();
}

fn @"ALU (HL)"() void {
    start("ALU (HL)");
    const prog = [_]u8{
        0x86,               // ADD A,(HL)
        0xDD, 0x96, 0x01,   // SUB (IX+1)
        0xFD, 0xA6, 0xFF,   // AND (IY-1)
        0x00, 0x00,
    };
    init(&prog);

    // ADD A,(HL)
    T(m1_cycle());
    T(mread_cycle());

    // SUB (IX+1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));
    T(mread_cycle());

    // AND (IY-1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));
    T(mread_cycle());

    T(finish());

    ok();
}

fn NOP() void {
    start("NOP");
    const prog = [_]u8{ 0, 0, 0, 0 };
    init(&prog);

    // 2x NOP
    T(m1_cycle());
    T(m1_cycle());

    ok();
}

fn @"LD r,n"() void {
    start("LD r,n");

    const prog = [_]u8{
        0x3E, 0x11,     // LD A,11h
        0x06, 0x22,     // LD B,22h
        0x00, 0x00,     // NOP, NOP
    };
    init(&prog);

    // LD A,11h
    T(m1_cycle());
    T(mread_cycle());

    // LD B,22h
    T(m1_cycle());
    T(mread_cycle());
    T(finish());

    ok();
}

fn @"LD rp,nn"() void {
    start("LD rp,nn");

    const prog = [_]u8{
        0x21, 0x11, 0x11,   // LD HL,1111h
        0x11, 0x22, 0x22,   // LD DE,2222h
        0xDD, 0x21, 0x33, 0x33, // LD IX,3333h
        0x00, 0x00,
    };
    init(&prog);

    // LD HL,1111h
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LD DE,2222h
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LD IX,3333h
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn DJNZ() void {
    start("DJNZ");

    const prog = [_]u8{
        0xAF,           //       XOR A
        0x06, 0x03,     //       LD B,3
        0x3C,           // loop: INC a
        0x10, 0xFD,     //       DJNZ loop
        0x00, 0x00
    };
    init(&prog);

    // XOR A
    T(m1_cycle());
    // LD B,3
    T(m1_cycle());
    T(mread_cycle());
    // INC A
    T(m1_cycle());
    // DJNZ (jump taken)
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(none_cycle(5));
    // INC A
    T(m1_cycle());
    // DJNZ (jump taken)
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(none_cycle(5));
    // INC A
    T(m1_cycle());
    // DJNZ (fallthrough)
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());

    T(finish());

    ok();
}

fn JR() void {
    start("JR");

    const prog = [_]u8{
        0x18, 0x01,     //        JR label
        0x00,           //        NOP
        0x3E, 0x33,     // label: LD A,33h
        0x00, 0x00
    };
    init(&prog);

    // JR label
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));

    // LD A,33h
    T(m1_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"JR cc"() void {
    start("JR cc");

    const prog = [_]u8{
        0xAF,           //        XOR A
        0x20, 0x03,     //        JR NZ, label
        0x28, 0x01,     //        JR Z, label
        0x00,           //        NOP
        0x3E, 0x33,     // label: LD A,33h
        0x00, 0x00
    };
    init(&prog);

    // XOR A
    T(m1_cycle());
    // JR NZ (not taken)
    T(m1_cycle());
    T(mread_cycle());
    // JR Z (taken)
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));
    // LD A,33h
    T(m1_cycle());
    T(mread_cycle());
    T(finish());

    ok();
}

fn RST() void {
    start("RST");

    const prog = [_]u8{
        0xCF,       // RST 8
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x3E, 0x33, // LD A,33h
        0x00, 0x00,
    };
    init(&prog);

    // RST 8
    T(m1_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());

    // LD A,33h
    T(m1_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"LD (HL),n"() void {
    start("LD (HL),n");

    const prog = [_]u8{
        0x36, 0x11,             // LD (HL),11h
        0xDD, 0x36, 0x01, 0x11, // LD (IX+1),11h
        0x00, 0x00,             // NOP NOP
    };
    init(&prog);

    // LD (HL),n
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());

    // LD (IX+1),11h
    T(m1_cycle());      // DD prefix
    T(m1_cycle());      // 36 opcode
    T(mread_cycle());   // load d-offset
    T(mread_cycle());   // load n
    T(none_cycle(2));   // 2 filler ticks
    T(mwrite_cycle());  // write result

    T(finish());

    ok();
}

fn @"LD r,(IX) / LD (IY),r"() void{
    start("LD r,(IX) / LD (IY),r");

    const prog = [_]u8{
        0xDD, 0x7E, 0x01,   // LD A,(IX+1)
        0xFD, 0x70, 0x01,   // LD (IY+1),B
        0x00, 0x00,         // NOP NOP
    };
    init(&prog);

    // LD A,(IX+1)
    T(m1_cycle());      // DD prefix
    T(m1_cycle());      // 7E opcode
    T(mread_cycle());   // load d-offset
    T(none_cycle(5));   // filler ticks
    T(mread_cycle());   // load (IX+1)

    // LD (IY+1),B
    T(m1_cycle());      // FD prefix
    T(m1_cycle());      // 70 opcode
    T(mread_cycle());   // load d-offset
    T(none_cycle(5));   // filler ticks
    T(mwrite_cycle());  // write (IY+1)

    T(finish());

    ok();
}

fn @"LD A,(BC/DE/nn)"() void{
    start("LD A,(BC/DE/nn)");

    const prog = [_]u8{
        0x0A,   // LD A,(BC)
        0x1A,   // LD A,(DE)
        0x3A, 0x00, 0x10,   // LD A,(1000h)
        0x00, 0x00
    };
    init(&prog);

    // LD A,(BC)
    T(m1_cycle());
    T(mread_cycle());

    // LD A,(DE)
    T(m1_cycle());
    T(mread_cycle());

    // LD A,(nn)
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"LD (BC/DE/nn),A"() void {
    start("LD (BC/DE/nn),A");

    const prog = [_]u8{
        0x02,       // LD (BC),A
        0x12,       // LD (DE),A
        0x32, 0x00, 0x10,   // LD (1000h),A
    };
    init(&prog);

    // LD (BC),A
    T(m1_cycle());
    T(mwrite_cycle());

    // LD (DE),A
    T(m1_cycle());
    T(mwrite_cycle());

    // LD (nn),A
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mwrite_cycle());

    ok();
}

fn @"LD (HL),nn"() void {
    start("LD (HL),nn");

    const prog = [_]u8{
        0x22, 0x11, 0x11,       // LD (1111h),HL
        0xDD, 0x22, 0x22, 0x22, // LD (2222h),IX
        0x00, 0x00,
    };
    init(&prog);

    // LD (1111h),HL
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(mwrite_cycle());

    // LD (2222h),IX
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(mwrite_cycle());

    T(finish());

    ok();
}

fn @"LD (nn),HL"() void {
    start("LD (nn),HL");

    const prog = [_]u8{
        0x2A, 0x11, 0x11,           // LD (1111h),HL
        0xDD, 0x2A, 0x22, 0x22,     // LD (2222h),IX
        0x00, 0x00,
    };
    init(&prog);

    // LD (nn),HL
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LD (nn),IX
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"INC/DEC rp"() void {
    start("INC/DEC rp");

    const prog = [_]u8{
        0x23,       // INC HL
        0x1B,       // DEC DE
        0xDD, 0x23, // INC IX
        0xFD, 0x1B, // DEC IY
        0x00, 0x00,
    };
    init(&prog);

    // INC HL
    T(m1_cycle());
    T(none_cycle(2));
    // DEC DE
    T(m1_cycle());
    T(none_cycle(2));
    // INC IX
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(2));
    // DEC IY
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(2));

    T(finish());

    ok();
}

fn @"INC/DEC_(HL)"() void {
    start("INC/DEC (HL)");

    const prog = [_]u8{
        0x34,               // INC (HL)
        0xDD, 0x35, 0x01,   // DEC (IX+1)
        0xFD, 0x34, 0x02,   // INC (IY+2)
        0x00, 0x00,
    };
    init(&prog);

    // INC (HL)
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());

    // DEC (IX+1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());

    // INC (IY+2)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());

    T(finish());

    ok();
}

fn @"CALL/RET"() void {
    start("CALL/RET");

    const prog = [_]u8{
        0xCD, 0x08, 0x00,   //      CALL l0
        0xCD, 0x08, 0x00,   //      CALL l1
        0x00, 0x00,         //      NOP NOP
        0xC9                // l0:  RET
    };
    init(&prog);

    // CALL l0
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());

    // RET
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // CALL l0
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());

    // RET
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"PUSH/POP"() void {
    start("PUSH/POP");

    const prog = [_]u8{
        0xE5,           // PUSH HL
        0xDD, 0xE5,     // PUSH IX
        0xE1,           // POP HL
        0xDD, 0xE1,     // POP IX
        0x00, 0x00,
    };
    init(&prog);

    // PUSH HL
    T(m1_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());

    // PUSH IX
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());

    // POP HL
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // POP IX
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"LD SP,HL"() void {
    start("LD SP,HL");

    const prog = [_]u8{
        0xF9,       // LD SP,HL
        0xDD, 0xF9, // LD SP,IX
        0x00, 0x00,
    };
    init(&prog);

    // LD SP,HL
    T(m1_cycle());
    T(none_cycle(2));

    // LD SP,IX
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(2));

    T(finish());

    ok();
}

fn @"JP HL"() void {
    start("JP HL");

    const prog = [_]u8{
        0x21, 0x05, 0x00,   //      LD HL,l0
        0xE9,               //      JP HL
        0x00,               //      NOP
        0x3E, 0x33,         // l0:  LD A,33h
        0x00, 0x00,
    };
    init(&prog);

    // LD HL,l0
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // JP HL
    T(m1_cycle());

    // LD A,33h
    T(m1_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"EX (SP),HL"() void {
    start("EX (SP),HL");

    const prog = [_]u8{
        0xE3,           // EX (SP),HL
        0xDD, 0xE3,     // EX (SP),IX
        0x00, 0x00,
    };
    init(&prog);

    // EX (SP),HL
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());
    T(none_cycle(2));

    // EX (SP),IX
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());
    T(none_cycle(2));

    T(finish());

    ok();
}

fn @"JP nn"() void{
    start("JP nn");

    const prog = [_]u8{
        0xC3, 0x04, 0x00,   // JP l0
        0x00,               // NOP
        0x3E, 0x33,         // LD A,33h
        0x00, 0x00,
    };
    init(&prog);

    // JP l0
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LD A,33h
    T(m1_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"CALL cc / RET cc"() void {
    start("CALL cc / RET cc");

    const prog = [_]u8{
        0x97,               //      SUB A
        0xC4, 0x09, 0x00,   //      CALL NZ,l0
        0xCC, 0x09, 0x00,   //      CALL Z,l0
        0x00,               //      NOP
        0x00,
        0xC0,               // l0:  RET NZ
        0xC8,               //      RET Z
        0x3E, 0x33,         //      LD A,33h
    };
    init(&prog);

    // SUB A
    T(m1_cycle());

    // CALL NZ, l0 (not taken)
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // CALL Z, l0 (taken)
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());
    T(mwrite_cycle());

    // RET NZ (not taken)
    T(m1_cycle());
    T(none_cycle(1));

    // RET Z (taken)
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"JP cc,nn"() void {
    start("JP cc,nn");

    const prog = [_]u8{
        0x97,               // SUB A
        0xC2, 0x08, 0x00,   // JP NZ, l0
        0xCA, 0x08, 0x00,   // JP Z, l0
        0x00,
        0x3E, 0x33,         // LD A,33h
        0x00, 0x00
    };
    init(&prog);

    // SUB A
    T(m1_cycle());

    // JP NZ, l0 (not taken)
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // JP Z, l0 (taken)
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LD A,33h
    T(m1_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"IN/OUT (n),A"() void {
    start("IN/OUT (n),A");

    const prog = [_]u8{
        0xD3, 0x33,         // OUT (33h),A
        0xDB, 0x44,         // IN A,(44h)
        0x00, 0x00,
    };
    init(&prog);

    // OUT (33h),A
    T(m1_cycle());
    T(mread_cycle());
    T(iowrite_cycle());

    // IN A,(44h)
    T(m1_cycle());
    T(mread_cycle());
    T(ioread_cycle());

    T(finish());

    ok();
}

fn @"IN/OUT (C)"() void {
    start("IN/OUT (C)");

    const prog = [_]u8{
        0xED, 0x78,         // IN A,(C)
        0xED, 0x70,         // IN (C)
        0xED, 0x79,         // OUT (C),A
        0xED, 0x71,         // OUT (C),0
        0x00, 0x00,
    };
    init(&prog);

    // IN A,(C)
    T(m1_cycle());
    T(m1_cycle());
    T(ioread_cycle());

    // IN (C)
    T(m1_cycle());
    T(m1_cycle());
    T(ioread_cycle());

    // OUT (C),A
    T(m1_cycle());
    T(m1_cycle());
    T(iowrite_cycle());

    // OUT (C),0
    T(m1_cycle());
    T(m1_cycle());
    T(iowrite_cycle());

    T(finish());

    ok();
}

fn @"LD (nn),rp"() void{
    start("LD (nn),rp");

    const prog = [_]u8{
        0xED, 0x43, 0x11, 0x11,     // LD (1111h),BC
        0xED, 0x4B, 0x22, 0x22,     // LD BC,(2222h)
        0x00, 0x00,
    };
    init(&prog);

    // LD (1111h),BC
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(mwrite_cycle());

    // LD BC,(2222h)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(mread_cycle());

    T(finish());

    ok();
}

fn @"RRD/RLD"() void {
    start("RRD/RLD");

    const prog = [_]u8{
        0xED, 0x67,     // RRD
        0xED, 0x6F,     // RLD
        0x00, 0x00,
    };
    init(&prog);

    // RRD
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(4));
    T(mwrite_cycle());

    // RLD
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(4));
    T(mwrite_cycle());

    T(finish());

    ok();
}

fn @"LDI/LDD/CPI/CPD"() void {
    start("LDI/LDD/CPI/CPD");

    const prog = [_]u8{
        0xED, 0xA0,     // LDI
        0xED, 0xA8,     // LDD
        0xED, 0xA1,     // CPI
        0xED, 0xA9,     // CPD
        0x00, 0x00,
    };
    init(&prog);

    // LDI
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(none_cycle(2));

    // LDD
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(none_cycle(2));

    // CPI
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));

    // CPD
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));

    T(finish());

    ok();
}

fn @"INI/IND/OUTI/OUTD"() void {
    start("INI/IND/OUTI/OUTD");

    const prog = [_]u8{
        0xED, 0xA2,     // INI
        0xED, 0xAA,     // IND
        0xED, 0xA3,     // OUTI
        0xED, 0xAB,     // OUTD
        0x00, 0x00,
    };
    init(&prog);

    // INI
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(ioread_cycle());
    T(mwrite_cycle());

    // IND
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(ioread_cycle());
    T(mwrite_cycle());

    // OUTI
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(iowrite_cycle());

    // OUTD
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(iowrite_cycle());

    T(finish());

    ok();
}

fn @"LDIR/LDDR"() void {
    start("LDIR/LDDR");

    const prog = [_]u8{
        0x01, 0x02, 0x00,   // LD BC,2
        0xED, 0xB0,         // LDIR
        0x01, 0x02, 0x00,   // LD BC,2
        0xED, 0xB8,         // LDDR
        0x00, 0x00,
    };
    init(&prog);

    // LD BC,2
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LDIR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(none_cycle(7));

    // LDIR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(none_cycle(2));

    // LD BC,2
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // LDDR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(none_cycle(7));

    // LDDR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mwrite_cycle());
    T(none_cycle(2));

    T(finish());

    ok();
}

fn @"CPIR/CPDR"() void {
    start("CPIR/CPDR");

    const prog = [_]u8{
        0x01, 0x02, 0x00,   // LD BC,2
        0xED, 0xB1,         // CPIR
        0x01, 0x02, 0x00,   // LD BC,2
        0xED, 0xB9,         // CPDR
        0x00, 0x00,
    };
    init(&prog);

    // LD BC,2
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // CPIR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(10));

    // CPIR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));

    // LD BC,2
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());

    // CPDR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(10));

    // CPDR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(5));

    T(finish());

    ok();
}

fn @"INIR/INDR"() void {
    start("INIR/INDR");

    const prog = [_]u8{
        0x06, 0x02,         // LD B,2
        0xED, 0xB2,         // INIR
        0x06, 0x02,         // LD B,2
        0xED, 0xBA,         // INDR
        0x00, 0x00,
    };
    init(&prog);

    // LD BC,2
    T(m1_cycle());
    T(mread_cycle());

    // INIR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(ioread_cycle());
    T(mwrite_cycle());
    T(none_cycle(5));

    // INIR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(ioread_cycle());
    T(mwrite_cycle());

    // LD BC,2
    T(m1_cycle());
    T(mread_cycle());

    // INDR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(ioread_cycle());
    T(mwrite_cycle());
    T(none_cycle(5));

    // INDR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(ioread_cycle());
    T(mwrite_cycle());

    T(finish());

    ok();
}

fn @"OTIR_OTDR"() void {
    start("OTIR/OTDR");

    const prog = [_]u8{
        0x06, 0x02,     // LD B,2
        0xED, 0xB3,     // OTIR
        0x06, 0x02,     // LD B,2
        0xED, 0xBB,     // OTDR
        0x00, 0x00,
    };
    init(&prog);

    // LD B,2
    T(m1_cycle());
    T(mread_cycle());

    // OTIR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(iowrite_cycle());
    T(none_cycle(5));

    // OTIR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(iowrite_cycle());

    // LD B,2
    T(m1_cycle());
    T(mread_cycle());

    // OTDR (1)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(iowrite_cycle());
    T(none_cycle(5));

    // OTDR (2)
    T(m1_cycle());
    T(m1_cycle());
    T(none_cycle(1));
    T(mread_cycle());
    T(iowrite_cycle());

    T(finish());

    ok();
}

fn @"SET/BIT n,r"() void {
    start("SET/BIT n,r");

    const prog = [_]u8{
        0xCB, 0xC7,     // SET 0,A
        0xCB, 0x48,     // BIT 1,B
        0x00, 0x00,
    };
    init(&prog);

    // SET 0,A
    T(m1_cycle());
    T(m1_cycle());

    // BIT 1,B
    T(m1_cycle());
    T(m1_cycle());

    T(finish());

    ok();
}

fn @"SET/BIT n,(HL)"() void {
    start("SET/BIT (HL)");

    const prog = [_]u8{
        0xCB, 0xC6,                 // SET 0,(HL)
        0xDD, 0xCB, 0x01, 0xC6,     // SET 0,(IX+1)
        0xCB, 0x46,                 // BIT 0,(HL)
        0xDD, 0xCB, 0x01, 0x46,     // BIT 0,(IX+1)
        0x00, 0x00,
    };
    init(&prog);

    // SET 0,(HL)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());

    // SET 0,(IX+1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(2));
    T(mread_cycle());
    T(none_cycle(1));
    T(mwrite_cycle());

    // BIT 0,(HL)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(none_cycle(1));

    // BIT 0,(IX+1)
    T(m1_cycle());
    T(m1_cycle());
    T(mread_cycle());
    T(mread_cycle());
    T(none_cycle(2));
    T(mread_cycle());
    T(none_cycle(1));

    T(finish());

    ok();
}

pub fn main() void {
    @"LD r,(HL) / LD (HL),r"();
    @"ALU (HL)"();
    NOP();
    @"LD r,n"();
    @"LD rp,nn"();
    DJNZ();
    JR();
    @"JR cc"();
    RST();
    @"LD (HL),n"();
    @"LD r,(IX) / LD (IY),r"();
    @"LD A,(BC/DE/nn)"();
    @"LD (BC/DE/nn),A"();
    @"LD (HL),nn"();
    @"LD (nn),HL"();
    @"INC/DEC rp"();
    @"INC/DEC_(HL)"();
    @"CALL/RET"();
    @"PUSH/POP"();
    @"LD SP,HL"();
    @"JP HL"();
    @"EX (SP),HL"();
    @"JP nn"();
    @"CALL cc / RET cc"();
    @"JP cc,nn"();
    @"IN/OUT (n),A"();
    @"IN/OUT (C)"();
    @"LD (nn),rp"();
    @"RRD/RLD"();
    @"LDI/LDD/CPI/CPD"();
    @"INI/IND/OUTI/OUTD"();
    @"LDIR/LDDR"();
    @"CPIR/CPDR"();
    @"INIR/INDR"();
    @"OTIR_OTDR"();
    @"SET/BIT n,r"();
    @"SET/BIT n,(HL)"();
}