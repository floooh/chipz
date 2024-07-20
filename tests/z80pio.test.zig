const std = @import("std");
const expect = std.testing.expect;
const chipz = @import("chipz");
const z80pio = chipz.chips.z80pio;

const Bus = u64;
const Z80PIO = z80pio.Z80PIO(.{ .pins = z80pio.DefaultPins, .bus = Bus });

const setData = Z80PIO.setData;

const IORQ = Z80PIO.IORQ;
const RD = Z80PIO.RD;
const CE = Z80PIO.CE;
const BASEL = Z80PIO.BASEL;
const CDSEL = Z80PIO.CDSEL;

const PORT = Z80PIO.PORT;
const MODE = Z80PIO.MODE;
const INTCTRL = Z80PIO.INTCTRL;

test "init Z80PIO" {
    const pio = Z80PIO.init();
    try expect(pio.reset_active);
    for (&pio.ports) |*p| {
        try expect(p.mode == MODE.INPUT);
        try expect(p.int_mask == 0xFF);
    }
}

test "write interrupt vector" {
    var pio = Z80PIO.init();

    // port A...
    _ = pio.tick(setData(CE | IORQ | CDSEL, 0xEE));
    try expect(!pio.reset_active);
    try expect(pio.ports[PORT.A].irq.vector == 0xEE);
    try expect(0 != (pio.ports[PORT.A].int_control & INTCTRL.EI));
    try expect(pio.ports[PORT.A].int_enabled);

    // port B...
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, 0xCC));
    try expect(pio.ports[PORT.B].irq.vector == 0xCC);
    try expect(0 != (pio.ports[PORT.B].int_control & INTCTRL.EI));
    try expect(pio.ports[PORT.B].int_enabled);
}

test "set input/output mode" {
    var pio = Z80PIO.init();

    // set port A to output...
    _ = pio.tick(setData(CE | IORQ | CDSEL, (@as(u8, MODE.OUTPUT) << 6) | 0x0F));
    try expect(pio.ports[PORT.A].mode == MODE.OUTPUT);

    // set port B to input...
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, (@as(u8, MODE.INPUT) << 6) | 0x0F));
    try expect(pio.ports[PORT.B].mode == MODE.INPUT);
}
