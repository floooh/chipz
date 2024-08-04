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
const keybuf = common.keybuf;
const pins = common.bitutils.pins;
const mask = common.bitutils.mask;
const maskm = common.bitutils.maskm;
const cp = common.utils.cp;
const audio = common.audio;
const fillNoise = common.utils.fillNoise;
const DisplayInfo = common.glue.DisplayInfo;
const Beeper = common.Beeper;

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
    .BASEL = CPU_PINS.ABUS[0], // BASEL pin is directly connected to A0
    .CDSEL = CPU_PINS.ABUS[1], // CDSEL pin is directly connected to A1
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
    .CS = .{ CPU_PINS.ABUS[0], CPU_PINS.ABUS[1] }, // CTC CS0/CS1 are directly connected to A0/A1
    .CLKTRG = .{ 52, 53, 54, 55 },
    .ZCTO = .{ 56, 57, 58 },
    .RETI = CPU_PINS.RETI,
    .IEIO = PIO_PINS.IEIO,
};

// KC85/4: IO84 and IO86 8-bit latches
const IO84_PINS = [8]comptime_int{ 80, 81, 82, 83, 84, 85, 86, 87 };
const IO86_PINS = [8]comptime_int{ 88, 89, 90, 91, 92, 93, 94, 95 };

// NOTE: 64 bits isn't enough for the system bus
const Bus = u128;
const Memory = memory.Type(.{ .page_size = 0x0400 });
const Z80 = z80.Type(.{ .pins = CPU_PINS, .bus = Bus });
const Z80PIO = z80pio.Type(.{ .pins = PIO_PINS, .bus = Bus });
const Z80CTC = z80ctc.Type(.{ .pins = CTC_PINS, .bus = Bus });
const KeyBuf = keybuf.Type(.{ .num_slots = 4 });
const Audio = audio.Type(.{ .num_voices = 2 });

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
            audio: Audio.Options,
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
        pub const IRM0_PAGE = 4;

        pub const DISPLAY = struct {
            pub const WIDTH = 320;
            pub const HEIGHT = 256;
            pub const FB_WIDTH = 512;
            pub const FB_HEIGHT = 256;
            pub const FB_SIZE = FB_WIDTH * FB_HEIGHT;
            pub const PALETTE = [_]u32{
                // 16 foreground colors
                0xFF000000, // black
                0xFFFF0000, // blue
                0xFF0000FF, // red
                0xFFFF00FF, // magenta
                0xFF00FF00, // green
                0xFFFFFF00, // cyan
                0xFF00FFFF, // yellow
                0xFFFFFFFF, // white
                0xFF000000, // black #2
                0xFFFF00A0, // violet
                0xFF00A0FF, // orange
                0xFFA000FF, // purple
                0xFFA0FF00, // blueish green
                0xFFFFA000, // greenish blue
                0xFF00FFA0, // yellow-green
                0xFFFFFFFF, // white #2
                // 8 background colors
                0xFF000000, // black
                0xFFA00000, // dark-blue
                0xFF0000A0, // dark-red
                0xFFA000A0, // dark-magenta
                0xFF00A000, // dark-green
                0xFFA0A000, // dark-cyan
                0xFF00A0A0, // dark-yellow
                0xFFA0A0A0, // gray
                // padding to get next block at 2^N
                0xFFFF00FF,
                0xFFFF00FF,
                0xFFFF00FF,
                0xFFFF00FF,
                0xFFFF00FF,
                0xFFFF00FF,
                0xFFFF00FF,
                0xFFFF00FF,
                // KC85/4 only: 4 extra HICOLOR colors
                0xFF000000, // black
                0xFF0000FF, // red
                0xFFFFFF00, // cyan
                0xFFFFFFFF, // white
            };
        };

        // general IO address decoding mask and pins
        const IO = struct {
            const MASK = Z80.M1 | Z80.IORQ | Z80.A7 | Z80.A6 | Z80.A5 | Z80.A4;
            const PINS = Z80.IORQ | Z80.A7;
        };

        // PIO output pins
        pub const PIO = struct {
            pub const CAOS_ROM = Z80PIO.PA0;
            pub const RAM = Z80PIO.PA1;
            pub const IRM = Z80PIO.PA2;
            pub const RAM_RO = Z80PIO.PA3;
            pub const NMI = Z80PIO.PA4; // KC85/2,/3 only
            pub const TAPE_LED = Z80PIO.PA5;
            pub const TAPE_MOTOR = Z80PIO.PA6;
            pub const BASIC_ROM = Z80PIO.PA7;
            pub const RAM8 = Z80PIO.PB5;
            pub const RAM8_RO = Z80PIO.PB6;
            pub const BLINK_ENABLED = Z80PIO.PB7;

            // IO bits which affect memory mapping
            pub const MEMORY_BITS = CAOS_ROM | RAM | IRM | RAM_RO | BASIC_ROM | RAM8 | RAM8_RO;

            // chip-enable mask and pins
            pub const CE_MASK = IO.MASK | Z80.A3 | Z80.A2;
            pub const CE_PINS = IO.PINS | Z80.A3;
        };

        // CTC output pins
        pub const CTC = struct {
            pub const BEEPER1 = Z80CTC.ZCTO0;
            pub const BEEPER2 = Z80CTC.ZCTO1;
            pub const BLINK = Z80CTC.ZCTO2;

            // chip-enable mask and pins
            pub const CE_MASK = IO.MASK | Z80.A3 | Z80.A2;
            pub const CE_PINS = IO.PINS | Z80.A3 | Z80.A2;
        };

        // KC85/4 IO address 0x84 latch
        pub const IO84 = struct {
            // virtual pin masks
            pub const P = maskm(Bus, &IO84_PINS);
            pub const P0 = mask(Bus, IO84_PINS[0]);
            pub const P1 = mask(Bus, IO84_PINS[1]);
            pub const P2 = mask(Bus, IO84_PINS[2]);
            pub const P3 = mask(Bus, IO84_PINS[3]);
            pub const P4 = mask(Bus, IO84_PINS[4]);
            pub const P5 = mask(Bus, IO84_PINS[5]);
            pub const P6 = mask(Bus, IO84_PINS[6]);
            pub const P7 = mask(Bus, IO84_PINS[7]);

            pub const SEL_VIEW_IMG = P0; // 0: display img0, 1: display img1
            pub const SEL_CPU_COLOR = P1; // 0: access pixels, 1: access colors
            pub const SEL_CPU_IMG = P2; // 0: access img 0, 1: access img 1
            pub const HICOLOR = P3; // 0: hicolor mode off, 1: hicolor mode on
            pub const SEL_RAM8 = P4; // select RAM8 block 0 or 1

            // latch bits which affect memory mapping
            pub const MEMORY_BITS = SEL_CPU_COLOR | SEL_CPU_IMG | SEL_RAM8;

            // IO enable mask and pins (write-only)
            pub const SEL_MASK = IO.MASK | Z80.WR | Z80.A3 | Z80.A2 | Z80.A1 | Z80.A0;
            pub const SEL_PINS = IO.PINS | Z80.WR | Z80.A2;

            pub inline fn set(bus: Bus, data: u8) Bus {
                return (bus & ~P) | (@as(Bus, data) << IO84_PINS[0]);
            }
        };

        // KC85/4 IO address 0x86 latch
        pub const IO86 = struct {
            // virtual pin masks
            pub const P = maskm(Bus, &IO86_PINS);
            pub const P0 = mask(Bus, IO86_PINS[0]);
            pub const P1 = mask(Bus, IO86_PINS[1]);
            pub const P2 = mask(Bus, IO86_PINS[2]);
            pub const P3 = mask(Bus, IO86_PINS[3]);
            pub const P4 = mask(Bus, IO86_PINS[4]);
            pub const P5 = mask(Bus, IO86_PINS[5]);
            pub const P6 = mask(Bus, IO86_PINS[6]);
            pub const P7 = mask(Bus, IO86_PINS[7]);

            pub const RAM4 = P0;
            pub const RAM4_RO = P1;
            pub const CAOS_ROM_C = P7;

            // latch bits which affect memory mapping
            pub const MEMORY_BITS = RAM4 | RAM4_RO | CAOS_ROM_C;

            // IO enable mask and pins (write only)
            pub const SEL_MASK = IO.MASK | Z80.WR | Z80.A3 | Z80.A2 | Z80.A1 | Z80.A0;
            pub const SEL_PINS = IO.PINS | Z80.WR | Z80.A2 | Z80.A1;

            pub inline fn set(bus: Bus, data: u8) Bus {
                return (bus & ~P) | (@as(Bus, data) << IO86_PINS[0]);
            }
        };

        // keyboard handler flags
        pub const KBD = struct {
            pub const TIMEOUT: u8 = 1 << 3;
            pub const KEYREADY: u8 = 1 << 0;
            pub const REPEAT: u8 = 1 << 4;
            pub const SHORT_REPEAT_COUNT = 8;
            pub const LONG_REPEAR_COUNT = 60;
        };

        // expansion system constant
        pub const EXP = struct {
            pub const NUM_SLOTS = 2; // number of expansion slots in the base device
            pub const BUF_SIZE = NUM_SLOTS * 64 * 1024; // expansion system buffer size (64 KB per slot)

            // IO enable mask and pins
            pub const MASK = IO.MASK | Z80.A3 | Z80.A2 | Z80.A1 | Z80.A0;
            pub const PINS = IO.PINS | Z80.A2 | Z80.A1;
        };

        pub const ALL_MEMORY_BITS = PIO.MEMORY_BITS | if (model == .KC854) IO84.MEMORY_BITS | IO86.MEMORY_BITS else 0;

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

        // expansion module state
        pub const Module = struct {
            mod_type: ModuleType = .NONE,
            id: u8 = 0,
            writable: bool = false,
            addr_mask: u8 = 0,
            size: u32 = 0,
        };

        // expansion system slot
        pub const Slot = struct {
            addr: u8, // 0x0C (left slot) or 0x08 (right slot)
            ctrl: u8 = 0, // current control byte
            buf_offset: u32 = 0, // byte offset in expansion system memory buffer
            mod: Module = .{}, // currently inserted module
        };

        // KC85 expansion system state
        pub const Exp = struct {
            slot: [EXP.NUM_SLOTS]Slot = .{
                .{ .addr = 0x0C },
                .{ .addr = 0x08 },
            },
            buf_top: u32 = 0,
        };

        pub const Rom = switch (model) {
            .KC852 => struct {
                caos_e: [0x2000]u8, // 8 KB CAOS ROM at 0xE000,
            },
            .KC853 => struct {
                basic: [0x2000]u8, // 8 KB BASIC ROM at 0xC000
                caos_e: [0x2000]u8, // 8 KB CAOS ROM at 0xE000
            },
            .KC854 => struct {
                basic: [0x2000]u8, // 8 KB BASIC ROM at 0xC000
                caos_c: [0x1000]u8, // 4 KB CAOS ROM at 0xC000
                caos_e: [0x2000]u8, // 8 KB CAOS ROM at 0xE000
            },
        };

        // KC85 emulator state
        bus: Bus = 0,
        cpu: Z80,
        pio: Z80PIO,
        ctc: Z80CTC,
        video: struct {
            h_tick: u16 = 0,
            v_count: u16 = 0,
        } = .{},
        flip_flops: Bus = 0,
        mem_mapping: Bus = 0,
        beeper: [2]Beeper,
        mem: Memory,
        key_buf: KeyBuf,
        exp: Exp = .{},

        // memory buffers
        ram: [8][0x4000]u8,
        rom: Rom,
        audio: Audio,
        ext_buf: [EXP.BUF_SIZE]u8,
        fb: [DISPLAY.FB_SIZE]u8 align(128),
        junk_page: [Memory.PAGE_SIZE]u8,
        unmapped_page: [Memory.PAGE_SIZE]u8,

        pub fn initInPlace(self: *Self, opts: Options) void {
            const beeper_opts: Beeper.Options = .{
                .tick_hz = FREQUENCY,
                .sound_hz = @intCast(opts.audio.sample_rate),
            };
            self.* = .{
                // init PIO port pins to high
                .bus = Z80PIO.setPort(0, 0, 0xFF) | Z80PIO.setPort(1, 0, 0xFF),
                .cpu = Z80.init(),
                .pio = Z80PIO.init(),
                .ctc = Z80CTC.init(),
                .beeper = .{ Beeper.init(beeper_opts), Beeper.init(beeper_opts) },
                .mem = Memory.init(.{
                    .junk_page = &self.junk_page,
                    .unmapped_page = &self.unmapped_page,
                }),
                .key_buf = KeyBuf.init(.{
                    // let keys stick for 2 PAL frames
                    .sticky_time = 2 * (1000 / 50) * 1000,
                }),
                .ram = init: {
                    var arr: [8][0x4000]u8 = undefined;
                    if (model == .KC854) {
                        // on KC85/4, RAM is filled with zeroes
                        arr = std.mem.zeroes(@TypeOf(self.ram));
                    } else {
                        // on KC85/2, /3 RAM is filled with noise
                        var x: u32 = 0x6D98302B; // seed for xorshift32
                        inline for (0..8) |i| {
                            x = fillNoise(&arr[i], x);
                        }
                    }
                    break :init arr;
                },
                .rom = initRoms(opts),
                .audio = Audio.init(opts.audio),
                .ext_buf = std.mem.zeroes(@TypeOf(self.ext_buf)),
                .fb = std.mem.zeroes(@TypeOf(self.fb)),
                .junk_page = std.mem.zeroes(@TypeOf(self.junk_page)),
                .unmapped_page = [_]u8{0xFF} ** Memory.PAGE_SIZE,
            };
            // initial memory map
            self.updateMemoryMap(self.bus);
            // execution starts at address 0xF000
            self.cpu.prefetch(0xF000);
        }

        pub fn reset(self: *Self) void {
            _ = self; // autofix
            @panic("FIXME: kc85.reset");
        }

        pub fn exec(self: *Self, micro_seconds: u32) u32 {
            const num_ticks = clock.microSecondsToTicks(FREQUENCY, micro_seconds);
            var bus = self.bus;
            for (0..num_ticks) |_| {
                bus = self.tick(bus);
            }
            self.bus = bus;
            self.updateKeyboard(micro_seconds);
            return num_ticks;
        }

        pub fn tick(self: *Self, in_bus: Bus) Bus {
            // tick CPU and memory access
            var bus = self.cpu.tick(in_bus);
            const addr = getAddr(bus);
            if ((bus & MREQ) != 0) {
                if ((bus & RD) != 0) {
                    bus = setData(bus, self.mem.rd(addr));
                } else if ((bus & WR) != 0) {
                    self.mem.wr(addr, getData(bus));
                }
            }

            // tick video system (may set CTC CLKTRG0..3)
            bus = self.tickVideo(bus);

            // IO address decoding
            bus = (bus & ~(Z80CTC.CE | Z80PIO.CE | Z80.NMI)) | Z80CTC.IEIO;
            if ((bus & CTC.CE_MASK) == CTC.CE_PINS) {
                bus |= Z80CTC.CE;
            }
            if ((bus & PIO.CE_MASK) == PIO.CE_PINS) {
                bus |= Z80PIO.CE;
            }

            // tick the CTC and PIO
            bus = self.ctc.tick(bus);
            bus = self.pio.tick(bus);
            self.flip_flops ^= bus;

            // tick beepers
            self.beeper[0].set((self.flip_flops & CTC.BEEPER1) != 0);
            self.beeper[1].set((self.flip_flops & CTC.BEEPER2) != 0);
            _ = self.beeper[0].tick();
            if (self.beeper[1].tick()) {
                // new audio sample ready
                self.audio.put(self.beeper[0].sample.out + self.beeper[1].sample.out);
            }

            // PIO output
            if (model == .KC854) {
                @panic("FIXME: KC85/4 PIO output");
            } else {
                // on KC85/2 and /3, PA4 is connected to NMI
                if ((bus & PIO.NMI) == 0) {
                    bus |= Z80.NMI;
                }
            }

            // KC85/4 IO latch 0x84 and 0x86
            if (model == .KC854) {
                if ((bus & IO84.SEL_MASK) == IO84.SEL_PINS) {
                    bus = IO84.set(bus, getData(bus));
                }
                if ((bus & IO86.SEL_MASK) == IO86.SEL_PINS) {
                    bus = IO86.set(bus, getData(bus));
                }
            }

            // update memory mapping if needed
            const mem_mapping_changed = (self.mem_mapping ^ bus) & ALL_MEMORY_BITS;
            if (mem_mapping_changed != 0) {
                self.updateMemoryMap(bus);
            }
            return bus;
        }

        pub fn displayInfo(selfOrNull: ?*const Self) DisplayInfo {
            return .{
                .fb = .{
                    .dim = .{
                        .width = DISPLAY.FB_WIDTH,
                        .height = DISPLAY.FB_HEIGHT,
                    },
                    .buffer = if (selfOrNull) |self| .{ .Palette8 = &self.fb } else null,
                },
                .view = .{
                    .x = 0,
                    .y = 0,
                    .width = DISPLAY.WIDTH,
                    .height = DISPLAY.HEIGHT,
                },
                .palette = &DISPLAY.PALETTE,
                .orientation = .Landscape,
            };
        }

        pub fn keyDown(self: *Self, key_code: u32) void {
            self.key_buf.keyDown(key_code, 0);
        }

        pub fn keyUp(self: *Self, key_code: u32) void {
            self.key_buf.keyUp(key_code);
        }

        fn tickVideo(self: *Self, bus: Bus) Bus {
            // every 2 CPU ticks, 8 pixels are decoded
            if ((self.video.h_tick & 1) != 0) {
                const x: u16 = self.video.h_tick >> 1;
                const y: u16 = self.video.v_count;
                if ((y < 256) and (x < 40)) {
                    if (model == .KC854) {
                        @panic("FIXME: KC85/4 video decoding");
                    } else {
                        // KC85/2 and KC85/3 pixel decoding
                        const pixel_offset, const color_offset = if ((x & 0x20) == 0) .{
                            // left 256x256 area
                            x | (((y >> 2) & 0x3) << 5) | ((y & 0x3) << 7) | (((y >> 4) & 0xF) << 9),
                            0x2800 + (x | (((y >> 2) & 0x3f) << 5)),
                        } else .{
                            // right 64x256 area
                            0x2000 + ((x & 0x7) | (((y >> 4) & 0x3) << 3) | (((y >> 2) & 0x3) << 5) | ((y & 0x3) << 7) | (((y >> 6) & 0x3) << 9)),
                            0x3000 + ((x & 0x7) | (((y >> 4) & 0x3) << 3) | (((y >> 2) & 0x3) << 5) | (((y >> 6) & 0x3) << 7)),
                        };
                        // FIXME: optionally implement display needling
                        const color_bits = self.ram[IRM0_PAGE][color_offset];
                        const fg_blank = blinkState(color_bits, self.flip_flops, bus);
                        const pixel_bits = if (fg_blank) 0 else self.ram[IRM0_PAGE][pixel_offset];
                        self.decode8Pixels(x, y, pixel_bits, color_bits);
                    }
                }
            }
            return self.updateRasterCounters(bus);
        }

        inline fn blinkState(color_bits: u8, flip_flops: Bus, bus: Bus) bool {
            return (color_bits & (1 << 7) != 0) and (flip_flops & CTC.BLINK != 0) and (bus & PIO.BLINK_ENABLED != 0);
        }

        inline fn decode8Pixels(self: *Self, x: usize, y: usize, pixel_bits: u8, color_bits: u8) void {
            assert((x < 40) and (y < 256));
            const off: usize = y * DISPLAY.FB_WIDTH + x * 8;
            const bg = 0x10 | (color_bits & 0x07); // background color
            const fg = (color_bits >> 3) & 0x0F; // foreground color
            inline for (0..8) |i| {
                self.fb[off + i] = if ((pixel_bits & (0x80 >> i)) != 0) fg else bg;
            }
        }

        inline fn updateRasterCounters(self: *Self, in_bus: Bus) Bus {
            var bus = in_bus;
            self.video.h_tick +%= 1;
            // feed '_h4' into CTC CLKTRG0 and 1, per scanline:
            //   0..31 ticks lo
            //  32..63 ticks hi
            //  64..95 ticks lo
            //  remainder: hi
            if ((self.video.h_tick & 0x20) != 0) {
                bus |= Z80CTC.CLKTRG0 | Z80CTC.CLKTRG1;
            } else {
                bus &= ~(Z80CTC.CLKTRG0 | Z80CTC.CLKTRG1);
            }
            // vertical blanking interval (/BI) active for the last 56 scanlines
            if ((self.video.v_count & 0x100) != 0) {
                bus |= Z80CTC.CLKTRG2 | Z80CTC.CLKTRG3;
            } else {
                bus &= ~(Z80CTC.CLKTRG2 | Z80CTC.CLKTRG3);
            }
            if (self.video.h_tick == SCANLINE_TICKS) {
                self.video.h_tick = 0;
                self.video.v_count +%= 1;
                if (self.video.v_count == NUM_SCANLINES) {
                    self.video.v_count = 0;
                }
            }
            return bus;
        }

        fn initRoms(opts: Options) Rom {
            var rom: Rom = undefined;
            switch (model) {
                .KC852 => {
                    cp(opts.roms.caos22, &rom.caos_e);
                },
                .KC853 => {
                    cp(opts.roms.kcbasic, &rom.basic);
                    cp(opts.roms.caos31, &rom.caos_e);
                },
                .KC854 => {
                    cp(opts.roms.kcbasic, &rom.basic);
                    cp(opts.roms.caos42c, &rom.caos_c);
                    cp(opts.roms.caos42e, &rom.caos_e);
                },
            }
            return rom;
        }

        fn updateMemoryMap(self: *Self, bus: Bus) void {
            self.mem_mapping = bus;
            self.mem.unmap(0x0000, 0x10000);

            // 0x0000..0x3FFF: all models have 16 KB builtin RAM at address 0x0000
            if ((bus & PIO.RAM) != 0) {
                if ((bus & PIO.RAM_RO) != 0) {
                    self.mem.mapRAM(0x0000, 0x4000, &self.ram[0]);
                } else {
                    self.mem.mapROM(0x0000, 0x4000, &self.ram[0]);
                }
            }

            // 0x4000..0x7FFF
            if (model == .KC854) {
                if ((bus & IO86.RAM4) != 0) {
                    if ((bus & IO86.RAM4_RO) != 0) {
                        self.mem.mapRAM(0x4000, 0x4000, &self.ram[1]);
                    } else {
                        self.mem.mapROM(0x4000, 0x4000, &self.ram[1]);
                    }
                }
            }

            // 0x8000..0xBFFF
            if (model != .KC854) {
                if ((bus & PIO.IRM) != 0) {
                    self.mem.mapRAM(0x8000, 0x4000, &self.ram[IRM0_PAGE]);
                }
            } else {
                // video memory is 4 banks, 2 for pixels, 2 for colors,
                // the area at 0xA800 to 0xBFFF is always mapped to IRM0!
                if ((bus & PIO.IRM) != 0) {
                    const irm_index: usize = @truncate((bus >> IO84_PINS[1]) & 3);
                    const irm = self.ram[IRM0_PAGE + irm_index][0..0x2800];
                    // on the KC85, an access to IRM banks other than the
                    // first is only possible for the first 10 KByte until
                    // A800, memory access to the remaining 6 KBytes
                    // (A800 to BFFF) is always forced to the first IRM bank
                    // by the address decoder hardware (see KC85/4 service manual)
                    self.mem.mapRAM(0x8000, 0x2800, irm);
                    // always force access to 0xA800 and above to the first IRM bank
                    self.mem.mapRAM(0xA800, 0x1800, self.ram[IRM0_PAGE][0x2800..]);
                } else if ((bus & PIO.RAM8) != 0) {
                    const ram8 = if ((bus & IO84.SEL_RAM8) != 0) &self.ram[3] else &self.ram[2];
                    if ((bus & PIO.RAM8_RO) != 0) {
                        self.mem.mapRAM(0x8000, 0x4000, ram8);
                    } else {
                        self.mem.mapROM(0x8000, 0x4000, ram8);
                    }
                }
            }

            // 0xC000..0xDFFF
            if (model != .KC852) {
                if ((bus & PIO.BASIC_ROM) != 0) {
                    self.mem.mapROM(0xC000, 0x2000, &self.rom.basic);
                }
            }
            if (model == .KC854) {
                if ((bus & IO86.CAOS_ROM_C) != 0) {
                    self.mem.mapROM(0xC000, 0x1000, &self.rom.caos_c);
                }
            }

            // 0xE000..0xFFFF
            if ((bus & PIO.CAOS_ROM) != 0) {
                self.mem.mapROM(0xE000, 0x2000, &self.rom.caos_e);
            } else {
                self.mem.unmap(0xE000, 0x2000);
            }
        }

        // this is a simplified version of the PIO-B interrupt service routine
        // which is normally triggered when the serial keyboard hardware
        // sends a new pulse (for details, see
        // https://github.com/floooh/yakc/blob/master/misc/kc85_3_kbdint.md )
        //
        // we ignore the whole tricky serial decoding and patch the
        // keycode directly into the right memory locations.
        //
        fn updateKeyboard(self: *Self, micro_seconds: u32) void {
            self.key_buf.update(micro_seconds);

            // don't do anything if interrupts are currently disabled,
            // IX might point to the wrong base address!
            if (self.cpu.iff1 == 0) {
                return;
            }

            // get first valid key code from key buffer
            var key_code: u8 = 0;
            for (self.key_buf.slots) |slot| {
                if (slot.key != 0) {
                    key_code = @truncate(slot.key);
                    break;
                }
            }

            const ix = self.cpu.IX();
            const ix_key_status = ix +% 0x8;
            const ix_key_repeat = ix +% 0xA;
            const ix_key_code = ix +% 0xD;
            if (0 == key_code) {
                // if keycode is 0, this basically means the CTC3 timeout was hit
                self.mem.wr(ix_key_status, self.mem.rd(ix_key_status) | KBD.TIMEOUT); // set the CTC3 timeout bit
                self.mem.wr(ix_key_code, 0); // clear current keycode
            } else {
                // a valid key code has been received, clear the timeout bit
                self.mem.wr(ix_key_status, self.mem.rd(ix_key_status) & ~KBD.TIMEOUT);

                // check for key-repeat
                if (key_code != self.mem.rd(ix_key_code)) {
                    // no key repeat
                    self.mem.wr(ix_key_code, key_code);
                    self.mem.wr(ix_key_status, self.mem.rd(ix_key_status) & ~KBD.REPEAT);
                    self.mem.wr(ix_key_status, self.mem.rd(ix_key_status) | KBD.KEYREADY);
                    self.mem.wr(ix_key_repeat, 0);
                } else {
                    // handle key repeat
                    self.mem.wr(ix_key_repeat, self.mem.rd(ix_key_repeat) +% 1);
                    if ((self.mem.rd(ix_key_repeat) & KBD.REPEAT) != 0) {
                        // this is a followup (short) key repeat
                        if (self.mem.rd(ix_key_repeat) < KBD.SHORT_REPEAT_COUNT) {
                            // wait some more...
                            return;
                        }
                    } else {
                        // this is the first (long) key repeat
                        if (self.mem.rd(ix_key_repeat) < KBD.LONG_REPEAR_COUNT) {
                            // wait some more...
                            return;
                        }
                        // first key repeat pause over, set first-key-repeat flag
                        self.mem.wr(ix_key_status, self.mem.rd(ix_key_status) | KBD.REPEAT);
                    }
                    // key repeat triggered, set the key-ready flags and reset repeat-count
                    self.mem.wr(ix_key_status, self.mem.rd(ix_key_status) | KBD.KEYREADY);
                    self.mem.wr(ix_key_repeat, 0);
                }
            }
        }
    };
}
