//! Z80 CTC emulation
const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;

/// Z80 CTC pin declarations
pub const Pins = struct {
    DBUS: [8]comptime_int,
    M1: comptime_int,
    IORQ: comptime_int,
    RD: comptime_int,
    INT: comptime_int,
    CE: comptime_int,
    CS: [2]comptime_int,
    CLKTRG: [4]comptime_int,
    ZCTO: [3]comptime_int,

    // virtual pins
    RETI: comptime_int, // set by CPU on RETI instruction
    IEIO: comptime_int, // combined IEI and IEO pints
};

/// default pin configuration (mainly useful for testing)
pub const DefaultPins = Pins{
    .DBUS = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .M1 = 8,
    .IORQ = 9,
    .RD = 10,
    .INT = 11,
    .CE = 12,
    .CS = .{ 13, 14 },
    .CLKTRG = .{ 15, 16, 17, 18 },
    .ZCTO = .{ 19, 20, 21 },
    .RETI = 22,
    .IEIO = 23,
};

pub fn Z80CTC(comptime P: Pins, comptime Bus: anytype) type {
    return struct {
        const Self = @This();

        // pin bit masks
        pub const DBUS = maskm(Bus, &P.DBUS);
        pub const D0 = mask(Bus, P.D[0]);
        pub const D1 = mask(Bus, P.D[1]);
        pub const D2 = mask(Bus, P.D[2]);
        pub const D3 = mask(Bus, P.D[3]);
        pub const D4 = mask(Bus, P.D[4]);
        pub const D5 = mask(Bus, P.D[5]);
        pub const D6 = mask(Bus, P.D[6]);
        pub const D7 = mask(Bus, P.D[7]);
        pub const M1 = mask(Bus, P.M1);
        pub const IORQ = mask(Bus, P.IORQ);
        pub const RD = mask(Bus, P.RD);
        pub const INT = mask(Bus, P.INT);
        pub const IEI = mask(Bus, P.IEI);
        pub const IEO = mask(Bus, P.IEO);
        pub const CE = mask(Bus, P.CE);
        pub const CS = maskm(Bus, &P.CS);
        pub const CS0 = mask(Bus, P.CS[0]);
        pub const CS1 = mask(Bus, P.CS[1]);
        pub const CLKTRG = maskm(Bus, &P.CLKTRG);
        pub const CLKTRG0 = mask(Bus, P.CLKTRG[0]);
        pub const CLKTRG1 = mask(Bus, P.CLKTRG[1]);
        pub const CLKTRG2 = mask(Bus, P.CLKTRG[2]);
        pub const CLKTRG3 = mask(Bus, P.CLKTRG[3]);
        pub const ZCTO = maskm(Bus, &P.ZCTO);
        pub const ZCTO0 = mask(Bus, P.ZCTO[0]);
        pub const ZCTO1 = mask(Bus, P.ZCTO[1]);
        pub const ZCTO2 = mask(Bus, P.ZCTO[2]);
        pub const RETI = mask(Bus, P.RETI);
        pub const IEIO = mask(Bus, P.IEIO);

        // control register bits
        pub const CTRL = struct {
            pub const EI: u8 = 1 << 7; // 1: interrupts enabled, 0: interrupts disabled
            pub const MODE: u8 = 1 << 6; // 1: counter mode, 0: timer mode
            pub const PRESCALER: u8 = 1 << 5; // 1: prescaler 256, 0: prescaler 16
            pub const EDGE: u8 = 1 << 4; // 1: edge rising, 0: edge falling
            pub const TRIGGER: u8 = 1 << 3; // 1: CLK/TRG pulse starts timer, 0: load constant starts timer
            pub const CONST_FOLLOWS: u8 = 1 << 2; // 1: time constant follows, 0: no time constant follows
            pub const RESET: u8 = 1 << 1; // 1: software reset, 0: continue operation
            pub const CONTROL: u8 = 1 << 0; // 1: control word, 0: vector
        };

        pub const IRQ = struct {
            pub const NEEDED: u8 = 1 << 0;
            pub const REQUESTED: u8 = 1 << 1;
            pub const SERVICED: u8 = 1 << 2;
        };

        pub const NUM_CHANNELS = 4;

        pub const Channel = struct {
            control: u8 = 0,
            constant: u8 = 0,
            down_counter: u8 = 0,
            prescaler: u8 = 0,
            int_vector: u8 = 0,
            // helpers
            tigger_edge: bool = false,
            waiting_for_trigger: bool = false,
            ext_trigger: bool = false,
            prescaler_mask: u8 = 0,
            irq_state: u8 = 0,
        };

        chn: [NUM_CHANNELS]Channel = [_]Channel{.{}} ** NUM_CHANNELS,

        pub inline fn getData(bus: Bus) u8 {
            return @truncate(bus >> P.DBUS[0]);
        }

        pub inline fn setData(bus: Bus, data: u8) Bus {
            return (bus & ~DBUS) | (@as(Bus, data) << P.DBUS[0]);
        }
    };
}
