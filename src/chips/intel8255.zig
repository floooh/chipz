//! intel8255 -- emulates the Intel 8255 PPI Programmable Peripheral Interface chip
//!    EMULATED PINS:
//!
//!                  +-----------+
//!            CS -->|           |<-> PA0
//!            RD -->|           |...
//!            WR -->|   i8255   |<-> PA7
//!            A0 -->|           |
//!            A1 -->|           |<-> PB0
//!                  |           |...
//!            D0 <->|           |<-> PB7
//!               ...|           |
//!            D7 <->|           |<-> PC0
//!                  |           |...
//!                  |           |<-> PC7
//!                  +-----------+
//!
//!    NOT IMPLEMENTED:
//!        - mode 1 (strobed input/output)
//!        - mode 2 (bi-directional bus)
//!        - interrupts
//!        - input latches

const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;

pub const Pins = struct {
    RD: comptime_int, // read
    WR: comptime_int, // write
    CS: comptime_int, // chip select
    DBUS: [8]comptime_int, // data bus
    ABUS: [2]comptime_int, // address bus
    PA: [8]comptime_int, // IO port A
    PB: [8]comptime_int, // IO port B
    PC: [8]comptime_int, // IO port B
};

/// default pin configuration (mainly useful for debugging)
pub const DefaultPins = Pins{
    .RD = 27, // Read from PPI, shared with Z80 RD
    .WR = 28, // Write to PPI, shared with Z80 WR
    .CS = 40, // Chip select, PPI responds to RD/WR when active
    .ABUS = .{ 0, 1 }, // Shared with Z80 lowest address bus pins
    .DBUS = .{ 16, 17, 18, 19, 20, 21, 22, 23 }, // Shared with Z80 data bus
    .PA = .{ 48, 49, 50, 51, 52, 53, 54, 55 },
    .PB = .{ 56, 57, 58, 59, 60, 61, 62, 63 },
    .PC = .{ 8, 9, 10, 11, 12, 13, 14, 15 },
};

/// comptime type configuration for i8255 PPI
pub const TypeConfig = struct {
    pins: Pins,
    bus: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    const Bus = cfg.bus;

    return struct {
        const Self = @This();

        // pin bit-masks
        pub const DBUS = maskm(Bus, &cfg.pins.DBUS);
        pub const D0 = mask(Bus, cfg.pins.D[0]);
        pub const D1 = mask(Bus, cfg.pins.D[1]);
        pub const D2 = mask(Bus, cfg.pins.D[2]);
        pub const D3 = mask(Bus, cfg.pins.D[3]);
        pub const D4 = mask(Bus, cfg.pins.D[4]);
        pub const D5 = mask(Bus, cfg.pins.D[5]);
        pub const D6 = mask(Bus, cfg.pins.D[6]);
        pub const D7 = mask(Bus, cfg.pins.D[7]);
        pub const ABUS = maskm(Bus, &cfg.pins.ABUS);
        pub const A0 = mask(Bus, cfg.pins.ABUS[0]);
        pub const A1 = mask(Bus, cfg.pins.ABUS[1]);
        pub const RD = mask(Bus, cfg.pins.RD);
        pub const WR = mask(Bus, cfg.pins.WR);
        pub const CS = mask(Bus, cfg.pins.CS);
        pub const PA = maskm(Bus, &cfg.pins.PA);
        pub const PA0 = mask(Bus, cfg.pins.PA[0]);
        pub const PA1 = mask(Bus, cfg.pins.PA[1]);
        pub const PA2 = mask(Bus, cfg.pins.PA[2]);
        pub const PA3 = mask(Bus, cfg.pins.PA[3]);
        pub const PA4 = mask(Bus, cfg.pins.PA[4]);
        pub const PA5 = mask(Bus, cfg.pins.PA[5]);
        pub const PA6 = mask(Bus, cfg.pins.PA[6]);
        pub const PA7 = mask(Bus, cfg.pins.PA[7]);
        pub const PB = maskm(Bus, &cfg.pins.PB);
        pub const PB0 = mask(Bus, cfg.pins.PB[0]);
        pub const PB1 = mask(Bus, cfg.pins.PB[1]);
        pub const PB2 = mask(Bus, cfg.pins.PB[2]);
        pub const PB3 = mask(Bus, cfg.pins.PB[3]);
        pub const PB4 = mask(Bus, cfg.pins.PB[4]);
        pub const PB5 = mask(Bus, cfg.pins.PB[5]);
        pub const PB6 = mask(Bus, cfg.pins.PB[6]);
        pub const PB7 = mask(Bus, cfg.pins.PB[7]);
        pub const PC = maskm(Bus, &cfg.pins.PC);
        pub const PC0 = mask(Bus, cfg.pins.PC[0]);
        pub const PC1 = mask(Bus, cfg.pins.PC[1]);
        pub const PC2 = mask(Bus, cfg.pins.PC[2]);
        pub const PC3 = mask(Bus, cfg.pins.PC[3]);
        pub const PC4 = mask(Bus, cfg.pins.PC[4]);
        pub const PC5 = mask(Bus, cfg.pins.PC[5]);
        pub const PC6 = mask(Bus, cfg.pins.PC[6]);
        pub const PC7 = mask(Bus, cfg.pins.PC[7]);

        /// POP port A and B indices
        pub const PORT = struct {
            pub const A = 0;
            pub const B = 1;
            pub const C = 2;
        };
        /// number of PIO ports
        pub const NUM_PORTS = 3;

        /// Control word bits
        ///
        /// MODE SELECT (bit 7: 1)
        ///
        /// | C7 | C6 | C5 | C4 | C3 | C2 | C1 | C0 |
        ///
        /// C0..C2: GROUP B control bits:
        ///     C0: port C (lower) in/out:  0=output, 1=input
        ///     C1: port B in/out:          0=output, 1=input
        ///     C2: mode select:            0=mode0 (basic in/out), 1=mode1 (strobed in/out)
        ///
        /// C3..C6: GROUP A control bits:
        ///     C3: port C (upper) in/out:  0=output, 1=input
        ///     C4: port A in/out:          0=output, 1=input
        ///     C5+C6: mode select:         00=mode0 (basic in/out)
        ///                                 01=mode1 (strobed in/out)
        ///                                 1x=mode2 (bi-directional bus)
        ///
        /// C7: 1 for 'mode select'
        ///
        /// INTERRUPT CONTROL (bit 7: 0)
        ///
        /// Interrupt handling is currently not implemented
        pub const CTRL = struct {
            pub const CONTROL: u8 = 1 << 7;
            pub const CONTROL_MODE: u8 = 1 << 7;
            pub const CONTROL_BIT: u8 = 0;

            // Port C lower input/output select
            pub const CLO: u8 = 1;
            pub const CLO_INPUT: u8 = 1;
            pub const CLO_OUTPUT: u8 = 0;

            // Port B input/output
            pub const B: u8 = 1 << 1;
            pub const B_INPUT: u8 = 1 << 1;
            pub const B_OUTPUT: u8 = 0;

            // Group B mode select
            pub const B_CLO_MODE: u8 = 1 << 2;
            pub const B_CLO_MODE0: u8 = 0;
            pub const B_CLO_MODE1: u8 = 1 << 2;

            // Port C upper input/output
            pub const CHI: u8 = 1 << 3;
            pub const CHI_INPUT: u8 = 1 << 3;
            pub const CHI_OUTPUT: u8 = 0;

            // Port A input/output
            pub const A: u8 = 1 << 4;
            pub const A_INPUT: u8 = 1 << 4;
            pub const A_OUTPUT: u8 = 0;

            // Group A mode select
            pub const A_CHI_MODE: u8 = (1 << 6) | (1 << 5);
            pub const A_CHI_MODE0: u8 = 0;
            pub const A_CHI_MODE1: u8 = 1 << 5;
            pub const A_CHI_MODE2: u8 = 1 << 6;

            // Set/reset bit for control bit
            pub const CTRL_BIT: u8 = 1 << 0;
            pub const CTRL_BIT_SET: u8 = 1 << 0;
            pub const CTRL_BIT_RESET: u8 = 0;

            // Reset state
            pub const RESET: u8 = CTRL.CONTROL_MODE | CTRL.CLO_INPUT | CTRL.CHI_INPUT | CTRL.B_INPUT | CTRL.A_INPUT;
        };

        pub const ABUS_MODE = struct {
            pub const PORT_A: u2 = 0;
            pub const PORT_B: u2 = 1;
            pub const PORT_C: u2 = 2;
            pub const CTRL: u2 = 3;
        };

        /// intel8255 PPI port state
        pub const Port = struct {
            output: u8 = 0, // data output register
        };

        ports: [NUM_PORTS]Port = [_]Port{.{}} ** NUM_PORTS,
        control: u8 = 0,
        reset_active: bool = false,

        /// Get data bus value
        pub inline fn getData(bus: Bus) u8 {
            return @truncate(bus >> cfg.pins.DBUS[0]);
        }

        /// Set data bus value
        pub inline fn setData(bus: Bus, data: u8) Bus {
            return (bus & ~DBUS) | (@as(Bus, data) << cfg.pins.DBUS[0]);
        }

        /// Get data ABUS value
        pub inline fn getABUS(bus: Bus) u2 {
            return @truncate(bus >> cfg.pins.ABUS[0]);
        }

        /// Set data ABUS value
        pub inline fn setABUS(bus: Bus, data: u2) Bus {
            return (bus & ~ABUS) | (@as(Bus, data) << cfg.pins.ABUS[0]);
        }

        /// Set PPI port pins value
        pub inline fn setPort(comptime port: comptime_int, bus: Bus, data: u8) Bus {
            return switch (port) {
                PORT.A => (bus & ~PA) | (@as(Bus, data) << cfg.pins.PA[0]),
                PORT.B => (bus & ~PB) | (@as(Bus, data) << cfg.pins.PB[0]),
                PORT.C => (bus & ~PC) | (@as(Bus, data) << cfg.pins.PC[0]),
                else => unreachable,
            };
        }

        /// Set PPI port C lower pins value
        pub inline fn setPortCLO(bus: Bus, data: u8) Bus {
            const port_data = getPort(PORT.C, bus);
            return setPort(PORT.C, bus, (data & 0x0f) | (port_data & 0xf0));
        }

        /// Set PPI port C upper pins value
        pub inline fn setPortCHI(bus: Bus, data: u8) Bus {
            const port_data = getPort(PORT.C, bus);
            return setPort(PORT.C, bus, (data & 0xf0) | (port_data & 0x0f));
        }

        /// Get PPI port pins value
        pub inline fn getPort(comptime port: comptime_int, bus: Bus) u8 {
            return @truncate(bus >> switch (port) {
                PORT.A => cfg.pins.PA[0],
                PORT.B => cfg.pins.PB[0],
                PORT.C => cfg.pins.PC[0],
                else => unreachable,
            });
        }

        /// Get PPI port C lower pins value
        pub inline fn getPortCLO(bus: Bus) u8 {
            return getPort(PORT.C, bus) & 0x0f;
        }

        /// Get PPI port C upper pins value
        pub inline fn getPortCHI(bus: Bus) u8 {
            return getPort(PORT.C, bus) & 0xf0;
        }

        /// Return an initialized intel8255 PPI instance
        pub fn init() Self {
            var self: Self = .{};
            self.reset();
            return self;
        }

        /// Reset PPI instance
        pub fn reset(self: *Self) void {
            self.reset_active = true;
            self.control = CTRL.RESET;
            for (&self.ports) |*port| {
                port.output = 0;
            }
        }

        /// Execute one clock cycle
        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            if ((bus & CS) != 0) {
                if ((bus & RD) != 0) {
                    bus = self.read(bus);
                } else if ((bus & WR) != 0) {
                    self.write(bus);
                }
            }
            bus = self.write_ports(bus);
            return bus;
        }

        /// Write a value to the PPI
        pub fn write(self: *Self, bus: Bus) void {
            const data = getData(bus);
            switch (getABUS(bus)) {
                ABUS_MODE.PORT_A => {
                    // Write to port A
                    if ((self.control & CTRL.A) == CTRL.A_OUTPUT) {
                        self.ports[PORT.A].output = data;
                    }
                },
                ABUS_MODE.PORT_B => {
                    // Write to port B
                    if ((self.control & CTRL.B) == CTRL.B_OUTPUT) {
                        self.ports[PORT.B].output = data;
                    }
                },
                ABUS_MODE.PORT_C => {
                    // Write to port C
                    self.ports[PORT.C].output = data;
                },
                ABUS_MODE.CTRL => {
                    // Control operation
                    if ((data & CTRL.CONTROL) == CTRL.CONTROL_MODE) {
                        // Set port mode
                        self.control = data;
                        self.ports[PORT.A].output = 0;
                        self.ports[PORT.B].output = 0;
                        self.ports[PORT.C].output = 0;
                    } else {
                        // Set/clear single bit in port C
                        const bit: u3 = @truncate((data >> 1) & 0x07);
                        const port_mask: u8 = @as(u8, 1) << bit;
                        if ((data & CTRL.CTRL_BIT) == CTRL.CTRL_BIT_SET) {
                            self.ports[PORT.C].output |= port_mask;
                        } else {
                            self.ports[PORT.C].output &= ~port_mask;
                        }
                    }
                },
            }
        }

        // Read a value from the PPI
        fn read(self: *Self, bus: Bus) Bus {
            var data: u8 = 0xff;
            switch (getABUS(bus)) {
                ABUS_MODE.PORT_A => {
                    // Read from port A
                    if ((self.control & CTRL.A) == CTRL.A_OUTPUT) {
                        data = self.ports[PORT.A].output;
                    } else {
                        data = getPort(PORT.A, bus);
                    }
                },
                ABUS_MODE.PORT_B => {
                    // Read from port B
                    if ((self.control & CTRL.B) == CTRL.B_OUTPUT) {
                        data = self.ports[PORT.B].output;
                    } else {
                        data = getPort(PORT.B, bus);
                    }
                },
                ABUS_MODE.PORT_C => {
                    // Read from port C
                    data = getPort(PORT.C, bus);
                    if ((self.control & CTRL.CHI) == CTRL.CHI_OUTPUT) {
                        data = getPortCLO(bus) | (self.ports[PORT.C].output & 0xf0);
                    }
                    if ((self.control & CTRL.CLO) == CTRL.CLO_OUTPUT) {
                        data = getPortCHI(bus) | (self.ports[PORT.C].output & 0x0f);
                    }
                },
                ABUS_MODE.CTRL => {
                    // Read control word
                    data = self.control;
                },
            }
            return setData(bus, data);
        }

        // Write ports to bus
        fn write_ports(self: *Self, in_bus: Bus) Bus {
            self.reset_active = false;
            var bus = in_bus;
            if ((self.control & CTRL.A) == CTRL.A_OUTPUT) {
                bus = setPort(PORT.A, bus, self.ports[PORT.A].output);
            }
            if ((self.control & CTRL.B) == CTRL.B_OUTPUT) {
                bus = setPort(PORT.B, bus, self.ports[PORT.B].output);
            }
            if ((self.control & CTRL.CHI) == CTRL.CHI_OUTPUT) {
                bus = setPortCHI(bus, self.ports[PORT.C].output);
            }
            if ((self.control & CTRL.CLO) == CTRL.CLO_OUTPUT) {
                bus = setPortCLO(bus, self.ports[PORT.C].output);
            }
            return bus;
        }
    };
}
