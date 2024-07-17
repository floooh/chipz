const std = @import("std");
const expect = std.testing.expect;
const chipz = @import("chipz");
const z80pio = chipz.chips.z80pio;

const Bus = u64;
const Z80PIO = z80pio.Z80PIO(z80pio.DefaultPins, Bus);

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

// FIXME: more tests
