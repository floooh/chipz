//! Z80 CTC emulation
const assert = @import("std").debug.assert;
const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;
const z80irq = @import("z80irq.zig");

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

pub const Config = struct { pins: Pins, bus: type };

pub fn Type(comptime cfg: Config) type {
    assert(cfg.pins.CS[1] == cfg.pins.CS[0] + 1);
    assert(cfg.pins.ZCTO[1] == cfg.pins.ZCTO[0] + 1);
    assert(cfg.pins.ZCTO[2] == cfg.pins.ZCTO[1] + 1);

    const Bus = cfg.bus;
    const Z80IRQ = z80irq.Type(.{
        .pins = .{
            .DBUS = cfg.pins.DBUS,
            .M1 = cfg.pins.M1,
            .IORQ = cfg.pins.IORQ,
            .INT = cfg.pins.INT,
            .RETI = cfg.pins.RETI,
            .IEIO = cfg.pins.IEIO,
        },
        .bus = Bus,
    });

    return struct {
        const Self = @This();

        // pin bit masks
        pub const DBUS = maskm(Bus, &cfg.pins.DBUS);
        pub const D0 = mask(Bus, cfg.pins.D[0]);
        pub const D1 = mask(Bus, cfg.pins.D[1]);
        pub const D2 = mask(Bus, cfg.pins.D[2]);
        pub const D3 = mask(Bus, cfg.pins.D[3]);
        pub const D4 = mask(Bus, cfg.pins.D[4]);
        pub const D5 = mask(Bus, cfg.pins.D[5]);
        pub const D6 = mask(Bus, cfg.pins.D[6]);
        pub const D7 = mask(Bus, cfg.pins.D[7]);
        pub const M1 = mask(Bus, cfg.pins.M1);
        pub const IORQ = mask(Bus, cfg.pins.IORQ);
        pub const RD = mask(Bus, cfg.pins.RD);
        pub const INT = mask(Bus, cfg.pins.INT);
        pub const IEI = mask(Bus, cfg.pins.IEI);
        pub const IEO = mask(Bus, cfg.pins.IEO);
        pub const CE = mask(Bus, cfg.pins.CE);
        pub const CS = maskm(Bus, &cfg.pins.CS);
        pub const CS0 = mask(Bus, cfg.pins.CS[0]);
        pub const CS1 = mask(Bus, cfg.pins.CS[1]);
        pub const CLKTRG = maskm(Bus, &cfg.pins.CLKTRG);
        pub const CLKTRG0 = mask(Bus, cfg.pins.CLKTRG[0]);
        pub const CLKTRG1 = mask(Bus, cfg.pins.CLKTRG[1]);
        pub const CLKTRG2 = mask(Bus, cfg.pins.CLKTRG[2]);
        pub const CLKTRG3 = mask(Bus, cfg.pins.CLKTRG[3]);
        pub const ZCTO = maskm(Bus, &cfg.pins.ZCTO);
        pub const ZCTO0 = mask(Bus, cfg.pins.ZCTO[0]);
        pub const ZCTO1 = mask(Bus, cfg.pins.ZCTO[1]);
        pub const ZCTO2 = mask(Bus, cfg.pins.ZCTO[2]);
        pub const RETI = mask(Bus, cfg.pins.RETI);
        pub const IEIO = mask(Bus, cfg.pins.IEIO);

        // control register bits
        pub const CTRL = struct {
            pub const EI: u8 = 1 << 7; // 1: interrupts enabled, 0: interrupts disabled

            pub const MODE: u8 = 1 << 6; // 1: counter mode, 0: timer mode
            pub const MODE_COUNTER: u8 = MODE;
            pub const MODE_TIMER: u8 = 0;

            pub const PRESCALER: u8 = 1 << 5; // 1: prescaler 256, 0: prescaler 16
            pub const PRESCALER_256: u8 = PRESCALER;
            pub const PRESCALER_16: u8 = 0;

            pub const EDGE: u8 = 1 << 4; // 1: edge rising, 0: edge falling
            pub const EDGE_RISING: u8 = EDGE;
            pub const EDGE_FALLING: u8 = 0;

            pub const TRIGGER: u8 = 1 << 3; // 1: CLK/TRG pulse starts timer, 0: load constant starts timer
            pub const TRIGGER_WAIT: u8 = TRIGGER;
            pub const TRIGGER_AUTO: u8 = 0;

            pub const CONST_FOLLOWS: u8 = 1 << 2; // 1: time constant follows, 0: no time constant follows
            pub const RESET: u8 = 1 << 1; // 1: software reset, 0: continue operation
            pub const CONTROL: u8 = 1 << 0; // 1: control word, 0: vector
        };

        pub const NUM_CHANNELS = 4;

        pub const Channel = struct {
            control: u8 = 0,
            constant: u8 = 0,
            down_counter: u8 = 0,
            prescaler: u8 = 0,
            // helpers
            trigger_edge: bool = false,
            waiting_for_trigger: bool = false,
            ext_trigger: bool = false,
            prescaler_mask: u8 = 0,
            irq: Z80IRQ = .{},
        };

        chn: [NUM_CHANNELS]Channel = [_]Channel{.{}} ** NUM_CHANNELS,

        pub inline fn getData(bus: Bus) u8 {
            return @truncate(bus >> cfg.pins.DBUS[0]);
        }

        pub inline fn setData(bus: Bus, data: u8) Bus {
            return (bus & ~DBUS) | (@as(Bus, data) << cfg.pins.DBUS[0]);
        }

        pub fn init() Self {
            var self: Self = .{};
            self.reset();
            return self;
        }

        pub fn reset(self: *Self) void {
            for (&self.chn) |*chn| {
                chn.control = CTRL.RESET;
                chn.constant = 0;
                chn.down_counter = 0;
                chn.waiting_for_trigger = false;
                chn.trigger_edge = false;
                chn.prescaler_mask = 0x0F;
                chn.irq.reset();
            }
        }

        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            bus = self._tick(bus);
            switch (bus & (CE | IORQ | RD | M1)) {
                CE | IORQ | RD => bus = self.ioRead(bus),
                CE | IORQ => bus = self.ioWrite(bus),
                else => {},
            }
            bus = self.irq(bus);
            return bus;
        }

        fn ioRead(self: *const Self, bus: Bus) Bus {
            const chn_idx: usize = (bus >> cfg.pins.CS[0]) & 3;
            const data = self.chn[chn_idx].down_counter;
            return setData(bus, data);
        }

        fn ioWrite(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            const data = getData(bus);
            const chn_id: usize = (bus >> cfg.pins.CS[0]) & 3;
            var chn = &self.chn[chn_id];
            if ((chn.control & CTRL.CONST_FOLLOWS) != 0) {
                // timer constant following control word
                chn.control &= ~(CTRL.CONST_FOLLOWS | CTRL.RESET);
                chn.constant = data;
                if ((chn.control & CTRL.MODE) == CTRL.MODE_TIMER) {
                    if ((chn.control & CTRL.TRIGGER) == CTRL.TRIGGER_WAIT) {
                        chn.waiting_for_trigger = true;
                    } else {
                        chn.down_counter = chn.constant;
                    }
                } else {
                    chn.down_counter = chn.constant;
                }
            } else if ((data & CTRL.CONTROL) != 0) {
                // a control word
                const old_control = chn.control;
                chn.control = data;
                chn.trigger_edge = data & CTRL.EDGE == CTRL.EDGE_RISING;
                if ((chn.control & CTRL.PRESCALER) == CTRL.PRESCALER_16) {
                    chn.prescaler_mask = 0x0F;
                } else {
                    chn.prescaler_mask = 0xFF;
                }
                // changing the Trigger Slope triggers an 'active edge'
                if (((old_control ^ chn.control) & CTRL.EDGE) != 0) {
                    bus = activeEdge(chn, bus, chn_id);
                }
            } else {
                // the interrupt vector for the entire CTC must be written
                // to channel 0, the vectors for the following channels
                // are then computed from the base vector plus 2 bytes per channel
                if (0 == chn_id) {
                    for (0..NUM_CHANNELS) |i| {
                        self.chn[i].irq.setVector(@truncate((data & 0xF8) + 2 * i));
                    }
                }
            }
            return bus;
        }

        fn _tick(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus & ~(ZCTO0 | ZCTO1 | ZCTO2);
            for (&self.chn, 0..) |*chn, chn_id| {
                // check if externally triggered
                if (chn.waiting_for_trigger or (chn.control & CTRL.MODE) == CTRL.MODE_COUNTER) {
                    const trg = 0 != (bus & (CLKTRG0 << @truncate(chn_id)));
                    if (trg != chn.ext_trigger) {
                        chn.ext_trigger = trg;
                        // rising/falling edge trigger
                        if (chn.trigger_edge == trg) {
                            bus = activeEdge(chn, bus, chn_id);
                        }
                    }
                } else if ((chn.control & (CTRL.MODE | CTRL.RESET | CTRL.CONST_FOLLOWS)) == CTRL.MODE_TIMER) {
                    // handle timer mode down-counting
                    chn.prescaler -%= 1;
                    if (0 == (chn.prescaler & chn.prescaler_mask)) {
                        // prescaler has reached zero, tick the down-counter
                        chn.down_counter -%= 1;
                        if (0 == chn.down_counter) {
                            bus = counterZero(chn, bus, chn_id);
                        }
                    }
                }
            }
            return bus;
        }

        fn irq(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            inline for (&self.chn) |*chn| {
                bus = chn.irq.tick(bus);
            }
            return bus;
        }

        // Issue an 'active edge' on a channel, this happens when a CLKTRG pin
        // is triggered, or when reprogramming the Z80CTC_CTRL_EDGE control bit.
        //
        // This results in:
        // - if the channel is in timer mode and waiting for trigger,
        //   the waiting flag is cleared and timing starts
        // - if the channel is in counter mode, the counter decrements
        //
        fn activeEdge(chn: *Channel, in_bus: Bus, chn_id: usize) Bus {
            var bus = in_bus;
            if ((chn.control & CTRL.MODE) == CTRL.MODE_COUNTER) {
                // counter mode
                chn.down_counter -%= 1;
                if (0 == chn.down_counter) {
                    bus = counterZero(chn, bus, chn_id);
                }
            } else if (chn.waiting_for_trigger) {
                // timer mode and waiting for trigger?
                chn.waiting_for_trigger = false;
                chn.down_counter = chn.constant;
            }
            return bus;
        }

        // called when the downcounter reaches zero, request interrupt,
        // trigger ZCTO pin and reload downcounter
        //
        fn counterZero(chn: *Channel, in_bus: Bus, chn_id: usize) Bus {
            var bus = in_bus;
            // down counter has reached zero, trigger interrupt and ZCTO pin
            if ((chn.control & CTRL.EI) != 0) {
                chn.irq.request();
            }
            // last channel doesn't have a ZCTO pin
            if (chn_id < 3) {
                // set the zcto pin
                bus |= ZCTO0 << @truncate(chn_id);
            }
            // reload the down counter
            chn.down_counter = chn.constant;
            return bus;
        }
    };
}
