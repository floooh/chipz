const expect = @import("std").testing.expect;
const z80ctc = @import("chipz").chips.z80ctc;

const Pins = z80ctc.DefaultPins;
const Bus = u32;
const Z80CTC = z80ctc.Z80CTC(Pins, Bus);

test "init Z80CTC" {
    const ctc = Z80CTC.init();
    for (0..3) |i| {
        try expect(ctc.chn[i].control & Z80CTC.CTRL.RESET != 0);
        try expect(ctc.chn[i].prescaler_mask == 0x0F);
    }
}
