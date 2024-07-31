//! Implements the Z80 interrupt request protocol in support chips like CTC and PIO
const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;

pub const Pins = struct {
    DBUS: [8]comptime_int,
    M1: comptime_int,
    IORQ: comptime_int,
    INT: comptime_int,
    RETI: comptime_int,
    IEIO: comptime_int,
};

pub const TypeConfig = struct {
    pins: Pins,
    bus: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    const Bus = cfg.bus;
    return struct {
        const Self = @This();

        // pin bit masks
        const DBUS = maskm(Bus, &cfg.pins.DBUS);
        const M1 = mask(Bus, cfg.pins.M1);
        const IORQ = mask(Bus, cfg.pins.IORQ);
        const INT = mask(Bus, cfg.pins.INT);
        const RETI = mask(Bus, cfg.pins.RETI);
        const IEIO = mask(Bus, cfg.pins.IEIO);

        const NEEDED: u8 = 1 << 0;
        const REQUESTED: u8 = 1 << 1;
        const SERVICED: u8 = 1 << 2;

        state: u8 = 0,
        vector: u8 = 0,

        inline fn setData(bus: Bus, data: u8) Bus {
            return (bus & ~DBUS) | (@as(Bus, data) << cfg.pins.DBUS[0]);
        }

        pub fn reset(self: *Self) void {
            self.state = 0;
        }

        pub fn request(self: *Self) void {
            self.state |= NEEDED;
        }

        pub fn clearRequest(self: *Self) void {
            self.state &= ~NEEDED;
        }

        pub fn setVector(self: *Self, v: u8) void {
            self.vector = v;
        }

        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;

            // on RETI, only the highest priority interrupt that's currently being
            // serviced resets its state so that IEIO enables interrupt handling
            // on downstream devices, this must be allowed to happen even if a higher
            // priority device has entered interrupt handling
            //
            if ((bus & RETI) != 0 and (self.state & SERVICED) != 0) {
                self.state &= ~SERVICED;
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
            if (self.state != 0 and (bus & IEIO) != 0) {
                // inhibit interrupt handling on downstream devices for the
                // entire duration of interrupt servicing
                bus &= ~IEIO;
                // set INT pint active until the CPU acknowledges the interrupt
                if ((self.state & NEEDED) != 0) {
                    self.state = (self.state & ~NEEDED) | REQUESTED;
                    bus |= INT;
                }
                // interrupt ackowledge from CPU (M1|IORQ): put interrupt vector
                // on data bus, clear INT pin and go into "serviced" state.
                if ((self.state & REQUESTED) != 0 and (bus & (M1 | IORQ)) == M1 | IORQ) {
                    self.state = (self.state & ~REQUESTED) | SERVICED;
                    bus = setData(bus, self.vector) & ~INT;
                }
            }
            return bus;
        }
    };
}
