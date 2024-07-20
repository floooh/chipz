const std = @import("std");
const expect = std.testing.expect;
const chipz = @import("chipz");
const z80pio = chipz.chips.z80pio;

const Bus = u64;
const Z80PIO = z80pio.Type(.{ .pins = z80pio.DefaultPins, .bus = Bus });

const setData = Z80PIO.setData;
const getData = Z80PIO.getData;

const IORQ = Z80PIO.IORQ;
const RD = Z80PIO.RD;
const CE = Z80PIO.CE;
const BASEL = Z80PIO.BASEL;
const CDSEL = Z80PIO.CDSEL;

const PORT = Z80PIO.PORT;
const MODE = Z80PIO.MODE;
const INTCTRL = Z80PIO.INTCTRL;

fn modeAsData(mode: u2) u8 {
    return (@as(u8, mode) << 6) | 0x0F;
}

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
    const pa = &pio.ports[PORT.A];
    const pb = &pio.ports[PORT.B];

    // port A...
    _ = pio.tick(setData(CE | IORQ | CDSEL, 0xEE));
    try expect(!pio.reset_active);
    try expect(pa.irq.vector == 0xEE);
    try expect(0 != (pa.int_control & INTCTRL.EI));
    try expect(pa.int_enabled);

    // port B...
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, 0xCC));
    try expect(pb.irq.vector == 0xCC);
    try expect(0 != (pb.int_control & INTCTRL.EI));
    try expect(pb.int_enabled);
}

test "set input/output mode" {
    var pio = Z80PIO.init();
    const pa = &pio.ports[PORT.A];
    const pb = &pio.ports[PORT.B];

    // set port A to output...
    _ = pio.tick(setData(CE | IORQ | CDSEL, modeAsData(MODE.OUTPUT)));
    try expect(pa.mode == MODE.OUTPUT);

    // set port B to input...
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, modeAsData(MODE.INPUT)));
    try expect(pb.mode == MODE.INPUT);
}

test "set port A to bidirectional" {
    var pio = Z80PIO.init();
    _ = pio.tick(setData(CE | IORQ | CDSEL, modeAsData(MODE.BIDIRECTIONAL)));
    try expect(pio.ports[PORT.A].mode == MODE.BIDIRECTIONAL);
}

test "set port A to bitcontrol plus followup io-select mask" {
    var pio = Z80PIO.init();
    const pa = &pio.ports[PORT.A];

    // set interrupt vector (also enabled interrupts)
    _ = pio.tick(setData(CE | IORQ | CDSEL, 0xE0));
    try expect(pa.int_enabled);
    try expect(pa.irq.vector == 0xE0);

    // set bitcontrol mode (also disables interrupts)
    _ = pio.tick(setData(CE | IORQ | CDSEL, modeAsData(MODE.BITCONTROL)));
    try expect(!pa.int_enabled);
    try expect(pa.mode == MODE.BITCONTROL);

    // set io-select mask
    _ = pio.tick(setData(CE | IORQ | CDSEL, 0xAA));
    try expect(pa.int_enabled);
    try expect(pa.io_select == 0xAA);
}

test "set port B interrupt control and interrupt control mask, enable interrupts" {
    var pio = Z80PIO.init();
    const pb = &pio.ports[PORT.B];
    const int_ctrl = INTCTRL.ANDOR | INTCTRL.HILO | INTCTRL.MASK_FOLLOWS;

    // set interrupt vector (also enabled interrupts)
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, 0xE0));
    try expect(pb.int_enabled);
    try expect(pb.irq.vector == 0xE0);

    // write interrupt control word
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, int_ctrl | 0x07));
    try expect(!pb.int_enabled);
    try expect(pb.int_control == int_ctrl);

    // write interrupt control mask
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, 0x23));
    try expect(!pb.int_enabled);
    try expect(pb.int_mask == 0x23);

    // enable interrupts
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, INTCTRL.EI | 0x03));
    try expect(pb.int_enabled);
    try expect(pb.int_control == (int_ctrl | INTCTRL.EI));
}

// write interrupt control word to A and B,
// and read the control word back, this does not
// seem to be documented anywhere, so we're doing
// the same thing that MAME does.
test "write/read interrupt control word" {
    var pio = Z80PIO.init();
    const int_ctrl_a = INTCTRL.ANDOR | INTCTRL.HILO;
    const int_ctrl_b = INTCTRL.EI | INTCTRL.ANDOR;
    _ = pio.tick(setData(CE | IORQ | CDSEL, int_ctrl_a | 0x07));
    _ = pio.tick(setData(CE | IORQ | BASEL | CDSEL, int_ctrl_b | 0x07));
    const bus = pio.tick(CE | IORQ | RD | CDSEL);
    try expect(getData(bus) == 0x4C);
}
