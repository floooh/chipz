const std = @import("std");
const expect = std.testing.expect;
const chipz = @import("chipz");
const z80ctc = chipz.chips.z80ctc;
const z80 = chipz.chips.z80;
const pin = chipz.common.bitutils.pin;
const pins = chipz.common.bitutils.pins;

const BusDecl = .{
    // Z80 and shared pins
    .DBUS = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .ABUS = .{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 },
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

    // extra CTC pins (NOTE: CS pins are wired to A0 and A1)
    .CTC_CE = 34,
    .CTC_CLKTRG = .{ 37, 38, 39, 40 },
    .CTC_ZCTO = .{ 41, 42, 43 },

    // virtual pins
    .RETI = 45,
    .IEIO = 46,
};

const Z80Pins = z80.Pins{
    .DBUS = BusDecl.DBUS,
    .ABUS = BusDecl.ABUS,
    .M1 = BusDecl.M1,
    .MREQ = BusDecl.MREQ,
    .IORQ = BusDecl.IORQ,
    .RD = BusDecl.RD,
    .WR = BusDecl.WR,
    .RFSH = BusDecl.RFSH,
    .HALT = BusDecl.HALT,
    .WAIT = BusDecl.WAIT,
    .INT = BusDecl.INT,
    .NMI = BusDecl.NMI,
    .RETI = BusDecl.RETI,
};

const Z80CTCPins = z80ctc.Pins{
    .DBUS = BusDecl.DBUS,
    .M1 = BusDecl.M1,
    .IORQ = BusDecl.IORQ,
    .RD = BusDecl.RD,
    .INT = BusDecl.INT,
    .CE = BusDecl.CTC_CE,
    .CS = .{ BusDecl.ABUS[0], BusDecl.ABUS[1] },
    .CLKTRG = BusDecl.CTC_CLKTRG,
    .ZCTO = BusDecl.CTC_ZCTO,
    .RETI = BusDecl.RETI,
    .IEIO = BusDecl.IEIO,
};

const Bus = u64;
const Z80 = z80.Z80(.{ .pins = Z80Pins, .bus = Bus });
const Z80CTC = z80ctc.Z80CTC(.{ .pins = Z80CTCPins, .bus = Bus });

const setData = Z80.setData;
const getData = Z80.getData;
const getAddr = Z80.getAddr;
const M1 = Z80.M1;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RD = Z80.RD;
const WR = Z80.WR;
const CE = Z80CTC.CE;
const CS0 = Z80CTC.CS0;
const CS1 = Z80CTC.CS1;
const ZCTO1 = Z80CTC.ZCTO1;
const CLKTRG1 = Z80CTC.CLKTRG1;
const IEIO = Z80CTC.IEIO;

const CTRL = Z80CTC.CTRL;

test "init Z80CTC" {
    const ctc = Z80CTC.init();
    for (0..3) |i| {
        try expect(ctc.chn[i].control & Z80CTC.CTRL.RESET != 0);
        try expect(ctc.chn[i].prescaler_mask == 0x0F);
    }
}

test "write int vector" {
    var ctc = Z80CTC.init();
    var bus = setData(CE | IORQ, 0xE0);
    bus = ctc.tick(bus);
    try expect(bus == setData(CE | IORQ, 0xE0));
    try expect(ctc.chn[0].irq.vector == 0xE0);
    try expect(ctc.chn[1].irq.vector == 0xE2);
    try expect(ctc.chn[2].irq.vector == 0xE4);
    try expect(ctc.chn[3].irq.vector == 0xE6);
}

test "timer" {
    var ctc = Z80CTC.init();
    const ctrl = CTRL.EI | CTRL.MODE_TIMER | CTRL.PRESCALER_16 | CTRL.TRIGGER_AUTO | CTRL.CONST_FOLLOWS | CTRL.CONTROL;
    // write control word for channel 1
    var bus = ctc.tick(setData(CE | IORQ | CS0, ctrl));
    try expect(ctc.chn[1].control == ctrl);
    try expect(ctc.chn[1].prescaler_mask == 0x0F);
    // write timer constant for channel 1
    bus = ctc.tick(setData(CE | IORQ | CS0, 10));
    try expect(0 == ctc.chn[1].control & CTRL.CONST_FOLLOWS);
    try expect(10 == ctc.chn[1].constant);
    try expect(10 == ctc.chn[1].down_counter);
    bus = 0;
    for (0..3) |_| {
        for (0..160) |tck| {
            bus = ctc.tick(bus);
            if (tck != 159) {
                try expect(0 == bus & ZCTO1);
            } else {
                try expect(0 != bus & ZCTO1);
                try expect(10 == ctc.chn[1].down_counter);
            }
        }
    }
}

test "timer wait trigger" {
    var ctc = Z80CTC.init();
    const ctrl = CTRL.EI | CTRL.MODE_TIMER | CTRL.PRESCALER_16 | CTRL.TRIGGER_WAIT | CTRL.EDGE_RISING | CTRL.CONST_FOLLOWS | CTRL.CONTROL;
    // write control word for channel 1
    var bus = ctc.tick(setData(CE | IORQ | CS0, ctrl));
    try expect(ctc.chn[1].control == ctrl);
    try expect(ctc.chn[1].prescaler_mask == 0x0F);
    // write timer constant
    bus = ctc.tick(setData(CE | IORQ | CS0, 10));
    try expect(0 == ctc.chn[1].control & CTRL.CONST_FOLLOWS);
    try expect(10 == ctc.chn[1].constant);
    bus = 0;
    // tick the CTC without starting the timer
    for (0..300) |_| {
        bus = ctc.tick(bus);
        try expect(0 == bus & ZCTO1);
    }
    // now start the timer on next tick
    bus = ctc.tick(bus | CLKTRG1);
    try expect(10 == ctc.chn[1].down_counter);
    for (0..3) |_| {
        for (0..160) |tck| {
            bus = ctc.tick(bus);
            if (tck != 159) {
                try expect(0 == bus & ZCTO1);
            } else {
                try expect(0 != bus & ZCTO1);
                try expect(10 == ctc.chn[1].down_counter);
            }
        }
    }
}

test "counter" {
    var ctc = Z80CTC.init();
    const ctrl = CTRL.EI | CTRL.MODE_COUNTER | CTRL.EDGE_RISING | CTRL.CONST_FOLLOWS | CTRL.CONTROL;
    // write control word for channel 1
    var bus = ctc.tick(setData(CE | IORQ | CS0, ctrl));
    try expect(ctc.chn[1].control == ctrl);
    // write counter constant
    bus = ctc.tick(setData(CE | IORQ | CS0, 10));
    try expect(0 == ctc.chn[1].control & CTRL.CONST_FOLLOWS);
    try expect(10 == ctc.chn[1].constant);

    for (0..3) |_| {
        for (0..10) |tck| {
            // switch CLKTRG1 on/off
            bus |= CLKTRG1;
            bus = ctc.tick(bus);
            if (tck != 9) {
                try expect(0 == bus & ZCTO1);
            } else {
                try expect(0 != bus & ZCTO1);
                try expect(10 == ctc.chn[1].down_counter);
            }
            bus &= ~CLKTRG1;
            bus = ctc.tick(bus);
        }
    }
}

// a complete CPU+CTC interrupt test
const state = struct {
    var cpu: Z80 = undefined;
    var ctc: Z80CTC = undefined;
    var mem = [_]u8{0} ** 0x10000;
    var tick_count: usize = 0;
};

fn tick(in_bus: Bus) Bus {
    state.tick_count += 1;
    var bus = in_bus & ~CE;
    bus = state.cpu.tick(bus);
    if (pin(bus, MREQ)) {
        const addr = getAddr(bus);
        if (pin(bus, RD)) {
            const data = state.mem[addr];
            bus = setData(bus, data);
        } else if (pin(bus, WR)) {
            const data = getData(bus);
            state.mem[addr] = data;
        }
    } else if (pin(bus, IORQ)) {
        // just assume that each IO request is for the CTC
        // NOTE: CS0/CS1 are wired to A0/A1
        bus |= CE;
    }
    bus = state.ctc.tick(bus | IEIO);
    return bus;
}

fn w16(addr: u16, data: u16) void {
    state.mem[addr] = @truncate(data);
    state.mem[addr +% 1] = @truncate(data >> 8);
}

fn copy(start_addr: u16, bytes: []const u8) void {
    std.mem.copyForwards(u8, state.mem[start_addr..], bytes);
}

// - setup CTC channel 0 to request an interrupt every 1024 ticks
// - go into a halt, which is left at interrupt, increment a
//   memory location, and loop back to the halt
// - an interrupt routine increments another memory location
// - run CPU for N ticks, check if both counters have expected values
test "interrupt" {
    state.cpu = Z80.init();
    state.ctc = Z80CTC.init();

    // location of interrupt routine
    w16(0x00E0, 0x0200);

    const ctc_ctrl: u8 = CTRL.EI | CTRL.MODE_TIMER | CTRL.PRESCALER_256 | CTRL.TRIGGER_AUTO | CTRL.CONST_FOLLOWS | CTRL.CONTROL;

    // main program at address 0x0100
    const main_prog = [_]u8{
        0x31, 0x00, 0x03, // LD SP,0x0300
        0xFB, // EI
        0xED, 0x5E, // IM 2
        0xAF, // XOR A
        0xED, 0x47, // LD I,A
        0x3E, 0xE0, // LD A,0xE0: load interrupt vector into CTC channel 0
        0xD3, 0x00, // OUT (0),A
        0x3E, ctc_ctrl, // LD A,n: configure CTC channel 0 as timer
        0xD3, 0x00, // OUT (0),A
        0x3E, 0x04, // LD A,0x04: timer constant (with prescaler 256): 4 * 256 = 1024
        0xD3, 0x00, // OUT (0),A
        0x76, // HALT
        0x21, 0x00, 0x00, // LD HL,0x0000
        0x34, // INC (HL)
        0x18, 0xF9, // JR -> HALT, endless loop back to the HALT instruction
    };
    copy(0x0100, &main_prog);

    // interrupt service routine, increment content of 0x0001
    const int_prog = [_]u8{
        0xF3, // DI
        0x21, 0x01, 0x00, // LD HL,0x0001
        0x34, // INC (HL)
        0xFB, // EI
        0xED, 0x4D, // RETI
    };
    copy(0x0200, &int_prog);

    // run for 4500 ticks, this should invoke the interrupt routine 4x
    state.cpu.prefetch(0x0100);
    var bus: Bus = 0;
    for (0..4500) |_| {
        bus = tick(bus);
    }
    try expect(state.mem[0x0000] == 4);
    try expect(state.mem[0x0001] == 4);
}
