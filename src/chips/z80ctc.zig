//! Z80 CTC emulation
const assert = @import("std").debug.assert;
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
    assert(P.CS[1] == P.CS[0] + 1);
    assert(P.ZCTO[1] == P.ZCTO[0] + 1);
    assert(P.ZCTO[2] == P.ZCTO[1] + 1);

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

        pub const IRQ = struct {
            pub const INT_NEEDED: u8 = 1 << 0;
            pub const INT_REQUESTED: u8 = 1 << 1;
            pub const INT_SERVICED: u8 = 1 << 2;
        };

        pub const NUM_CHANNELS = 4;

        pub const Channel = struct {
            control: u8 = 0,
            constant: u8 = 0,
            down_counter: u8 = 0,
            prescaler: u8 = 0,
            int_vector: u8 = 0,
            // helpers
            trigger_edge: bool = false,
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
                chn.irq_state = 0;
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
            const chn_idx: usize = (bus >> P.CS[0]) & 3;
            const data = self.chn[chn_idx].down_counter;
            return setData(bus, data);
        }

        fn ioWrite(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            const data = getData(bus);
            const chn_id: usize = (bus >> P.CS[0]) & 3;
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
                        self.chn[i].int_vector = @truncate((data & 0xF8) + 2 * i);
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
            for (&self.chn) |*chn| {
                // on RETI, only the highest priority interrupt that's currently being
                // serviced resets its state so that IEIO enables interrupt handling
                // on downstream devices, this must be allowed to happen even if a higher
                // priority device has entered interrupt handling
                //
                if ((bus & RETI) != 0 and (chn.irq_state & IRQ.INT_SERVICED) != 0) {
                    chn.irq_state &= ~IRQ.INT_SERVICED;
                    bus &= ~RETI;
                }

                // Also see: https://github.com/floooh/emu-info/blob/master/z80/z80-interrupts.pdf
                //
                // Especially the timing Figure 7 and Figure 7 timing diagrams!
                //
                // - set status of IEO pin depending on IEI pin and current
                //   channel's interrupt request/acknowledge status, this
                //   'ripples' to the next channel and downstream interrupt
                //   controllers
                //
                // - the IEO pin will be set to inactive (interrupt disabled)
                //   when: (1) the IEI pin is inactive, or (2) the IEI pin is
                //   active and and an interrupt has been requested
                //
                // - if an interrupt has been requested but not ackowledged by
                //   the CPU because interrupts are disabled, the RETI state
                //   must be passed to downstream devices. If a RETI is
                //   received in the interrupt-requested state, the IEIO
                //   pin will be set to active, so that downstream devices
                //   get a chance to decode the RETI
                //
                // - NOT IMPLEMENTED: "All channels are inhibited from changing
                //   their interrupt request status when M1 is active - about two
                //   clock cycles earlier than IORQ".
                //
                if (chn.irq_state != 0 and (bus & IEIO) != 0) {
                    // inhibit interrupt handling on downstream devices for the
                    // entire duration of interrupt servicing
                    bus &= ~IEIO;
                    // set INT pint active until the CPU acknowledges the interrupt
                    if ((chn.irq_state & IRQ.INT_NEEDED) != 0) {
                        chn.irq_state = (chn.irq_state & ~IRQ.INT_NEEDED) | IRQ.INT_REQUESTED;
                        bus |= INT;
                    }
                    // interrupt ackowledge from CPU (M1|IORQ): put interrupt vector
                    // on data bus, clear INT pin and go into "serviced" state.
                    if ((chn.irq_state & IRQ.INT_REQUESTED) != 0 and (bus & (M1 | IORQ)) == M1 | IORQ) {
                        chn.irq_state = (chn.irq_state & ~IRQ.INT_REQUESTED) | IRQ.INT_SERVICED;
                        bus = setData(bus, chn.int_vector) & ~INT;
                    }
                }
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
                chn.irq_state |= IRQ.INT_NEEDED;
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
