//! AY-3-8910/2/3 sound chip emulator
//! FIXME: AY-3-8913 chip select pin is not emulated, instead the AY-3-8913
//! is simply a AY-3-8910 without IO ports
const bitutils = @import("common").bitutils;
const mask = bitutils.mask;
const maskm = bitutils.maskm;

/// map chip pin names to bit positions
///
/// NOTE: the BC2 pin is not emulated since it is usually
/// set to active when not connected to a CP1610 processor.
/// The remaining BDIR/BC1 pins are interpreted as follows:
///
///    |BDIR|BC1|
///    +----+---+
///    |  0 | 0 |  INACTIVE
///    |  0 | 1 |  READ FROM PSG
///    |  1 | 0 |  WRITE TO PSG
///    |  1 | 1 |  LATCH ADDRESS
///
pub const Pins = struct {
    DBUS: [8]comptime_int, // data bus
    BDIR: comptime_int, // bus direction
    BC1: comptime_int, // bus control 1
    IOA: [8]comptime_int, // IO port A
    IOB: [8]comptime_int, // IO port B
};

pub const DefaultPins = Pins{
    .DBUS = .{ 0, 1, 2, 3, 4, 5, 6, 7 },
    .BDIR = 8,
    .BC1 = 9,
    .IOA = .{ 10, 11, 12, 13, 14, 15, 16, 17 },
    .IOB = .{ 17, 18, 19, 20, 21, 22, 23, 24 },
};

/// chip model
pub const Model = enum {
    AY38910, // both IO ports
    AY38912, // only IO port A
    AY38913, // no IO ports
};

pub const Config = struct {
    model: Model = .AY38910,
    pins: Pins,
    bus: type,
};

pub fn AY3891(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;

        pub const Options = struct {
            tick_hz: u32, // frequency at which the tick function will be called
            sound_hz: u32, // host sound frequency (number of samples per second)
            volume: f32 = 1.0, // output volume (0..1)
            chip_select: u4 = 0, // optional chip-select
        };

        // pin bit masks
        pub const DBUS = maskm(Bus, &cfg.pins.DBUS);
        pub const D0 = mask(Bus, cfg.pins.DBUS[0]);
        pub const D1 = mask(Bus, cfg.pins.DBUS[1]);
        pub const D2 = mask(Bus, cfg.pins.DBUS[2]);
        pub const D3 = mask(Bus, cfg.pins.DBUS[3]);
        pub const D4 = mask(Bus, cfg.pins.DBUS[4]);
        pub const D5 = mask(Bus, cfg.pins.DBUS[5]);
        pub const D6 = mask(Bus, cfg.pins.DBUS[6]);
        pub const D7 = mask(Bus, cfg.pins.DBUS[7]);
        pub const BDIR = mask(Bus, cfg.pins.BDIR);
        pub const BC1 = mask(Bus, cfg.pins.BC1);
        pub const IOA = maskm(Bus, &cfg.pins.IOA);
        pub const IOA0 = mask(Bus, cfg.pins.IOA[0]);
        pub const IOA1 = mask(Bus, cfg.pins.IOA[1]);
        pub const IOA2 = mask(Bus, cfg.pins.IOA[2]);
        pub const IOA3 = mask(Bus, cfg.pins.IOA[3]);
        pub const IOA4 = mask(Bus, cfg.pins.IOA[4]);
        pub const IOA5 = mask(Bus, cfg.pins.IOA[5]);
        pub const IOA6 = mask(Bus, cfg.pins.IOA[6]);
        pub const IOB = maskm(Bus, &cfg.pins.IOB);
        pub const IOB0 = mask(Bus, cfg.pins.IOB[0]);
        pub const IOB1 = mask(Bus, cfg.pins.IOB[1]);
        pub const IOB2 = mask(Bus, cfg.pins.IOB[2]);
        pub const IOB3 = mask(Bus, cfg.pins.IOB[3]);
        pub const IOB4 = mask(Bus, cfg.pins.IOB[4]);
        pub const IOB5 = mask(Bus, cfg.pins.IOB[5]);
        pub const IOB6 = mask(Bus, cfg.pins.IOB[6]);

        // misc constants
        const NUM_CHANNELS = 3;
        const FIXEDPOINT_SCALE = 16; // error accumulation precision boost
        const DCADJ_BUFLEN = 128;

        // registers
        pub const REG = struct {
            pub const PERIOD_A_FINE: u4 = 0;
            pub const PERIOD_A_COARSE: u4 = 1;
            pub const PERIOD_B_FINE: u4 = 2;
            pub const PERIOD_B_COARSE: u4 = 3;
            pub const PERIOD_C_FINE: u4 = 4;
            pub const PERIOD_C_COARSE: u4 = 5;
            pub const PERIOD_NOISE: u4 = 6;
            pub const ENABLE: u4 = 7;
            pub const AMP_A: u4 = 8;
            pub const AMP_B: u4 = 9;
            pub const AMP_C: u4 = 10;
            pub const ENV_PERIOD_FINE: u4 = 11;
            pub const ENV_PERIOD_COARSE: u4 = 12;
            pub const ENV_SHAPE_CYCLE: u4 = 13;
            pub const IO_PORT_A: u4 = 14;
            pub const IO_PORT_B: u4 = 15;
            pub const NUM = 16;
        };

        // register bit widths
        const REGMASK = [REG.NUM]u8{
            0xFF, // REG.PERIOD_A_FINE
            0x0F, // REG.PERIOD_A_COARSE
            0xFF, // REG.PERIOD_B_FINE
            0x0F, // REG.PERIOD_B_COARSE
            0xFF, // REG.PERIOD_C_FINE
            0x0F, // REG.PERIOD_C_COARSE
            0x1F, // REG.PERIOD_NOISE
            0xFF, // REG.ENABLE,
            0x1F, // REG.AMP_A (0..3: 4-bit volume, 4: use envelope)
            0x1F, // REG.AMP_B (^^^)
            0x1F, // REG.AMP_C (^^^)
            0xFF, // REG.ENV_PERIOD_FINE
            0xFF, // REG.ENV_PERIOD_COARSE
            0x0F, // REG.ENV_SHAPE_CYCLE
            0xFF, // REG.IO_PORT_A
            0xFF, // REG.IO_PORT_B
        };

        // port names
        pub const Port = enum { A, B };

        // envelope shape bits
        pub const ENV = struct {
            pub const HOLD: u8 = (1 << 0);
            pub const ALTERNATE: u8 = (1 << 1);
            pub const ATTACK: u8 = (1 << 2);
            pub const CONTINUE: u8 = (1 << 3);
        };

        pub const Tone = struct {
            period: u16 = 0,
            counter: u16 = 0,
            phase: u1 = 0,
            tone_disable: u1 = 0,
            noise_disable: u1 = 0,
        };

        pub const Noise = struct {
            period: u16 = 0,
            counter: u16 = 0,
            rng: u32 = 0,
            phase: u1 = 0,
        };

        pub const Envelope = struct {
            period: u16 = 0,
            counter: u16 = 0,
            shape: struct {
                holding: bool = false,
                hold: bool = false,
                counter: u5 = 0,
                state: u4 = 0,
            } = .{},
        };

        pub const Sample = struct {
            period: i32 = 0,
            counter: i32 = 0,
            volume: f32 = 0.0,
            value: f32 = 0.0,
            ready: bool = false, // true if a new sample value is ready
            dcadj: struct {
                sum: f32 = 0.0,
                pos: u32 = 0.0,
                buf: [DCADJ_BUFLEN]f32 = [_]f32{0.0} ** DCADJ_BUFLEN,
            } = .{},
        };

        tick_count: u38 = 0, // tick counter for internal clock division
        cs_mask: u8 = 0, // hi: 4-bit chip-select (options.chip_select << 4)
        active: bool = false, // true if upper chip-select matches when writing address
        addr: u4 = 0, // current register index
        regs: [REG.NUM]u8 = [_]u8{0} ** REG.NUM,
        tone: [NUM_CHANNELS]Tone = [_]Tone{.{}} ** NUM_CHANNELS, // tone generator states (3 channels)
        noise: Noise = .{}, // noise generator state
        env: Envelope = .{}, // envelope generator state
        sample: Sample = .{}, // sample generator state

        pub inline fn getData(bus: Bus) u8 {
            return @truncate(bus >> cfg.pins.DBUS[0]);
        }

        pub inline fn setData(bus: Bus, data: u8) Bus {
            return (bus & ~DBUS) | (@as(Bus, data) << cfg.pins.DBUS[0]);
        }

        pub inline fn getPort(comptime port: Port, bus: Bus) u8 {
            return switch (port) {
                .A => @truncate(bus >> cfg.pins.IOA[0]),
                .B => @truncate(bus >> cfg.pins.IOB[0]),
            };
        }

        pub inline fn setPort(comptime port: Port, bus: Bus, data: u8) Bus {
            return switch (port) {
                .A => (bus & ~IOA) | (@as(Bus, data) << cfg.pins.IOA[0]),
                .B => (bus & ~IOB) | (@as(Bus, data) << cfg.pins.IOB[0]),
            };
        }

        pub inline fn setReg(self: *Self, comptime r: comptime_int, data: u8) void {
            self.regs[r] = data & REGMASK[r];
        }

        inline fn reg16(self: *const Self, comptime r_hi: comptime_int, comptime r_lo: comptime_int) u16 {
            return (@as(u16, self.regs[r_hi]) << 8) | self.regs[r_lo];
        }

        pub fn init(opts: Options) Self {
            const sample_period: i32 = @intCast(@divFloor(opts.tick_hz * FIXEDPOINT_SCALE, opts.sound_hz));
            var self = Self{
                .cs_mask = @as(u8, opts.chip_select) << 4,
                .noise = .{
                    .rng = 1,
                },
                .sample = .{
                    .period = sample_period,
                    .counter = sample_period,
                    .volume = opts.volume,
                },
            };
            self.updateValues();
            self.restartEnvelope();
            return self;
        }

        pub fn reset(self: *Self) void {
            self.active = false;
            self.addr = 0;
            self.tick_count = 0;
            for (&self.regs) |r| {
                r.* = 0;
            }
            self.updateValues();
            self.restartEnvelope();
        }

        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            // first check read/write access
            switch (bus & (BDIR | BC1)) {
                // latch register addr
                BDIR | BC1 => {
                    const data = getData(bus);
                    self.active = (data & 0xF0) == self.cs_mask;
                    if (self.active) {
                        self.addr = @truncate(data);
                    }
                },
                // write to register at latched addr (only if chip-select mask matches)
                BDIR => {
                    if (self.active) {
                        self.write(bus);
                    }
                },
                // read from register at latched addr (only if chip-select mask macthes)
                BC1 => {
                    if (self.active) {
                        bus = self.read(bus);
                    } else {
                        bus = setData(bus, 0xFF);
                    }
                },
                else => {},
            }
            // handle port IO
            if (cfg.model != .AY38913) {
                bus = self.portIO(bus);
            }

            // perform tick operations
            self.tick_count +%= 1;
            if ((self.tick_count & 7) == 0) {
                // tick tone channels
                for (&self.tone) |*chn| {
                    chn.counter +%= 1;
                    if (chn.counter >= chn.period) {
                        chn.counter = 0;
                        chn.phase ^= 1;
                    }
                }
                // tick the noise channel
                self.noise.counter +%= 1;
                if (self.noise.counter >= self.noise.period) {
                    self.noise.counter = 0;
                    // random number generator from MAME:
                    // https://github.com/mamedev/mame/blob/master/src/devices/sound/ay8910.cpp
                    // The Random Number Generator of the 8910 is a 17-bit shift
                    // register. The input to the shift register is bit0 XOR bit3
                    // (bit0 is the output). This was verified on AY-3-8910 and YM2149 chips.
                    self.noise.rng ^= ((self.noise.rng & 1) ^ ((self.noise.rng >> 3) & 1)) << 17;
                    self.noise.rng >>= 1;
                }
            }

            // tick the envelope generator
            if ((self.tick_count & 15) == 0) {
                self.env.counter +%= 1;
                if (self.env.counter >= self.env.period) {
                    self.env.period = 0;
                    if (!self.env.shape.holding) {
                        self.env.shape.counter +%= 1;
                        if (self.env.shape.hold and (0x1F == self.env.shape.counter)) {
                            self.env.shape.holding = true;
                        }
                    }
                }
                self.env.shape.state = env_shapes[self.regs[REG.ENV_SHAPE_CYCLE]][self.env.shape.counter];
            }

            // generate sample
            self.sample.counter -= FIXEDPOINT_SCALE;
            if (self.sample.counter <= 0) {
                self.sample.counter += self.sample.period;
                var sm: f32 = 0.0;
                inline for (&self.tone, .{ REG.AMP_A, REG.AMP_B, REG.AMP_C }) |chn, ampReg| {
                    const noise_enable: u1 = @truncate((self.noise.rng & 1) | chn.noise_disable);
                    const tone_enable: u1 = chn.phase | chn.tone_disable;
                    if ((tone_enable & noise_enable) != 0) {
                        const amp = self.regs[ampReg];
                        if (0 == (amp & (1 << 4))) {
                            // fixed amplitude
                            sm += volumes[amp & 0x0F];
                        } else {
                            // envelope control
                            sm += volumes[self.env.shape.state];
                        }
                    }
                }
                self.sample.value = dcadjust(self, sm) * self.sample.volume;
                self.sample.ready = true;
            } else {
                self.sample.ready = false;
            }
            return bus;
        }

        // DC adjustment filter from StSound, this moves an "offcenter"
        // signal back to the zero-line (e.g. the volume-level output
        // from the chip simulation which is >0.0 gets converted to
        //a +/- sample value)
        fn dcadjust(self: *Self, s: f32) f32 {
            const pos = self.sample.dcadj.pos;
            self.sample.dcadj.sum -= self.sample.dcadj.buf[pos];
            self.sample.dcadj.sum += s;
            self.sample.dcadj.buf[pos] = s;
            self.sample.dcadj.pos = (pos + 1) & (DCADJ_BUFLEN - 1);
            const div: f32 = @floatFromInt(DCADJ_BUFLEN);
            return s - (self.sample.dcadj.sum / div);
        }

        // write from data bus to register
        fn write(self: *Self, bus: Bus) void {
            const data = getData(bus);
            // update register content and dependent values
            self.regs[self.addr] = data & REGMASK[self.addr];
            self.updateValues();
            if (self.addr == REG.ENV_SHAPE_CYCLE) {
                self.restartEnvelope();
            }
        }

        // read from register to data bus
        fn read(self: *const Self, bus: Bus) Bus {
            return setData(bus, self.regs[self.addr]);
        }

        // handle IO ports
        fn portIO(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            // The bits 6 and 7 of the 'enable' register define whether
            // port A and B are in input or output mode. When in input mode,
            // the port bits are mirrored into the port A/B register, and
            // when in output mode the port A/B registers are mirrored on the port pins
            if (cfg.model != .AY38913) {
                // port A exists only on AY38910 and AY38912
                if ((self.regs[REG.ENABLE] & (1 << 6)) != 0) {
                    // port A is in output mode
                    bus = setPort(.A, bus, self.regs[REG.IO_PORT_A]);
                } else {
                    // port A is in input mode
                    self.setReg(REG.IO_PORT_A, getPort(.A, bus));
                }
            }
            if (cfg.model == .AY38910) {
                // port B exists only on AY38910
                if ((self.regs[REG.ENABLE] & (1 << 7)) != 0) {
                    // port B is in output mode
                    bus = setPort(.B, bus, self.regs[REG.IO_PORT_B]);
                } else {
                    // port B is in input mode
                    self.setReg(REG.IO_PORT_B, getPort(.B, bus));
                }
            }
            return bus;
        }

        // called after register values change
        fn updateValues(self: *Self) void {
            // update tone generator values...
            inline for (&self.tone, 0..) |*chn, i| {
                // "...Note also that due to the design technique used in the Tone Period
                // count-down, the lowest period value is 000000000001 (divide by 1)
                // and the highest period value is 111111111111 (divide by 4095)
                chn.period = self.reg16(2 * i + 1, 2 * i);
                if (chn.period == 0) {
                    chn.period = 1;
                }
                // a set 'enabled bit' actually means 'disabled'
                chn.tone_disable = @truncate((self.regs[REG.ENABLE] >> i) & 1);
                chn.noise_disable = @truncate((self.regs[REG.ENABLE] >> (3 + i)) & 1);
            }
            // update noise generator values
            self.noise.period = self.regs[REG.PERIOD_NOISE];
            if (self.noise.period == 0) {
                self.noise.period = 1;
            }
            // update envelope generator values
            self.env.period = self.reg16(REG.ENV_PERIOD_COARSE, REG.ENV_PERIOD_FINE);
            if (self.env.period == 0) {
                self.env.period = 1;
            }
        }

        // restart envelope shape generator, only called when env-shape register is updated
        fn restartEnvelope(self: *Self) void {
            self.env.shape.holding = false;
            self.env.shape.counter = 0;
            const cycle = self.regs[REG.ENV_SHAPE_CYCLE];
            self.env.shape.hold = 0 == (cycle & ENV.CONTINUE) and 0 != (cycle & ENV.HOLD);
        }

        // volume table from: https://github.com/true-grue/ayumi/blob/master/ayumi.c
        const volumes = [16]f32{
            0.0,
            0.00999465934234,
            0.0144502937362,
            0.0210574502174,
            0.0307011520562,
            0.0455481803616,
            0.0644998855573,
            0.107362478065,
            0.126588845655,
            0.20498970016,
            0.292210269322,
            0.372838941024,
            0.492530708782,
            0.635324635691,
            0.805584802014,
            1.0,
        };

        // canned envelope generator shapes
        const env_shapes = [16][32]u4{
            // CONTINUE ATTACK ALTERNATE HOLD
            // 0 0 X X
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            // 0 1 X X
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            // 1 0 0 0
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
            // 1 0 0 1
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            // 1 0 1 0
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
            // 1 0 1 1
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 },
            // 1 1 0 0
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
            // 1 1 0 1
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 },
            // 1 1 1 0
            .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
            // 1 1 1 1
            .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        };
    };
}
