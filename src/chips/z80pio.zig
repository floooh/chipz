//! Z80 PIO emulation
const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;

/// Z80 PIO pin declarations
pub const Pins = struct {
    DBUS: [8]comptime_int,
    M1: comptime_int,
    IORQ: comptime_int,
    RD: comptime_int,
    INT: comptime_int,
    CE: comptime_int,
    BASEL: comptime_int,
    CDSEL: comptime_int,
    ARDY: comptime_int,
    BRDY: comptime_int,
    ASTB: comptime_int,
    BSTB: comptime_int,
    PA: [8]comptime_int,
    PB: [8]comptime_int,
    // virtual pins
    RETI: comptime_int,
    IEIO: comptime_int,
};

/// default pin configuration (mainly useful for debugging)
pub const DefaultPins = Pins{
    .DBUS = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .M1 = 8,
    .IORQ = 9,
    .RD = 10,
    .INT = 11,
    .CE = 12,
    .BASEL = 13,
    .CDSEL = 14,
    .ARDY = 15,
    .BRDY = 16,
    .ASTB = 17,
    .BSTB = 18,
    .PA = .{ 19, 20, 21, 22, 23, 24, 25, 26 },
    .PB = .{ 27, 28, 29, 30, 31, 32, 33, 34 },
    .RETI = 35,
    .IEIO = 36,
};

pub fn Z80PIO(comptime P: Pins, comptime Bus: anytype) type {
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
        pub const CE = mask(Bus, P.CE);
        pub const BASEL = mask(Bus, P.BASEL);
        pub const CDSEL = mask(Bus, P.CDSEL);
        pub const ARDY = mask(Bus, P.ARDY);
        pub const BRDY = mask(Bus, P.BRDY);
        pub const ASTB = mask(Bus, P.ASTB);
        pub const BSTB = mask(Bus, P.BSTB);
        pub const PA = maskm(Bus, &P.PA);
        pub const PA0 = mask(Bus, P.PA[0]);
        pub const PA1 = mask(Bus, P.PA[1]);
        pub const PA2 = mask(Bus, P.PA[2]);
        pub const PA3 = mask(Bus, P.PA[3]);
        pub const PA4 = mask(Bus, P.PA[4]);
        pub const PA5 = mask(Bus, P.PA[5]);
        pub const PA6 = mask(Bus, P.PA[6]);
        pub const PA7 = mask(Bus, P.PA[7]);
        pub const PB = maskm(Bus, &P.PB);
        pub const PB0 = mask(Bus, P.PB[0]);
        pub const PB1 = mask(Bus, P.PB[1]);
        pub const PB2 = mask(Bus, P.PB[2]);
        pub const PB3 = mask(Bus, P.PB[3]);
        pub const PB4 = mask(Bus, P.PB[4]);
        pub const PB5 = mask(Bus, P.PB[5]);
        pub const PB6 = mask(Bus, P.PB[6]);
        pub const PB7 = mask(Bus, P.PB[7]);
    };
}
