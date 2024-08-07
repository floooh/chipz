//------------------------------------------------------------------------------
//  z80int.zig
//
//  Test Z80 interrupt timing.
//
// zig fmt: off
//------------------------------------------------------------------------------
const std = @import("std");
const assert = std.debug.assert;
const chipz = @import("chipz");
const pinsAll = chipz.common.bitutils.pinsAll;
const z80 = chipz.chips.z80;

const T = assert;
const Bus = u64;
const Z80 = z80.Type(.{ .pins = z80.DefaultPins, .bus = Bus });

var cpu: Z80 = undefined;
var bus: Bus = 0;
var mem = [_]u8{0} ** 0x10000;

const CTRL = Z80.CTRL;
const M1 = Z80.M1;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RFSH = Z80.RFSH;
const RD = Z80.RD;
const WR = Z80.WR;
const INT = Z80.INT;
const NMI = Z80.NMI;
const RETI = Z80.RETI;

const A = Z80.A;
const E = Z80.E;
const D = Z80.D;
const WZL = Z80.WZL;
const WZH = Z80.WZH;

fn tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if ((bus & MREQ) != 0) {
        if ((bus & RD) != 0) {
            bus = Z80.setData(bus, mem[addr]);
        } else if ((bus & WR) != 0) {
            mem[addr] = Z80.getData(bus);
        }
    } else if (pinsAll(bus, M1 | IORQ)) {
        // put 0xE0 on data bus (in IM2 mode this is the low byte of the
        // interrupt vector, and in IM1 mode it is ignored)
        bus = Z80.setData(bus, 0xE0);
    }
}

// special IM0 tick function, puts the RST 38h opcode on the data bus
fn im0_tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if ((bus & MREQ) != 0) {
        if ((bus & RD) != 0) {
            bus = Z80.setData(bus, mem[addr]);
        } else if ((bus & WR) != 0) {
            mem[addr] = Z80.getData(bus);
        }
    } else if (pinsAll(bus, M1 | IORQ)) {
        bus = Z80.setData(bus, 0xFF);
    }
}

fn copy(start_addr: u16, bytes: []const u8) void {
    std.mem.copyForwards(u8, mem[start_addr..], bytes);
}

fn init(start_addr: u16, bytes: []const u8) void {
    mem = std.mem.zeroes(@TypeOf(mem));
    bus = 0;
    cpu = Z80.init();
    copy(start_addr, bytes);
    cpu.prefetch(start_addr);
}

fn pins_none() bool {
    return (bus & CTRL) == 0;
}

fn pins_m1() bool {
    return (bus & CTRL) == M1 | MREQ | RD;
}

fn pins_rfsh() bool {
    return (bus & CTRL) == MREQ | RFSH;
}

fn pins_mread() bool {
    return (bus & CTRL) == MREQ | RD;
}

fn pins_mwrite() bool {
    return (bus & CTRL) == MREQ | WR;
}

fn pins_m1iorq() bool {
    return (bus & CTRL) == M1 | IORQ;
}

fn skip(num_ticks: usize) void {
    for (0..num_ticks) |_| {
        tick();
    }
}

fn iff1() bool {
    return 0 != cpu.iff1;
}

fn iff2() bool {
    return 0 != cpu.iff2;
}

fn int() bool {
    return 0 != cpu.int;
}

fn nmi() bool {
    return 0 != cpu.nmi;
}

fn start(msg: []const u8) void {
    std.debug.print("=> {s} ... ", .{msg});
}

fn ok() void {
    std.debug.print("ok\n", .{});
}

fn NMI_regular() void {
    start("NMI regular");
    const prog = [_]u8{
        0xFB, //       EI
        0x21, 0x11, 0x11, // loop: LD HL, 1111h
        0x11, 0x22, 0x22, //       LD DE, 2222h
        0xC3, 0x01, 0x00, //       JP loop
    };
    const isr = [_]u8{
        0x3E, 0x33, //       LD A,33h
        0xED, 0x45, //       RETN
    };
    init(0x0000, &prog);
    copy(0x0066, &isr);
    cpu.setSP(0x0100);

    // EI
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none()); T(!iff1()); T(!iff2());

    // LD HL,1111h
    tick(); T(pins_m1()); T(iff1()); T(iff2());
    tick(); T(pins_none());
    tick(); T(pins_rfsh()); T(!nmi() and !int());
    tick(); T(pins_none());
    tick(); T(pins_none()); bus |= NMI;
    tick(); T(pins_mread()); bus &= ~NMI;
    tick(); T(pins_none()); T(nmi());
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());

    // the NMI should kick in here, starting with a regular refresh cycle
    tick(); T(pins_m1()); T(cpu.pc == 4);
    tick(); T(pins_none()); T(cpu.pc == 4); T(!iff1());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // extra tick
    tick(); T(pins_none());
    // mwrite
    tick(); T(pins_none()); T(cpu.pc == 4);
    tick(); T(pins_mwrite()); T(cpu.SP() == 0x00FF); T(mem[0x00FF] == 0);
    tick(); T(pins_none());
    // mwrite
    tick(); T(pins_none());
    tick(); T(pins_mwrite()); T(cpu.SP() == 0x00FE); T(mem[0x00FE] == 4);
    tick(); T(pins_none());

    // first overlapped tick of interrupt service routine
    tick(); T(pins_m1()); T(cpu.pc == 0x67);
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());

    // RETN
    // ED prefix
    tick(); T(pins_m1()); T(cpu.r[A] == 0x33);
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // opcode
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread());  T(cpu.SP() == 0x00FF);
    tick(); T(pins_none()); T(cpu.r[WZL] == 0x04); T(0 == (bus & RETI));
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread());  T(cpu.SP() == 0x0100);
    tick(); T(pins_none()); T(!iff1()); T(cpu.r[WZH] == 0x00); T(cpu.pc == 0x0004);

    // continue at LD DE,2222h
    tick(); T(pins_m1()); T(iff1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none()); T(cpu.r[E] == 0x22);
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none()); T(cpu.r[D] == 0x22);

    ok();
}

// test whether a 'last minute' NMI is detected
fn NMI_before_after() void {
    start("NMI before/after");
    const prog = [_]u8{
        0xFB,               //      EI
        0x00, 0x00, 0x00,   // l0:  NOPS
        0x18, 0xFB,         //      JR loop
    };
    const isr = [_]u8{
        0x3E, 0x33,         // LD A,33h
        0xED, 0x45,         // RETN
    };
    init(0x0000, &prog);
    copy(0x0066, &isr);
    cpu.setSP(0x0100);

    // EI
    skip(4);
    // NOP
    tick(); T(pins_m1()); T(iff1());
    tick();
    tick(); T(pins_rfsh());
    bus |= NMI;
    tick();
    bus &= ~NMI;
    // NOP
    tick(); T(pins_m1());
    tick(); T(!iff1()); // OK, interrupt was detected

    // same thing one tick later, interrupt delayed to next opportunity
    init(0x0000, &prog);
    copy(0x0066, &isr);
    cpu.setSP(0x1000);
    // EI
    skip(4);
    // NOP
    tick(); T(pins_m1()); T(iff1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // NOP
    bus |= NMI;
    tick(); T(pins_m1());
    bus &= ~NMI;
    tick(); T(pins_none()); T(iff1()); // IFF1 true here means the interrupt didn't trigger
    tick(); T(pins_rfsh());
    tick(); T(pins_none());

    // interrupt should trigger here instead
    tick(); T(pins_m1());
    tick(); T(!iff1()); // OK, interrupt was detected

    ok();
}

// test that a raised NMI doesn't retrigger
fn NMI_no_retrigger() void {
    start("NMI_no_retrigger");
    const prog = [_]u8{
        0xFB,               //      EI
        0x00, 0x00, 0x00,   // l0:  NOPS
        0x18, 0xFB,         //      JR loop
    };
    const isr = [_]u8{
        0x3E, 0x33,         // LD A,33h
        0xED, 0x45,         // RETN
    };
    init(0x0000, &prog);
    copy(0x0066, &isr);
    cpu.setSP(0x0100);

    // EI
    skip(4);
    // NOP
    tick(); T(pins_m1()); T(iff1());
    tick();
    tick(); T(pins_rfsh());
    bus|= NMI;    // NOTE: NMI pin stays active
    tick();
    // NOP
    tick(); T(pins_m1());
    tick(); T(!iff1()); // OK, interrupt was detected

    // run until end of interrupt service routine
    while (!iff1()) {
        tick();
    }
    // now run a few hundred ticks, NMI should not trigger again
    for (0..300) |_| {
        tick(); T(iff1());
    }
    ok();
}

// test whether NMI triggers during EI sequences (it should)
fn NMI_during_EI() void {
    start("NMI_during_EI");
    const prog = [_]u8{
        0xFB, 0xFB, 0xFB, 0xFB,     // EI...
    };
    const isr = [_]u8{
        0x3E, 0x33,         // LD A,33h
        0xED, 0x45,         // RETN
    };
    init(0x0000, &prog);
    copy(0x0066, &isr);
    cpu.setSP(0x0100);

    // EI
    skip(4);
    // EI
    tick(); T(pins_m1());
    tick(); T(pins_none());
    bus |= NMI;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // next EI, start of NMI handling
    tick(); T(pins_m1());
    tick(); T(pins_none()); T(!iff1());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // NMI: extra tick
    tick(); T(pins_none());
    // NMI: push PC
    tick(); T(pins_none()); T(!iff1());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());

    // first overlapped tick of interrupt service routine
    tick(); T(pins_m1()); T(cpu.pc == 0x0067); T(!iff1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());

    // RETN
    // ED prefix
    tick(); T(pins_m1()); T(cpu.r[A] == 0x33);
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // opcode
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread()); T(cpu.SP() == 0x00FF);
    tick(); T(pins_none()); T(0 == (bus & RETI));
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread()); T(cpu.SP() == 0x0100);
    tick(); T(pins_none()); T(!iff1());

    // continue after NMI
    tick(); T(pins_m1()); T(iff1());

    ok();
}

// test that NMIs don't trigger after prefixes
fn NMI_prefix() void {
    start("NMI_prefix");
    const isr = [_]u8{
        0x3E, 0x33,     // LD A,33h
        0xED, 0x45,     // RETN
    };

    //=== DD prefix
    const dd_prog = [_]u8{
        0xFB,               //      EI
        0xDD, 0x46, 0x01,   // l0:  LD B,(IX+1)
        0x00,               //      NOP
        0x18, 0xFA,         //      JR l0
    };
    init(0x0000, &dd_prog);
    copy(0x0066, &isr);

    // EI
    skip(4);

    // LD B,(IX+1)
    // trigger NMI during prefix
    tick(); T(pins_m1());
    bus |= NMI;
    tick(); T(pins_none()); T(iff1());
    bus &= ~NMI;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // opcode, NMI should not have triggered
    tick(); T(pins_m1());
    tick(); T(pins_none()); T(iff1());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // run to end of LD B,(IX+1)
    skip(11); T(iff1());

    // NOP, NMI should trigger now
    tick(); T(pins_m1());
    tick(); T(pins_none());  T(!iff1());

    //== ED prefix
    const ed_prog = [_]u8{
        0xFB,               //      EI
        0xED, 0xA0,         // l0:  LDI
        0x00,               //      NOP
        0x18, 0xFB,         //      JR l0
    };
    init(0x0000, &ed_prog);
    copy(0x0066, &isr);

    // EI
    skip(4);

    // LDI, trigger NMI during ED prefix
    tick(); T(pins_m1());
    bus |= NMI;
    tick(); T(pins_none()); T(iff1());
    bus &= ~NMI;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // opcode, NMI should not have triggered
    tick(); T(pins_m1());
    tick(); T(pins_none()); T(iff1());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // run to end of LDI
    skip(8); T(iff1());

    // NOP, NMI should trigger now
    tick(); T(pins_m1());
    tick(); T(pins_none());  T(!iff1());

    //== CB prefix
    const cb_prog = [_]u8{
        0xFB,           //      EI
        0xCB, 0x17,     // l0:  RL A
        0x00,           //      NOP
        0x18, 0xFB,     //      JR l0
    };
    init(0x0000, &cb_prog);
    copy(0x0066, &isr);

    // EI
    skip(4);

    // RL A, trigger NMI during CB prefix
    tick(); T(pins_m1());
    bus |= NMI;
    tick(); T(pins_none()); T(iff1());
    bus &= ~NMI;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // opcode, NMI should not have triggered
    tick(); T(pins_m1());
    tick(); T(pins_none()); T(iff1());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());

    // NOP, NMI should trigger now
    tick(); T(pins_m1());
    tick(); T(pins_none());  T(!iff1());

    //== DD+CB prefix
    const ddcb_prog = [_]u8{
        0xFB,                       //      EI
        0xDD, 0xCB, 0x01, 0x16,     // l0:  RL (IX+1)
        0x00,                       //      NOP
        0x18, 0xF9,                 //      JR l0
    };
    init(0x0000, &ddcb_prog);
    copy(0x0066, &isr);

    // EI
    skip(4);

    // RL (IX+1), trigger NMI during DD+CB prefix
    tick(); T(pins_m1());
    bus |= NMI;
    tick(); T(pins_none()); T(iff1());
    bus &= ~NMI;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // CB prefix, NMI should not trigger
    tick(); T(pins_m1());
    tick(); T(pins_none()); T(iff1());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // run to end of RL (IX+1)
    skip(15); T(iff1());

    // NOP, NMI should trigger now
    tick(); T(pins_m1());
    tick(); T(pins_none()); T(!iff1());

    ok();
}

// test IM0 interrupt behaviour and timing
fn INT_IM0() void {
    start("INT_IM0");
    const prog = [_]u8{
        0xFB,               //      EI
        0xED, 0x46,         //      IM 0
        0x31, 0x22, 0x11,   //      LD SP, 1122h
        0x00, 0x00, 0x00,   // l0:  NOPS
        0x18, 0xFB,         //      JR l0
    };
    const isr = [_]u8{
        0x3E, 0x33,         //      LD A,33h
        0xED, 0x4D,         //      RETI
    };
    init(0x0000, &prog);
    copy(0x0038, &isr);
    cpu.setSP(0x0100);

    // EI + IM 0 + LD SP,1122h
    skip(22);
    // NOP
    im0_tick(); T(pins_m1());
    im0_tick(); T(pins_none());
    bus |= INT;
    im0_tick(); T(pins_rfsh());
    im0_tick(); T(pins_none());
    // interrupt handling starts here
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_none()); T(!iff1()); T(!iff2());
    im0_tick(); T(pins_m1iorq()); T(Z80.getData(bus) == 0xFF);
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_rfsh());
    im0_tick(); T(pins_none());
    // RST execution should start here
    im0_tick(); T(pins_none());
    // mwrite (push PC)
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_mwrite());
    im0_tick(); T(pins_none());
    // mwrite (push PC)
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_mwrite());
    im0_tick(); T(pins_none());
    // interrupt service routine at address 0x0038 (LD A,33)
    im0_tick(); T(pins_m1()); T(cpu.pc == 0x0039);
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_rfsh());
    im0_tick(); T(pins_none());
    // mread
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_mread());
    im0_tick(); T(pins_none());
    // RETI, ED prefix
    im0_tick(); T(pins_m1());
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_rfsh());
    im0_tick(); T(pins_none());
    // RETI opcode
    im0_tick(); T(pins_m1());
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_rfsh());
    im0_tick(); T(pins_none());
    // RETI mread (pop)
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_mread());
    im0_tick(); T(pins_none()); T(0 != (bus & RETI));
    // RETI mread (pop)
    im0_tick(); T(pins_none());
    im0_tick(); T(pins_mread());
    im0_tick(); T(pins_none());

    // continue with next NOP, NOTE: iff1 is *NOT* reenabled!
    im0_tick(); T(pins_m1()); T(!iff1());
    im0_tick(); T(pins_none()); T(!iff1());
    im0_tick(); T(pins_rfsh()); T(!iff1());
    im0_tick(); T(pins_none()); T(!iff1());

    ok();
}

// test IM1 interrupt behaviour and timing
fn INT_IM1() void {
    start("INT_IM1");
    const prog = [_]u8{
        0xFB,               //      EI
        0xED, 0x56,         //      IM 1
        0x00, 0x00, 0x00,   // l0:  NOPs
        0x18, 0xFB,         //      JR l0
    };
    const isr = [_]u8{
        0x3E, 0x33,         //      LD A,33h
        0xED, 0x4D,         //      RETI
    };
    init(0x0000, &prog);
    copy(0x0038, &isr);
    cpu.setSP(0x0100);

    // EI + IM1
    skip(12);

    // NOP
    tick(); T(pins_m1()); T(iff1());
    tick(); T(pins_none());
    bus |= INT;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());

    // interrupt should trigger now
    tick(); T(pins_none());
    tick(); T(pins_none()); T(!iff1()); T(!iff2());
    tick(); T(pins_m1iorq());
    tick(); T(pins_none());
    // regular refresh cycle
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // one extra tcycle
    tick(); T(pins_none());
    // two mwrite cycles (push PC to stack)
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());
    // ISR starts here (LD A,33h)
    tick(); T(pins_m1());  T(!iff1()); T(!iff2()); T(cpu.pc == 0x0039);
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread (LD A,33h)
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());
    // RETI, ED prefix
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // RETI opcode
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // RETI mread (pop)
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none()); T(0 != (bus & RETI));
    // RETI mread (pop)
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());

    // next NOP (interrupts still disabled!)
    tick(); T(pins_m1()); T(!iff1()); T(!iff2()); T(cpu.pc == 5);

    ok();
}

// test IM2 interrupt behaviour and timing
fn INT_IM2() void {
    start("INT_IM2");
    const prog = [_]u8{
        0xFB,               //      EI
        0xED, 0x5E,         //      IM 2
        0x3E, 0x01,         //      LD A,1
        0xED, 0x47,         //      LD I,A
        0x00, 0x00, 0x00,   // l0:  NOPs
        0x18, 0xFB,         //      JR l0
        0x00,               //      ---
        0x3E, 0x33,         // isr: LD A,33h
        0xED, 0x4D,         //      RETI
    };
    const int_vec = [_]u8{
        0x0D, 0x00,         //      DW isr (0x000D)
    };
    init(0x0000, &prog);
    copy(0x01E0, &int_vec);

    // EI
    skip(4);
    // IM 2
    skip(8);
    // LD A,1
    skip(7);
    // LD I,A
    skip(9); T(iff1()); T(iff2()); T(cpu.im == 2);

    // NOP
    tick(); T(pins_m1()); T(cpu.I() == 1);
    tick(); T(pins_none());
    bus |= INT;
    tick(); T(pins_rfsh());
    tick(); T(pins_none());

    // interrupt should trigger now
    tick(); T(pins_none());
    tick(); T(pins_none()); T(!iff1()); T(!iff2());
    tick(); T(pins_m1iorq());
    tick(); T(pins_none());
    // regular refresh cycle
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // one extra tcycle
    tick(); T(pins_none());
    // two mwrite cycles (push PC to stack)
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none()); T(cpu.WZ() == 0x01E0);    // WZ is interrupt vector
    // two mread cycles from interrupt vector
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none()); T(cpu.WZ() == 0x000D); T(cpu.pc == 0x000D);

    // ISR starts here (LD A,33h)
    tick(); T(pins_m1()); T(!iff1()); T(!iff2()); T(cpu.pc == 0x000E);
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread (LD A,33h)
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());
    // RETI, ED prefix
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // RETI opcode
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // RETI mread (pop)
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none()); T(0 != (bus & RETI));
    // RETI mread (pop)
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());

    // next NOP (interrupts still disabled!)
    tick(); T(pins_m1()); T(!iff1()); T(!iff2()); T(cpu.pc == 9);

    ok();
}

// maskable interrupts shouldn't trigger when interrupts are disabled
fn INT_disabled() void {
    start("INT_disabled");
    const prog = [_]u8{
        0xF3,       //      DI
        0xED, 0x56, //      IM 1
        0x00,       // l0:  NOP
        0x18, 0xFD, //      JR l0
    };
    const isr = [_]u8{
        0x3E, 0x33, //      LD A,33h
        0xED, 0x3D, //      RETI
    };
    init(0x0000, &prog);
    copy(0x0038, &isr);

    // DI
    skip(4);
    // IM 1
    skip(8);

    // NOP
    tick(); T(pins_m1());
    bus |= INT;
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // JR l0 (interrupt should not have triggered)
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // mread
    tick(); T(pins_none());
    tick(); T(pins_mread());
    tick(); T(pins_none());
    // 5x ticks
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_none());

    // next NOP
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());

    ok();
}

// maskable interrupts shouldn't trigger during EI sequences
fn INT_EI_sequence() void {
    start("INT_EI_sequence");
    const prog = [_]u8{
        0xFB,               //      EI
        0xED, 0x56,         //      IM 1
        0xFB, 0xFB, 0xFB,   // l0:  3x EI
        0x00,               //      NOP
        0x18, 0xFA,         //      JR l0
    };
    const isr = [_]u8{
        0x3E, 0x33,         //      LD A,33h
        0xED, 0x3D,         //      RETI
    };
    init(0x0000, &prog);
    copy(0x0038, &isr);

    // EI
    skip(4);
    // IM 1
    skip(8);

    // EI
    tick(); T(pins_m1());
    bus |= INT;
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // EI (interrupt shouldn't trigger)
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // EI (interrupt shouldn't trigger)
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // NOP (interrupt should trigger at end)
    tick(); T(pins_m1());
    tick(); T(pins_none());
    tick(); T(pins_rfsh());
    tick(); T(pins_none());

    // IM1 interrupt request starts here
    tick(); T(pins_none());
    tick(); T(pins_none()); T(!iff1()); T(!iff2());
    tick(); T(pins_m1iorq());
    tick(); T(pins_none());
    // regular refresh cycle
    tick(); T(pins_rfsh());
    tick(); T(pins_none());
    // one extra tcycle
    tick(); T(pins_none());
    // two mwrite cycles (push PC to stack)
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());
    tick(); T(pins_none());
    tick(); T(pins_mwrite());
    tick(); T(pins_none());
    // ISR starts here (LD A,33h)
    tick(); T(pins_m1());  T(!iff1()); T(!iff2()); T(cpu.pc == 0x0039);

    ok();
}

pub fn main() void {
    NMI_regular();
    NMI_before_after();
    NMI_no_retrigger();
    NMI_during_EI();
    NMI_prefix();
    INT_IM0();
    INT_IM1();
    INT_IM2();
    INT_disabled();
    INT_EI_sequence();
}
