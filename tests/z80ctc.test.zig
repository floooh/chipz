const expect = @import("std").testing.expect;
const z80ctc = @import("chipz").chips.z80ctc;

const Pins = z80ctc.DefaultPins;
const Bus = u32;
const Z80CTC = z80ctc.Z80CTC(Pins, Bus);

const setData = Z80CTC.setData;
const CE = Z80CTC.CE;
const IORQ = Z80CTC.IORQ;
const CS0 = Z80CTC.CS0;
const CS1 = Z80CTC.CS1;
const ZCTO1 = Z80CTC.ZCTO1;
const CLKTRG1 = Z80CTC.CLKTRG1;

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
    try expect(ctc.chn[0].int_vector == 0xE0);
    try expect(ctc.chn[1].int_vector == 0xE2);
    try expect(ctc.chn[2].int_vector == 0xE4);
    try expect(ctc.chn[3].int_vector == 0xE6);
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
        for (0..160) |tick| {
            bus = ctc.tick(bus);
            if (tick != 159) {
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
        for (0..160) |tick| {
            bus = ctc.tick(bus);
            if (tick != 159) {
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
        for (0..10) |tick| {
            // switch CLKTRG1 on/off
            bus |= CLKTRG1;
            bus = ctc.tick(bus);
            if (tick != 9) {
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
