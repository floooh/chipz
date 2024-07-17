//! Z80 PIO emulation
const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;
const Z80IRQ = @import("z80irq").Z80IRQ;

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

        pub const PORT = struct {
            pub const A = 0;
            pub const B = 1;
        };
        pub const NUM_PORTS = 2;

        // Operating Modes
        //
        // The operating mode of a port is established by writing a control word
        // to the PIO in the following format:
        //
        //  D7 D6 D5 D4 D3 D2 D1 D0
        // |M1|M0| x| x| 1| 1| 1| 1|
        //
        // D7,D6   are the mode word bits
        // D3..D0  set to 1111 to indicate 'Set Mode'
        //
        pub const MODE = struct {
            pub const OUTPUT: u2 = 0;
            pub const INPUT: u2 = 1;
            pub const BIDIRECTIONAL: u2 = 2;
            pub const BITCONTROL: u2 = 3;
        };

        // Interrupt control word bits.
        //
        //  D7 D6 D5 D4 D3 D2 D1 D0
        // |EI|AO|HL|MF| 0| 1| 1| 1|
        //
        // D7 (EI)             interrupt enabled (1=enabled, 0=disabled)
        // D6 (AND/OR)         logical operation during port monitoring (only Mode 3, AND=1, OR=0)
        // D5 (HIGH/LOW)       port data polarity during port monitoring (only Mode 3)
        // D4 (MASK FOLLOWS)   if set, the next control word are the port monitoring mask (only Mode 3)
        //
        // (*) if an interrupt is pending when the enable flag is set, it will then be
        //     enabled on the onto the CPU interrupt request line
        // (*) setting bit D4 during any mode of operation will cause any pending
        //     interrupt to be reset
        //
        // The interrupt enable flip-flop of a port may be set or reset
        // without modifying the rest of the interrupt control word
        // by the following command:
        //
        //  D7 D6 D5 D4 D3 D2 D1 D0
        // |EI| x| x| x| 0| 0| 1| 1|
        //
        pub const INTCTRL = struct {
            pub const EI: u8 = 1 << 7;
            pub const ANDOR: u8 = 1 << 6;
            pub const HILO: u8 = 1 << 5;
            pub const MASK_FOLLOWS: u8 = 1 << 4;
        };

        pub const Expect = enum {
            CTRL,
            IO_SELECT,
            INT_MASK,
        };

        pub const Port = struct {
            input: u8 = 0, // data input register
            output: u8 = 0, // data output register
            mode: u2 = 0, // 2-bit mode control register (MODE.*)
            io_select: u8 = 0, // input/output select register
            int_control: u8 = 0, // interrupt control word (INTCTRL.*)
            int_mask: u8 = 0, // interrupt control mask
            // helpers
            irq: Z80IRQ(P, Bus) = .{}, // interrupt daisy chain state
            int_enabled: bool = false, // definitive interrupt enabled flag
            expect: Expect = .CTRL, // expect control word, io_select or int_mask
            expect_io_select: bool = false, // next control word will be io_select
            expect_int_mask: bool = false, // next control word will be int_mask
            bctrl_match: bool = false, // bitcontrol logic equation result
        };

        ports: [NUM_PORTS]Port = [_]Port{.{}} ** NUM_PORTS,
        reset_active: bool = false,

        pub inline fn getData(bus: Bus) u8 {
            return @truncate(bus >> P.DBUS[0]);
        }

        pub inline fn setData(bus: Bus, data: u8) Bus {
            return (bus & ~DBUS) | (@as(Bus, data) << P.DBUS[0]);
        }

        pub inline fn setPort(bus: Bus, comptime port: usize, data: u8) Bus {
            return switch (port) {
                PORT.A => (bus & ~PA) | (@as(bus, data) << P.PA[0]),
                PORT.B => (bus & ~PB) | (@as(bus, data) << P.PB[0]),
                else => unreachable,
            };
        }

        pub inline fn getPort(bus: Bus, comptime port: usize) u8 {
            return @truncate(bus >> switch (port) {
                PORT.A => P.PA[0],
                PORT.B => P.PB[0],
            });
        }

        pub fn init() Self {
            var self: Self = .{};
            self.reset();
            return self;
        }

        pub fn reset(self: *Self) void {
            self.reset_active = false;
            for (&self.ports) |*port| {
                port.mode = MODE.INPUT;
                port.output = 0;
                port.io_select = 0;
                port.int_control &= ~INTCTRL.EI;
                port.int_mask = 0xFF;
                port.int_enabled = false;
                port.expect_int_mask = false;
                port.expect_io_select = false;
                port.bctrl_match = false;
                port.irq.reset();
            }
        }

        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            // - OUTPUT MODE: On CPU write, the bus data is written to the output
            //   register, and the ARDY/BRDY pins must be set until the ASTB/BSTB pins
            //   changes from active to inactive. Strobe active=>inactive also an INT
            //   if the interrupt enable flip-flop is set and this device has the
            //   highest priority.
            //
            // - INPUT MODE (FIXME): When ASTB/BSTB goes active, data is loaded into the port's
            //   input register. When ASTB/BSTB then goes from active to inactive, an
            //   INT is generated is interrupt enable is set and this is the highest
            //   priority interrupt device. ARDY/BRDY goes active on ASTB/BSTB going
            //   inactive, and remains active until the CPU reads the input data.
            //
            // - BIDIRECTIONAL MODE: FIXME
            //
            // - BIT MODE: no handshake pins (ARDY/BRDY, ASTB/BSTB) are used. A CPU write
            //   cycle latches the data into the output register. On a CPU read cycle,
            //   the data returned to the CPU will be composed of output register data
            //   from those port data lines assigned as outputs and input register data
            //   from those port data lines assigned as inputs. The input register will
            //   contain data which was present immediately prior to the falling edge of RD.
            //   An interrupt will be generated if interrupts from the port are enabled and
            //   the data on the port data lines satisfy the logical equation defined by
            //   the 8-bit mask and 2-bit mask control registers
            //

            // handle io requests
            const p = &self.ports[if ((bus & BASEL) != 0) PORT.A else PORT.B];
            switch (bus & (CE | IORQ | RD | M1 | CDSEL)) {
                CE | IORQ | RD | CDSEL => {
                    // read control word
                    bus = setData(bus, self.readCtrl());
                },
                CE | IORQ | RD => {
                    // read data
                    bus = setData(bus, readData(p));
                },
                CE | IORQ | CDSEL => {
                    // write control word
                    self.writeCtrl(p, getData(bus));
                },
                CE | IORQ => {
                    // write data
                    writeData(p, getData(bus));
                },
            }
            // read port bits into PIO
            self.readPorts(bus);
            // update port bits
            bus = self.setPortOutput(bus);
            // handle interrupt protocol
            bus = self.irq(bus);
            return bus;
        }
        // new control word received from CPU
        fn writeCtrl(self: *Self, p: *Port, data: u8) void {
            self.reset_active = false;
            switch (p.expect) {
                .IO_SELECT => {
                    // followup io-select mask
                    p.io_select = data;
                    p.int_enabled = (p.int_control & INTCTRL.EI) != 0;
                    p.expect = .CTRL;
                },
                .INT_MASK => {
                    // followup interrupt mask
                    p.int_mask = data;
                    p.int_enabled = (p.int_control & INTCTRL.EI) != 0;
                    p.expect = .CTRL;
                },
                .CTRL => {
                    const ctrl = data & 0x0F;
                    if ((ctrl & 1) == 0) {
                        // set interrupt vector
                        p.irq.setVector(data);
                        // according to MAME setting the interrupt vector
                        // also enables interrupts, but this doesn't seem to
                        // be mentioned in the spec
                        p.int_control |= INTCTRL.EI;
                        p.int_enabled = true;
                    } else if (ctrl == 0x0F) {
                        // set operating mode (MODE.*)
                        p.mode = @truncate(data >> 6);
                        if (p.mode == MODE.BITCONTROL) {
                            // next control word is the io-select mask
                            p.expect = .IO_SELECT;
                            // disable interrupt until io-select mask written
                            p.int_enabled = false;
                            p.bctrl_match = false;
                        }
                    } else if (ctrl == 0x07) {
                        // set interrupt control word (INTCTRL.*)
                        p.int_control = data & 0xF0;
                        if ((data & INTCTRL.MASK_FOLLOWS) != 0) {
                            // next control word is the interrupt control mask
                            p.expect = .INT_MASK;
                            // disable interrupt until mask is written
                            p.int_enabled = false;
                            // reset pending interrupt
                            p.irq.clearRequest();
                            p.bctrl_match = false;
                        } else {
                            p.int_enabled = (p.int_control & INTCTRL.EI) != 0;
                        }
                    } else if (ctrl == 0x03) {
                        // only set interrupt enable bit
                        p.int_control = (data & INTCTRL.EI) | (p.int_control & ~INTCTRL.EI);
                        p.int_enabled = (p.int_control & INTCTRL.EI) != 0;
                    }
                },
            }
        }

        // read control word back to CPU
        fn readCtrl(self: *const Self) u8 {
            // I haven't found documentation about what is
            // returned when reading the control word, this
            // is what MAME does
            return (self.ports[PORT.A].int_control & 0xC0) | (self.ports[PORT.B].int_control >> 4);
        }

        // new data word received from CPU
        fn writeData(p: *Port, data: u8) void {
            switch (p.mode) {
                MODE.OUTPUT, MODE.INPUT, MODE.BITCONTROL => p.output = data,
                MODE.BIDIRECTIONAL => {}, // FIXME
            }
        }

        // read port data back to CPU
        fn readData(p: *Port) u8 {
            return switch (p.mode) {
                MODE.OUTPUT => p.output,
                MODE.INPUT => p.input,
                MODE.BIDIRECTIONAL => 0xFF, // FIXME
                MODE.BITCONTROL => (p.input & p.io_select) | (p.output | ~p.io_select),
            };
        }

        // set port bits on the bus
        fn setPortOutput(self: *const Self, in_bus: Bus) Bus {
            var bus = in_bus; // autofix
            inline for (&self.ports, 0..) |*p, pid| {
                const data = switch (p.mode) {
                    MODE.OUTPUT => p.output,
                    MODE.INPIUT, MODE.BIDIRECTIONAL => 0xFF,
                    MODE.BITCONTROL => p.io_select | (p.output & ~p.io_select),
                };
                bus = setPort(pid, bus, data);
            }
            return bus;
        }

        // read port bits from bus
        fn readPorts(self: *Self, bus: Bus) void {
            inline for (&self.ports, 0..) |*p, pid| {
                const data = getPort(pid, bus);
                // this only needs to be evaluated if either the port input
                // or port state might have changed
                if ((data != p.input) or ((bus & CE) != 0)) {
                    switch (p.mode) {
                        MODE.INPUT => {
                            // FIXME: strobe/ready handshake and interrupt
                            p.input = data;
                        },
                        MODE.BITCONTROL => {
                            p.input = data;

                            // check interrupt condition
                            const imask = ~p.int_mask;
                            const val = ((p.input & p.io_select) | (p.output & ~p.io_select)) & imask;
                            const ictrl = p.int_control & 0x60;
                            const match = switch (ictrl) {
                                0 => val != imask,
                                0x20 => val != 0,
                                0x40 => val == 0,
                                0x60 => val == imask,
                                else => false,
                            };
                            if (!p.bctrl_match and match and p.int_enabled) {
                                p.irq.request();
                            }
                            p.bctrl_match = match;
                        },
                    }
                }
            }
        }

        fn irq(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            inline for (&self.ports) |*p| {
                bus = p.irq.tick(bus);
            }
            return bus;
        }
    };
}
