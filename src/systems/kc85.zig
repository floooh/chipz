//! a KC85/2, /3 and /4 emulator
const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const z80 = chips.z80;
const z80pio = chips.z80pio;
const z80ctc = chips.z80ctc;
const common = @import("common");
const memory = common.memory;
const clock = common.clock;
const pin = common.bitutils.pin;

// KC85 models
pub const Model = enum {
    KC852,
    KC853,
    KC854,
};

// Z80 bus definitions
const CPU_PINS = z80.Pins{
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
    .RETI = 35,
};

// Z80 PIO bus definitions
const PIO_PINS = z80pio.Pins{
    .DBUS = CPU_PINS.DBUS,
    .M1 = CPU_PINS.M1,
    .IORQ = CPU_PINS.IORQ,
    .RD = CPU_PINS.RD,
    .INT = CPU_PINS.INT,
    .CE = 36,
    .BASEL = CPU_PINS.A[0], // BASEL pin is directly connected to A0
    .CDSEL = CPU_PINS.A[1], // CDSEL pin is directly connected to A1
    .ARDY = 37,
    .BRDY = 38,
    .ASTB = 39,
    .BSTB = 40,
    .PA = .{ 64, 65, 66, 67, 68, 69, 70, 71 },
    .PB = .{ 72, 73, 74, 75, 76, 77, 78, 79 },
    .RETI = CPU_PINS.RETI,
    .IEIO = 50,
};

// Z80 CTC bus definitions
const CTC_PINS = z80ctc.Pins{
    .DBUS = CPU_PINS.DBUS,
    .M1 = CPU_PINS.M1,
    .IORQ = CPU_PINS.IORQ,
    .RD = CPU_PINS.RD,
    .INT = CPU_PINS.INT,
    .CE = 51,
    .CS = .{ CPU_PINS.A[0], CPU_PINS.A[1] }, // CTC CS0/CS1 are directly connected to A0/A1
    .CLKTRG = .{ 52, 53, 54, 55 },
    .ZCTO = .{ 56, 57, 58 },
    .RETI = CPU_PINS.RETI,
    .IEIO = PIO_PINS.IEIO,
};

// NOTE: 64 bits isn't enough for the system bus
const Bus = u128;
const Memory = memory.Type(.{ .page_size = 0x0400 });
const Z80 = z80.Type(.{ .pins = CPU_PINS, .bus = Bus });
const Z80PIO = z80pio.Type(.{ .pins = PIO_PINS, .bus = Bus });
const Z80CTC = z80ctc.Type(.{ .pins = CTC_PINS, .bus = Bus });

const getData = Z80.getData;
const setData = Z80.setData;
const getAddr = Z80.getAddr;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RD = Z80.RD;
const WR = Z80.WR;

pub fn Type(comptime model: Model) type {
    _ = model; // autofix
    return struct {
        const Self = @This();
    };
}
