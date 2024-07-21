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
const AudioCallback = common.glue.AudioCallback;
const AudioOptions = common.glue.AudioOptions;
const DisplayInfo = common.glue.DisplayInfo;

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
    return struct {
        const Self = @This();

        // runtime options
        pub const Options = struct {
            audio: AudioOptions,
            // FIXME: patch callback
            roms: switch (model) {
                .KC852 => struct {
                    caos22: []const u8,
                },
                .KC853 => struct {
                    caos31: []const u8,
                    kcbasic: []const u8,
                },
                .KC854 => struct {
                    caos42c: []const u8,
                    caos42e: []const u8,
                    kcbasic: []const u8,
                },
            },
        };

        pub const FREQUENCY = if (model == .KC854) 1770000 else 1750000;
        pub const SCANLINE_TICKS = if (model == .KC854) 112 else 113;
        pub const NUM_SCANLINES = 312;

        pub const DISPLAY = struct {
            pub const WIDTH = 320;
            pub const HEIGHT = 256;
            pub const FB_WIDTH = 512;
            pub const FB_HEIGHT = 256;
        };

        // PIO output pins
        pub const PIO = struct {
            pub const CAOS_ROM = Z80PIO.PA[0];
            pub const RAM = Z80PIO.PA[1];
            pub const IRM = Z80PIO.PA[2];
            pub const RAM_RO = Z80PIO.PA[3];
            pub const NMI = Z80PIO.PA[4]; // KC85/2,/3 only
            pub const TAPE_LED = Z80PIO.PA[5];
            pub const TAPE_MOTOR = Z80PIO.PA[6];
            pub const BASIC_ROM = Z80PIO.PA[7];
            pub const RAM8 = Z80PIO.PB[5];
            pub const RAM8_RO = Z80PIO.PB[6];
            pub const BLINK_ENABLED = Z80PIO.PB[7];

            // IO bits which affect memory mapping
            pub const MEMORY_BITS = CAOS_ROM | RAM | IRM | RAM_RO | BASIC_ROM | RAM8 | RAM8_RO;
        };

        // CTC output pins
        pub const CTC = struct {
            pub const BEEPER1 = Z80CTC.ZCTO[0];
            pub const BEEPER2 = Z80CTC.ZCTO[1];
            pub const BLINK = Z80CTC.ZCTO[2];
        };

        // KC85/4 IO address 0x84 latch
        pub const IO84 = struct {
            pub const SEL_VIEW_IMG = 1 << 0; // 0: display img0, 1: display img1
            pub const SEL_CPU_COLOR = 1 << 1; // 0: access pixels, 1: access colors
            pub const SEL_CPU_IMG = 1 << 2; // 0: access img 0, 1: access img 1
            pub const HICOLOR = 1 << 3; // 0: hicolor mode off, 1: hicolor mode on
            pub const SEL_RAM8 = 1 << 4; // select RAM8 block 0 or 1

            // latch bits which affect memory mapping
            pub const MEMORY_BITS = SEL_CPU_COLOR | SEL_CPU_IMG | SEL_RAM8;
        };

        // KC85/4 IO address 0x86 latch
        pub const IO86 = struct {
            pub const RAM4 = 1 << 0;
            pub const RAM4_RO = 1 << 1;
            pub const CAOS_ROM_C = 1 << 7;

            // latch bits which affect memory mapping
            pub const MEMORY_BITS = RAM4 | RAM4_RO | CAOS_ROM_C;
        };

        // expansion system constant
        pub const EXP = struct {
            pub const NUM_SLOTS = 2; // number of expansion slots in the base device
            pub const BUF_SIZE = NUM_SLOTS * 64 * 1024; // expansion system buffer size (64 KB per slot)
        };

        // expansion module types
        pub const ModuleType = enum {
            NONE,
            M006_BASIC, // BASIC+CAOS 16 KB ROM module for the KC85/2 (id = 0xFC)
            M011_64KBYTE, // 64 KB RAM expansion (id = 0xF6)
            M012_TEXOR, // TEXOR text editing (id = 0xFB)
            M022_16KBYTE, // 16 KB RAM expansion (id = 0xF4)
            M026_FORTH, // FORTH IDE (id = 0xFB)
            M027_DEVELOPMENT, // Assembler IDE (id = 0xFB)
        };

        // KC85 expansion module state
        pub const Module = struct {
            mod_type: ModuleType = .NONE,
            id: u8 = 0,
            writable: bool = false,
            addr_mask: u8 = 0,
            size: u32 = 0,
        };

        // KC85 expansion slot
        pub const Slot = struct {
            slot: [EXP.NUM_SLOTS]Slot = [_]Slot{.{}} ** EXP.NUM_SLOTS,
            buf_top: u32 = 0,
        };

        // KC85 emulator state
        bus: Bus = 0,
        cpu: Z80,
        pio: Z80PIO,
        ctc: Z80CTC,
        video: struct {
            h_tick: u16 = 0,
            v_count: u16 = 0,
        },
        io84: u8 = 0, // KC85/4 only: byte latch at IO address 0x84
        io86: u8 = 0, // KC85/4 only: byte latch at IO address 0x86
        // FIXME: beepers
        mem: Memory,
    };
}
