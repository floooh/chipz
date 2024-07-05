//
//  Memory map info:
//
//  Pacman: only 15 address bits used, mirroring will happen in tick callback
//
//  0000..3FFF:     16KB ROM
//  4000..43FF:     1KB video RAM
//  4400..47FF:     1KB color RAM
//  4800..4C00:     unmapped?
//  4C00..4FEF:     <1KB main RAM
//  4FF0..4FFF:     sprite attributes (write only?)
//
//  5000            write:  interrupt enable/disable
//                  read:   IN0 (joystick + coin slot)
//  5001            write:  sound enable
//  5002            ???
//  5003            write:  flip screen
//  5004            write:  player 1 start light (ignored)
//  5005            write:  player 2 start light (ignored)
//  5006            write:  coin lockout (ignored)
//  5007            write:  coin counter (ignored)
//  5040..505F      write:  sound registers
//  5040            read:   IN1 (joystick + coin slot)
//  5060..506F      write:  sprite coordinates
//  5080            read:   DIP switched
//
//  Pengo: full 64KB address space
//
//  0000..7FFF:     32KB ROM
//  8000..83FF:     1KB video RAM
//  8400..87FF:     1KB color RAM
//  8800..8FEF:     2KB main RAM
//  9000+           memory mapped registers

const std = @import("std");
const assert = std.debug.assert;
const z80 = @import("chips").z80;
const common = @import("common");
const memory = common.memory;
const clock = common.clock;
const AudioCallback = common.host.AudioCallback;
const AudioOptions = common.host.AudioOptions;
const DisplayInfo = common.host.DisplayInfo;

/// the emulated arcade machine type
pub const System = enum {
    Pacman,
    Pengo,
};

// bus wire definitions
const Z80_PINS = z80.Pins{
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

// setup types
const Z80 = z80.Z80(Z80_PINS, u64);
const Memory = memory.Memory(0x400);

const getAddr = Z80.getAddr;
const getData = Z80.getData;
const setData = Z80.setData;
const M1 = Z80.M1;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const WR = Z80.WR;
const RD = Z80.RD;
const INT = Z80.INT;

pub fn Namco(comptime sys: System) type {
    return struct {
        const Self = @This();

        /// Namco system init options
        pub const Options = struct {
            audio: AudioOptions,
            roms: switch (sys) {
                .Pacman => struct {
                    sys_0000_0FFF: []const u8,
                    sys_1000_1FFF: []const u8,
                    sys_2000_2FFF: []const u8,
                    sys_3000_3FFF: []const u8,
                    prom_0000_001F: []const u8,
                    prom_0020_011F: []const u8,
                    gfx_0000_0FFF: []const u8,
                    gfx_1000_1FFF: []const u8,
                    sound_0000_00FF: []const u8,
                    sound_0100_01FF: []const u8,
                },
                .Pengo => struct {
                    sys_0000_0FFF: []const u8,
                    sys_1000_1FFF: []const u8,
                    sys_2000_2FFF: []const u8,
                    sys_3000_3FFF: []const u8,
                    sys_4000_4FFF: []const u8,
                    sys_5000_5FFF: []const u8,
                    sys_6000_6FFF: []const u8,
                    sys_7000_7FFF: []const u8,
                    prom_0000_001F: []const u8,
                    prom_0020_041F: []const u8,
                    gfx_0000_1FFF: []const u8,
                    gfx_2000_3FFF: []const u8,
                    sound_0000_00FF: []const u8,
                    sound_0100_01FF: []const u8,
                },
            },
        };

        pub const Input = enum {
            P1_UP,
            P1_LEFT,
            P1_RIGHT,
            P1_DOWN,
            P1_BUTTON,
            P1_COIN,
            P1_START,
            P2_UP,
            P2_LEFT,
            P2_RIGHT,
            P2_DOWN,
            P2_BUTTON,
            P2_COIN,
            P2_START,
        };

        const PALETTE_MAP_SIZE = if (sys == .Pacman) 256 else 512;
        const MASTER_FREQUENCY = 18432000;
        const CPU_FREQUENCY = MASTER_FREQUENCY / 6;
        const VSYNC_PERIOD = CPU_FREQUENCY / 60;

        // display related constants
        const DISPLAY = struct {
            const WIDTH = 288;
            const HEIGHT = 224;
            const FB_WIDTH = 512; // 2^N for faster address computation
            const FB_HEIGHT = 224;
            const FB_SIZE = FB_WIDTH * FB_HEIGHT;
        };

        // audio system related constants
        const AUDIO = struct {
            const MAX_SAMPLES = 256;
            const PERIOD = 32; // sound is ticked every 32 CPU ticks
            const OVERSAMPLE = 2;
            const SAMPLE_SCALE = 16;

            const ADDR_V1_FC0 = MEMIO.WR.AUDIO_BASE + 0x00; // voice1 frequency counter nibble 0
            const ADDR_V1_FC1 = MEMIO.WR.AUDIO_BASE + 0x01; //                          nibble 1
            const ADDR_V1_FC2 = MEMIO.WR.AUDIO_BASE + 0x02; //                          nibble 2
            const ADDR_V1_FC3 = MEMIO.WR.AUDIO_BASE + 0x03; //                          nibble 3
            const ADDR_V1_FC4 = MEMIO.WR.AUDIO_BASE + 0x04; //                          nibble 4
            const ADDR_V1_WAVE = MEMIO.WR.AUDIO_BASE + 0x05; // voice1 wave form
            const ADDR_V2_FC1 = MEMIO.WR.AUDIO_BASE + 0x06; // voice2 frequency counter nibble 1
            const ADDR_V2_FC2 = MEMIO.WR.AUDIO_BASE + 0x07; //                          nibble 2
            const ADDR_V2_FC3 = MEMIO.WR.AUDIO_BASE + 0x08; //                          nibble 3
            const ADDR_V2_FC4 = MEMIO.WR.AUDIO_BASE + 0x09; //                          nibble 4
            const ADDR_V2_WAVE = MEMIO.WR.AUDIO_BASE + 0x0A; // voice2 wave form
            const ADDR_V3_FC1 = MEMIO.WR.AUDIO_BASE + 0x0B; // voice3 frequency counter nibble 1
            const ADDR_V3_FC2 = MEMIO.WR.AUDIO_BASE + 0x0C; //                          nibble 2
            const ADDR_V3_FC3 = MEMIO.WR.AUDIO_BASE + 0x0D; //                          nibble 3
            const ADDR_V3_FC4 = MEMIO.WR.AUDIO_BASE + 0x0E; //                          nibble 4
            const ADDR_V3_WAVE = MEMIO.WR.AUDIO_BASE + 0x0F; // voice3 wave form
            const ADDR_V1_FQ0 = MEMIO.WR.AUDIO_BASE + 0x10; // voice1 frequency nibble 0
            const ADDR_V1_FQ1 = MEMIO.WR.AUDIO_BASE + 0x11; //                  nibble 1
            const ADDR_V1_FQ2 = MEMIO.WR.AUDIO_BASE + 0x12; //                  nibble 2
            const ADDR_V1_FQ3 = MEMIO.WR.AUDIO_BASE + 0x13; //                  nibble 3
            const ADDR_V1_FQ4 = MEMIO.WR.AUDIO_BASE + 0x14; //                  nibble 4
            const ADDR_V1_VOLUME = MEMIO.WR.AUDIO_BASE + 0x15; // voice1 volume
            const ADDR_V2_FQ1 = MEMIO.WR.AUDIO_BASE + 0x16; // voice2 frequency nibble 1
            const ADDR_V2_FQ2 = MEMIO.WR.AUDIO_BASE + 0x17; //                  nibble 2
            const ADDR_V2_FQ3 = MEMIO.WR.AUDIO_BASE + 0x18; //                  nibble 3
            const ADDR_V2_FQ4 = MEMIO.WR.AUDIO_BASE + 0x19; //                  nibble 4
            const ADDR_V2_VOLUME = MEMIO.WR.AUDIO_BASE + 0x1A; // voice2 volume
            const ADDR_V3_FQ1 = MEMIO.WR.AUDIO_BASE + 0x1B; // voice3 frequency nibble 1
            const ADDR_V3_FQ2 = MEMIO.WR.AUDIO_BASE + 0x1C; //                  nibble 2
            const ADDR_V3_FQ3 = MEMIO.WR.AUDIO_BASE + 0x1D; //                  nibble 3
            const ADDR_V3_FQ4 = MEMIO.WR.AUDIO_BASE + 0x1E; //                  nibble 4
            const ADDR_V3_VOLUME = MEMIO.WR.AUDIO_BASE + 0x1F; // voice3 volume
        };

        // memory mapping related constants
        const MEMMAP = switch (sys) {
            .Pacman => struct {
                const ADDR_MASK = 0x7FFF; // Pacman only has 15 address wires
                const SPRITES_ATTRS = 0x03F0; // index into Namco.ram.main[]
                const VIDEO_RAM_SIZE = 0x0400;
                const COLOR_RAM_SIZE = 0x0400;
                const MAIN_RAM_SIZE = 0x0400;
                const CPU_ROM_SIZE = 0x4000;
                const GFX_ROM_SIZE = 0x2000;
                const PROM_SIZE = 0x120;
                const SOUND_ROM_SIZE = 0x0200;
            },
            .Pengo => struct {
                const ADDR_MASK = 0xFFFF;
                const SPRITES_ATTRS = 0x07F0; // index into Namco.ram.main[]
                const VIDEO_RAM_SIZE = 0x0400;
                const COLOR_RAM_SIZE = 0x0400;
                const MAIN_RAM_SIZE = 0x0800;
                const CPU_ROM_SIZE = 0x8000;
                const GFX_ROM_SIZE = 0x4000;
                const PROM_SIZE = 0x0420;
                const SOUND_ROM_SIZE = 0x0200;
            },
        };

        // memory-mapped IO addresses
        const MEMIO = switch (sys) {
            .Pacman => struct {
                const BASE: u16 = 0x5000;
                const RD = struct {
                    const IN0: u16 = BASE;
                    const IN1: u16 = BASE + 0x40;
                    const DSW1: u16 = BASE + 0x80;
                };
                const WR = struct {
                    const INT_ENABLE: u16 = BASE;
                    const SOUND_ENABLE: u16 = BASE + 1;
                    const FLIP_SCREEN: u16 = BASE + 3; // FIXME: is this correct?
                    const AUDIO_BASE: u16 = BASE + 0x40;
                    const SPRITES_BASE: u16 = BASE + 0x60;
                };
            },
            .Pengo => struct {
                const BASE: u16 = 0x9000;
                const RD = struct {
                    const IN0: u16 = BASE + 0xC0;
                    const IN1: u16 = BASE + 0x80;
                    const DSW1: u16 = BASE + 0x40;
                    const DSW2: u16 = BASE;
                };
                const WR = struct {
                    const AUDIO_BASE: u16 = BASE;
                    const SPRITES_BASE: u16 = BASE + 0x20;
                    const INT_ENABLE: u16 = BASE + 0x40;
                    const SOUND_ENABLE: u16 = BASE + 0x41;
                    const PAL_SELECT: u16 = BASE + 0x42;
                    const FLIP_SCREEN: u16 = BASE + 0x43;
                    const CLUT_SELECT: u16 = BASE + 0x46;
                    const TILE_SELECT: u16 = BASE + 0x47;
                    const WATCHDOG: u16 = BASE + 0x80;
                };
            },
        };

        // IN0 bits (active-low)
        const IN0 = switch (sys) {
            .Pacman => struct {
                const UP: u8 = 1 << 0;
                const LEFT: u8 = 1 << 1;
                const RIGHT: u8 = 1 << 2;
                const DOWN: u8 = 1 << 3;
                const RACK_ADVANCE: u8 = 1 << 4;
                const COIN1: u8 = 1 << 5;
                const COIN2: u8 = 1 << 6;
                const CREDIT: u8 = 1 << 7;
            },
            .Pengo => struct {
                const UP: u8 = 1 << 0;
                const DOWN: u8 = 1 << 1;
                const LEFT: u8 = 1 << 2;
                const RIGHT: u8 = 1 << 3;
                const COIN1: u8 = 1 << 4;
                const COIN2: u8 = 1 << 5;
                const COIN3: u8 = 1 << 6; // aka coin-aux, not supported
                const BUTTON: u8 = 1 << 7;
            },
        };

        // IN1 bits (active-low)
        const IN1 = switch (sys) {
            .Pacman => struct {
                const UP: u8 = 1 << 0;
                const LEFT: u8 = 1 << 1;
                const RIGHT: u8 = 1 << 2;
                const DOWN: u8 = 1 << 3;
                const BOARD_TEST: u8 = 1 << 4;
                const P1_START: u8 = 1 << 5;
                const P2_START: u8 = 1 << 6;
            },
            .Pengo => struct {
                const UP: u8 = 1 << 0;
                const DOWN: u8 = 1 << 1;
                const LEFT: u8 = 1 << 2;
                const RIGHT: u8 = 1 << 3;
                const BOARD_TEST: u8 = 1 << 4;
                const P1_START: u8 = 1 << 5;
                const P2_START: u8 = 1 << 6;
                const BUTTON: u8 = 1 << 7;
            },
        };

        // DSW1 bits (active-high)
        const DSW1 = switch (sys) {
            .Pacman => struct {
                const COINS_MASK: u8 = 3 << 0;
                const COINS_FREE: u8 = 0; // free play
                const COINS_1C1G: u8 = 1 << 0; // 1 coin 1 game
                const COINS_1C2G: u8 = 2 << 0; // 1 coin 2 games
                const COINS_2C1G: u8 = 3 << 0; // 2 coins 1 game
                const LIVES_MASK: u8 = 3 << 2;
                const LIVES_1: u8 = 0 << 2;
                const LIVES_2: u8 = 1 << 2;
                const LIVES_3: u8 = 2 << 2;
                const LIVES_5: u8 = 3 << 2;
                const EXTRALIFE_MASK: u8 = 3 << 4;
                const EXTRALIFE_10K: u8 = 0 << 4;
                const EXTRALIFE_15K: u8 = 1 << 4;
                const EXTRALIFE_20K: u8 = 2 << 4;
                const EXTRALIFE_NONE: u8 = 3 << 4;
                const DIFFICULTY_MASK: u8 = 1 << 6;
                const DIFFICULTY_HARD: u8 = 0 << 6;
                const DIFFICULTY_NORM: u8 = 1 << 6;
                const GHOSTNAMES_MASK: u8 = 1 << 7;
                const GHOSTNAMES_ALT: u8 = 0 << 7;
                const GHOSTNAMES_NORM: u8 = 1 << 7;
                const DEFAULT: u8 = COINS_1C1G | LIVES_3 | EXTRALIFE_15K | DIFFICULTY_NORM | GHOSTNAMES_NORM;
            },
            .Pengo => struct {
                const EXTRALIFE_MASK: u8 = 1 << 0;
                const EXTRALIFE_30K: u8 = 0 << 0;
                const EXTRALIFE_50K: u8 = 1 << 0;
                const DEMOSOUND_MASK: u8 = 1 << 1;
                const DEMOSOUND_ON: u8 = 0 << 1;
                const DEMOSOUND_OFF: u8 = 1 << 1;
                const CABINET_MASK: u8 = 1 << 2;
                const CABINET_UPRIGHT: u8 = 0 << 2;
                const CABINET_COCKTAIL: u8 = 1 << 2;
                const LIVES_MASK: u8 = 3 << 3;
                const LIVES_2: u8 = 0 << 3;
                const LIVES_3: u8 = 1 << 3;
                const LIVES_4: u8 = 2 << 3;
                const LIVES_5: u8 = 3 << 3;
                const RACKTEST_MASK: u8 = 1 << 5;
                const RACKTEST_ON: u8 = 0 << 5;
                const RACKTEST_OFF: u8 = 1 << 5;
                const DIFFICULTY_MASK: u8 = 3 << 6;
                const DIFFICULTY_EASY: u8 = 0 << 6;
                const DIFFICULTY_MEDIUM: u8 = 1 << 6;
                const DIFFICULTY_HARD: u8 = 2 << 6;
                const DIFFICULTY_HARDEST: u8 = 3 << 6;
                const DEFAULT: u8 = EXTRALIFE_30K | DEMOSOUND_ON | CABINET_UPRIGHT | LIVES_3 | RACKTEST_OFF | DIFFICULTY_MEDIUM;
            },
        };

        // DSW2 bits (active-high)
        const DSW2 = switch (sys) {
            .Pacman => struct {
                const DEFAULT: u8 = 0;
            },
            .Pengo => struct {
                const COINA_MASK: u8 = 0xF << 0; // 16 combinations of N coins -> M games
                const COINA_1C1G: u8 = 0xC << 0;
                const COINB_MASK: u8 = 0xF << 4;
                const COINB_1C1G: u8 = 0xC << 4;
                const DEFAULT: u8 = COINA_1C1G | COINB_1C1G;
            },
        };

        const AudioVoice = struct {
            frequency: u20 = 0, // frequency
            counter: u20 = 0, // counter, top 5 bits are index into 32-byte wave table
            waveform: u3 = 0, // waveform select
            volume: u4 = 0, // 16 volume levels
            sample: f32 = 0.0, // accumulated sample value
            sample_div: f32 = 0.0, // oversampling divider
        };

        const Audio = struct {
            tick_counter: u32,
            sample_period: i32,
            sample_counter: i32,
            volume: f32,
            voices: [3]AudioVoice = [_]AudioVoice{.{}} ** 3,
            num_samples: u32,
            sample_pos: u32,
            callback: AudioCallback,
            rom: [0x0200]u8,
            sample_buffer: [AUDIO.MAX_SAMPLES]f32,
        };

        bus: u64 = 0,
        cpu: Z80,
        mem: Memory,
        in0: u8 = 0, // inverted bits (active-low)
        in1: u8 = 0, // inverted bits (active-low)
        dsw1: u8 = DSW1.DEFAULT, // dip-switches as-is (active-high)
        dsw2: u8 = DSW2.DEFAULT, // Pengo only
        int_vector: u8 = 0, // IM2 interrupt vector set with OUT on port 0
        int_enable: bool = false,
        sound_enable: bool = false,
        flip_screen: bool = false, // screen-flip for cocktail cabinet (not implemented)
        pal_select: u8 = 0, // Pengo only
        clut_select: u8 = 0, // Pengo only
        tile_select: u8 = 0, // Pengo only
        sprite_coords: [16]u8, // 8 sprites x/y pairs
        vsync_count: u32 = VSYNC_PERIOD,

        ram: struct {
            video: [MEMMAP.VIDEO_RAM_SIZE]u8,
            color: [MEMMAP.COLOR_RAM_SIZE]u8,
            main: [MEMMAP.MAIN_RAM_SIZE]u8,
        },
        rom: struct {
            cpu: [MEMMAP.CPU_ROM_SIZE]u8,
            gfx: [MEMMAP.GFX_ROM_SIZE]u8,
            prom: [MEMMAP.PROM_SIZE]u8,
        },

        audio: Audio, // audio emulation state
        hw_colors: [32]u32, // 8-bit colors from pal_rom[0..32] decoded to RGBA8
        pal_map: [PALETTE_MAP_SIZE]u5, // indirect indices into hw_colors
        fb: [DISPLAY.FB_SIZE]u8 align(128), // framebuffer bytes are indices into hw_colors

        junk_page: [Memory.PAGE_SIZE]u8,
        unmapped_page: [Memory.PAGE_SIZE]u8,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .cpu = .{},
                .mem = Memory.init(.{
                    .junk_page = &self.junk_page,
                    .unmapped_page = &self.unmapped_page,
                }),
                .sprite_coords = std.mem.zeroes(@TypeOf(self.sprite_coords)),
                .ram = .{
                    .video = std.mem.zeroes(@TypeOf(self.ram.video)),
                    .color = std.mem.zeroes(@TypeOf(self.ram.color)),
                    .main = std.mem.zeroes(@TypeOf(self.ram.main)),
                },
                .rom = .{
                    .cpu = initSysRom(opts),
                    .gfx = initGfxRom(opts),
                    .prom = initPRom(opts),
                },

                .hw_colors = initHwColors(&self.rom.prom),
                .pal_map = initPaletteMap(&self.rom.prom),

                .audio = initAudio(opts),

                .fb = std.mem.zeroes(@TypeOf(self.fb)),
                .junk_page = std.mem.zeroes(@TypeOf(self.junk_page)),
                .unmapped_page = [_]u8{0xFF} ** Memory.PAGE_SIZE,
            };
            self.initMemoryMap();
        }

        // FIXME: initAlloc()?

        inline fn pin(bus: u64, p: comptime_int) bool {
            return (bus & p) != 0;
        }

        /// run emulation for a number of microseconds and decode a video frame
        /// return number of clock cycles executed
        pub fn exec(self: *Self, micro_seconds: u32) u32 {
            const num_ticks = clock.microSecondsToTicks(CPU_FREQUENCY, micro_seconds);
            var bus = self.bus;
            for (0..num_ticks) |_| {
                bus = self.tick(bus);
            }
            self.bus = bus;
            self.decodeVideo();
            return num_ticks;
        }

        /// execute a single clock cycle
        pub fn tick(self: *Self, in_bus: u64) u64 {
            var bus = in_bus;

            // update vscync counter and trigger interrupt
            self.vsync_count -= 1;
            if (self.vsync_count == 0) {
                self.vsync_count = VSYNC_PERIOD;
                if (self.int_enable) {
                    bus |= INT;
                }
            }

            // tick sound
            self.tickAudio();

            // tick the CPU
            bus = self.cpu.tick(bus);
            const addr = getAddr(bus) & MEMMAP.ADDR_MASK;
            if (pin(bus, MREQ)) {
                if (pin(bus, WR)) {
                    const data = getData(bus);
                    if (addr < MEMIO.BASE) {
                        // a regular memory write
                        self.mem.wr(addr, data);
                    } else {
                        // a memory-mapped IO write
                        switch (addr) {
                            MEMIO.WR.INT_ENABLE => self.int_enable = (data & 1) != 0,
                            MEMIO.WR.SOUND_ENABLE => self.sound_enable = (data & 1) != 0,
                            MEMIO.WR.FLIP_SCREEN => self.flip_screen = (data & 1) != 0,
                            MEMIO.WR.AUDIO_BASE...MEMIO.WR.AUDIO_BASE + 0x1F => {
                                self.audioWrite(addr, data);
                            },
                            MEMIO.WR.SPRITES_BASE...MEMIO.WR.SPRITES_BASE + 0xF => {
                                self.sprite_coords[addr & 0x000F] = data;
                            },
                            else => if (sys == .Pengo) switch (addr) {
                                MEMIO.WR.PAL_SELECT => self.pal_select = data & 1,
                                MEMIO.WR.CLUT_SELECT => self.clut_select = data & 1,
                                MEMIO.WR.TILE_SELECT => self.tile_select = data & 1,
                                else => {},
                            },
                        }
                    }
                } else if (pin(bus, RD)) {
                    if (addr < MEMIO.BASE) {
                        // a regular memory read
                        bus = setData(bus, self.mem.rd(addr));
                    } else {
                        // FIXME: IN0, IN1, DSW1 are mirrored for 0x40 bytes
                        const data: u8 = switch (addr) {
                            MEMIO.RD.IN0 => ~self.in0,
                            MEMIO.RD.IN1 => ~self.in1,
                            MEMIO.RD.DSW1 => self.dsw1,
                            else => if (sys == .Pengo and addr == MEMIO.RD.DSW2) self.dsw2 else 0xFF,
                        };
                        bus = setData(bus, data);
                    }
                }
            } else if (pin(bus, IORQ)) {
                if (pin(bus, WR)) {
                    if ((addr & 0x00FF) == 0) {
                        // OUT to port 0: set interrupt vector latch
                        self.int_vector = getData(bus);
                    }
                } else if (pin(bus, M1)) {
                    // an interrupt machine cycle, set interrupt vector on data bus
                    // and clear the interrupt pin
                    bus = setData(bus, self.int_vector) & ~INT;
                }
            }
            return bus;
        }

        fn setClearBits(val: u8, comptime mask: u8, comptime set: bool) u8 {
            if (set) {
                return val | mask;
            } else {
                return val & ~mask;
            }
        }

        fn setClearInput(self: *Self, inp: Input, comptime set: bool) void {
            switch (inp) {
                .P1_UP => self.in0 = setClearBits(self.in0, IN0.UP, set),
                .P1_LEFT => self.in0 = setClearBits(self.in0, IN0.LEFT, set),
                .P1_RIGHT => self.in0 = setClearBits(self.in0, IN0.RIGHT, set),
                .P1_DOWN => self.in0 = setClearBits(self.in0, IN0.DOWN, set),
                .P1_BUTTON => if (sys == .Pengo) {
                    self.in0 = setClearBits(self.in0, IN0.BUTTON, set);
                },
                .P1_COIN => self.in0 = setClearBits(self.in0, IN0.COIN1, set),
                .P1_START => self.in1 = setClearBits(self.in1, IN1.P1_START, set),
                .P2_UP => self.in1 = setClearBits(self.in1, IN1.UP, set),
                .P2_LEFT => self.in1 = setClearBits(self.in1, IN1.LEFT, set),
                .P2_RIGHT => self.in1 = setClearBits(self.in1, IN1.RIGHT, set),
                .P2_DOWN => self.in1 = setClearBits(self.in1, IN1.DOWN, set),
                .P2_BUTTON => if (sys == .Pengo) {
                    self.in1 = setClearBits(self.in1, IN1.BUTTON, set);
                },
                .P2_COIN => self.in0 = setClearBits(self.in1, IN0.COIN2, set),
                .P2_START => self.in1 = setClearBits(self.in1, IN1.P2_START, set),
            }
        }

        /// set input bits to 'active' state
        pub fn setInput(self: *Self, inp: Input) void {
            self.setClearInput(inp, true);
        }

        /// set input bits to 'inactive' state
        pub fn clearInput(self: *Self, inp: Input) void {
            self.setClearInput(inp, false);
        }

        pub fn displayInfo(selfOrNull: ?*Self) DisplayInfo {
            return .{
                .fb = .{
                    .dim = .{
                        .width = DISPLAY.FB_WIDTH,
                        .height = DISPLAY.FB_HEIGHT,
                    },
                    .format = .Palette8,
                    .buffer = if (selfOrNull) |self| &self.fb else null,
                },
                .view = .{
                    .x = 0,
                    .y = 0,
                    .width = DISPLAY.WIDTH,
                    .height = DISPLAY.HEIGHT,
                },
                .palette = if (selfOrNull) |self| &self.hw_colors else null,
                .orientation = .Portrait,
            };
        }

        fn decodeVideo(self: *Self) void {
            self.decodeChars();
            self.decodeSprites();
        }

        // compute offset into video and color ram from x and y tile position,
        // see https://www.walkofmind.com/programming/pie/video_memory.htm
        fn video_offset(in_x: usize, in_y: usize) usize {
            const x = in_x -% 2;
            const y = in_y +% 2;
            return if ((x & 0x20) != 0) y + ((x & 0x1F) << 5) else x + (y << 5);
        }

        // decode an 8x4 pixel tile, used both for background tiles and sprites
        inline fn decode8x4(
            self: *Self,
            tile_base: usize,
            pal_base: usize,
            comptime tile_stride: usize,
            comptime tile_offset: usize,
            px: usize,
            py: usize,
            char_code: u8,
            color_code: u8,
            comptime opaq: bool,
            flip_x: bool,
            flip_y: bool,
        ) void {
            const xor_x: usize = if (flip_x) 3 else 0;
            const xor_y: usize = if (flip_y) 7 else 0;
            for (0..8) |yy| {
                const y: usize = py + (yy ^ xor_y);
                if (y >= DISPLAY.HEIGHT) {
                    continue;
                }
                const tile_index: usize = char_code * tile_stride + tile_offset + yy;
                for (0..4) |xx| {
                    const x: usize = px + (xx ^ xor_x);
                    if (x >= DISPLAY.WIDTH) {
                        continue;
                    }
                    const shr_hi: u3 = @truncate(7 - xx);
                    const shr_lo: u3 = @truncate(3 - xx);
                    const p2_hi: u8 = (self.rom.gfx[tile_base + tile_index] >> shr_hi) & 1;
                    const p2_lo: u8 = (self.rom.gfx[tile_base + tile_index] >> shr_lo) & 1;
                    const p2: u8 = (p2_hi << 1) | p2_lo;
                    const hw_color: u8 = self.pal_map[pal_base + ((@as(usize, color_code) << 2) | p2)];
                    if (opaq or (self.rom.prom[hw_color] != 0)) {
                        self.fb[y * DISPLAY.FB_WIDTH + x] = hw_color;
                    }
                }
            }
        }

        // decode background tile pixels
        fn decodeChars(self: *Self) void {
            const pal_base: usize = (@as(usize, self.pal_select) << 8) | (@as(usize, self.clut_select) << 7);
            const tile_base: usize = @as(usize, self.tile_select) * 0x2000;
            for (0..28) |y| {
                for (0..36) |x| {
                    const offset = video_offset(x, y);
                    const char_code = self.ram.video[offset];
                    const color_code = self.ram.color[offset] & 0x1F;
                    self.decode8x4(tile_base, pal_base, 16, 8, x * 8, y * 8, char_code, color_code, true, false, false);
                    self.decode8x4(tile_base, pal_base, 16, 0, x * 8 + 4, y * 8, char_code, color_code, true, false, false);
                }
            }
        }

        // decode hardware sprite pixels
        fn decodeSprites(self: *Self) void {
            const pal_base: usize = (@as(usize, self.pal_select) << 8) | (@as(usize, self.clut_select) << 7);
            const tile_base: usize = 0x1000 + @as(usize, self.tile_select) * 0x2000;
            const max_sprite: usize = if (sys == .Pacman) 6 else 7;
            const min_sprite: usize = if (sys == .Pacman) 1 else 0;
            var sprite_index: usize = max_sprite;
            while (sprite_index >= min_sprite) : (sprite_index -= 1) {
                const py: usize = self.sprite_coords[sprite_index * 2 + 0] -% 31;
                const px: usize = 272 - @as(usize, self.sprite_coords[sprite_index * 2 + 1]);
                const shape: u8 = self.ram.main[MEMMAP.SPRITES_ATTRS + sprite_index * 2 + 0];
                const char_code: u8 = shape >> 2;
                const color_code: u8 = self.ram.main[MEMMAP.SPRITES_ATTRS + sprite_index * 2 + 1];
                const flip_x: bool = (shape & 1) != 0;
                const flip_y: bool = (shape & 2) != 0;
                const fy0: usize = if (flip_y) 8 else 0;
                const fy1: usize = if (flip_y) 0 else 8;
                const fx0: usize = if (flip_x) 12 else 0;
                const fx1: usize = if (flip_x) 8 else 4;
                const fx2: usize = if (flip_x) 4 else 8;
                const fx3: usize = if (flip_x) 0 else 12;
                self.decode8x4(tile_base, pal_base, 64, 8, px +% fx0, py +% fy0, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 16, px +% fx1, py +% fy0, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 24, px +% fx2, py +% fy0, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 0, px +% fx3, py +% fy0, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 40, px +% fx0, py +% fy1, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 48, px +% fx1, py +% fy1, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 56, px +% fx2, py +% fy1, char_code, color_code, false, flip_x, flip_y);
                self.decode8x4(tile_base, pal_base, 64, 32, px +% fx3, py +% fy1, char_code, color_code, false, flip_x, flip_y);
            }
        }

        /// decode 8-bit ROM colors into 32-bit RGBA8
        fn initHwColors(prom: []const u8) [32]u32 {
            // Each color ROM entry describes an RGB color in 1 byte:
            //
            // | 7| 6| 5| 4| 3| 2| 1| 0|
            // |B1|B0|G2|G1|G0|R2|R1|R0|
            //
            // Intensities are: 0x97 + 0x47 + 0x21
            var rgba8: [32]u32 = undefined;
            for (0..32) |i| {
                const rgb: u8 = prom[i];
                const r: u32 = ((rgb >> 0) & 1) * 0x21 + ((rgb >> 1) & 1) * 0x47 + ((rgb >> 2) & 1) * 0x97;
                const g: u32 = ((rgb >> 3) & 1) * 0x21 + ((rgb >> 4) & 1) * 0x47 + ((rgb >> 5) & 1) * 0x97;
                const b: u32 = ((rgb >> 6) & 1) * 0x47 + ((rgb >> 7) & 1) * 0x97;
                rgba8[i] = 0xFF000000 | (b << 16) | (g << 8) | r;
            }
            return rgba8;
        }

        // decode PROM palette map
        fn initPaletteMap(prom: []const u8) [PALETTE_MAP_SIZE]u5 {
            var map: [PALETTE_MAP_SIZE]u5 = undefined;
            for (0..256) |i| {
                const pal_index: u5 = @truncate(prom[i + 0x20] & 0x0F);
                map[i] = pal_index;
                if (sys == .Pengo) {
                    map[0x100 + i] = 0x10 | pal_index;
                }
            }
            return map;
        }

        fn initMemoryMap(self: *Self) void {
            self.mem.mapROM(0x0000, 0x1000, self.rom.cpu[0x0000..0x1000]);
            self.mem.mapROM(0x1000, 0x1000, self.rom.cpu[0x1000..0x2000]);
            self.mem.mapROM(0x2000, 0x1000, self.rom.cpu[0x2000..0x3000]);
            self.mem.mapROM(0x3000, 0x1000, self.rom.cpu[0x3000..0x4000]);
            if (sys == .Pacman) {
                self.mem.mapRAM(0x4000, 0x0400, self.ram.video[0..]);
                self.mem.mapRAM(0x4400, 0x0400, self.ram.color[0..]);
                self.mem.mapRAM(0x4C00, 0x0400, self.ram.main[0..]);
            } else {
                self.mem.mapROM(0x4000, 0x1000, self.rom.cpu[0x4000..0x5000]);
                self.mem.mapROM(0x5000, 0x1000, self.rom.cpu[0x5000..0x6000]);
                self.mem.mapROM(0x6000, 0x1000, self.rom.cpu[0x6000..0x7000]);
                self.mem.mapROM(0x7000, 0x1000, self.rom.cpu[0x7000..0x8000]);
                self.mem.mapRAM(0x8000, 0x0400, self.ram.video[0..]);
                self.mem.mapRAM(0x8400, 0x0400, self.ram.color[0..]);
                self.mem.mapRAM(0x8800, 0x0800, self.ram.main[0..]);
            }
        }

        fn cp(src: []const u8, dst: []u8) void {
            std.mem.copyForwards(u8, dst, src);
        }

        fn initSysRom(opts: Options) [MEMMAP.CPU_ROM_SIZE]u8 {
            var rom: [MEMMAP.CPU_ROM_SIZE]u8 = undefined;
            if (sys == .Pacman) {
                assert(rom.len == 0x4000);
            }
            cp(opts.roms.sys_0000_0FFF, rom[0x0000..0x1000]);
            cp(opts.roms.sys_1000_1FFF, rom[0x1000..0x2000]);
            cp(opts.roms.sys_2000_2FFF, rom[0x2000..0x3000]);
            cp(opts.roms.sys_3000_3FFF, rom[0x3000..0x4000]);
            if (sys == .Pengo) {
                assert((sys == .Pengo) and (rom.len == 0x8000));
                cp(opts.roms.sys_4000_4FFF, rom[0x4000..0x5000]);
                cp(opts.roms.sys_5000_5FFF, rom[0x5000..0x6000]);
                cp(opts.roms.sys_6000_6FFF, rom[0x6000..0x7000]);
                cp(opts.roms.sys_7000_7FFF, rom[0x7000..0x8000]);
            }
            return rom;
        }

        fn initGfxRom(opts: Options) [MEMMAP.GFX_ROM_SIZE]u8 {
            var rom: [MEMMAP.GFX_ROM_SIZE]u8 = undefined;
            if (sys == .Pacman) {
                assert(rom.len == 0x2000);
                cp(opts.roms.gfx_0000_0FFF, rom[0x0000..0x1000]);
                cp(opts.roms.gfx_1000_1FFF, rom[0x1000..0x2000]);
            } else {
                assert((sys == .Pengo) and (rom.len == 0x4000));
                cp(opts.roms.gfx_0000_1FFF, rom[0x0000..0x2000]);
                cp(opts.roms.gfx_2000_3FFF, rom[0x2000..0x4000]);
            }
            return rom;
        }

        fn initPRom(opts: Options) [MEMMAP.PROM_SIZE]u8 {
            var rom: [MEMMAP.PROM_SIZE]u8 = undefined;
            cp(opts.roms.prom_0000_001F, rom[0x0000..0x0020]);
            if (sys == .Pacman) {
                assert(rom.len == 0x120);
                cp(opts.roms.prom_0020_011F, rom[0x0020..0x0120]);
            } else {
                assert((sys == .Pengo) and (rom.len == 0x420));
                cp(opts.roms.prom_0020_041F, rom[0x0020..0x420]);
            }
            return rom;
        }

        fn initSoundRom(opts: Options) [MEMMAP.SOUND_ROM_SIZE]u8 {
            var rom: [MEMMAP.SOUND_ROM_SIZE]u8 = undefined;
            cp(opts.roms.sound_0000_00FF, rom[0x0000..0x0100]);
            cp(opts.roms.sound_0100_01FF, rom[0x0100..0x0200]);
            return rom;
        }

        fn initAudio(opts: Options) Audio {
            assert(opts.audio.num_samples <= AUDIO.MAX_SAMPLES);
            assert(opts.audio.sample_rate > 0);
            const period: i32 = @divFloor(CPU_FREQUENCY * AUDIO.SAMPLE_SCALE, opts.audio.sample_rate);
            return .{
                .tick_counter = AUDIO.PERIOD,
                .sample_period = period,
                .sample_counter = period,
                .volume = opts.audio.volume,
                .num_samples = opts.audio.num_samples,
                .sample_pos = 0,
                .callback = opts.audio.callback,
                .rom = initSoundRom(opts),
                .sample_buffer = std.mem.zeroes([AUDIO.MAX_SAMPLES]f32),
            };
        }

        inline fn setNibble(val: u20, data: u8, comptime nibble: u5) u20 {
            const shl = nibble * 4;
            const mask: u20 = 0x0000F << shl;
            return (val & ~mask) | ((@as(u20, data) & 0xF) << shl);
        }

        fn audioWrite(self: *Self, addr: u16, data: u8) void {
            const snd = &self.audio;
            switch (addr) {
                // zig fmt: off
                AUDIO.ADDR_V1_FC0 => { snd.voices[0].counter = setNibble(snd.voices[0].counter, data, 0); },
                AUDIO.ADDR_V1_FC1 => { snd.voices[0].counter = setNibble(snd.voices[0].counter, data, 1); },
                AUDIO.ADDR_V1_FC2 => { snd.voices[0].counter = setNibble(snd.voices[0].counter, data, 2); },
                AUDIO.ADDR_V1_FC3 => { snd.voices[0].counter = setNibble(snd.voices[0].counter, data, 3); },
                AUDIO.ADDR_V1_FC4 => { snd.voices[0].counter = setNibble(snd.voices[0].counter, data, 4); },
                AUDIO.ADDR_V1_WAVE => { snd.voices[0].waveform = @truncate(data); },

                AUDIO.ADDR_V2_FC1 => { snd.voices[1].counter = setNibble(snd.voices[1].counter, data, 1); },
                AUDIO.ADDR_V2_FC2 => { snd.voices[1].counter = setNibble(snd.voices[1].counter, data, 2); },
                AUDIO.ADDR_V2_FC3 => { snd.voices[1].counter = setNibble(snd.voices[1].counter, data, 3); },
                AUDIO.ADDR_V2_FC4 => { snd.voices[1].counter = setNibble(snd.voices[1].counter, data, 4); },
                AUDIO.ADDR_V2_WAVE => { snd.voices[1].waveform = @truncate(data); },

                AUDIO.ADDR_V3_FC1 => { snd.voices[2].counter = setNibble(snd.voices[2].counter, data, 1); },
                AUDIO.ADDR_V3_FC2 => { snd.voices[2].counter = setNibble(snd.voices[2].counter, data, 2); },
                AUDIO.ADDR_V3_FC3 => { snd.voices[2].counter = setNibble(snd.voices[2].counter, data, 3); },
                AUDIO.ADDR_V3_FC4 => { snd.voices[2].counter = setNibble(snd.voices[2].counter, data, 4); },
                AUDIO.ADDR_V3_WAVE => { snd.voices[2].waveform = @truncate(data); },

                AUDIO.ADDR_V1_FQ0 => { snd.voices[0].frequency = setNibble(snd.voices[0].frequency, data, 0); },
                AUDIO.ADDR_V1_FQ1 => { snd.voices[0].frequency = setNibble(snd.voices[0].frequency, data, 1); },
                AUDIO.ADDR_V1_FQ2 => { snd.voices[0].frequency = setNibble(snd.voices[0].frequency, data, 2); },
                AUDIO.ADDR_V1_FQ3 => { snd.voices[0].frequency = setNibble(snd.voices[0].frequency, data, 3); },
                AUDIO.ADDR_V1_FQ4 => { snd.voices[0].frequency = setNibble(snd.voices[0].frequency, data, 4); },
                AUDIO.ADDR_V1_VOLUME => { snd.voices[0].volume = @truncate(data); },

                AUDIO.ADDR_V2_FQ1 => { snd.voices[1].frequency = setNibble(snd.voices[1].frequency, data, 1); },
                AUDIO.ADDR_V2_FQ2 => { snd.voices[1].frequency = setNibble(snd.voices[1].frequency, data, 2); },
                AUDIO.ADDR_V2_FQ3 => { snd.voices[1].frequency = setNibble(snd.voices[1].frequency, data, 3); },
                AUDIO.ADDR_V2_FQ4 => { snd.voices[1].frequency = setNibble(snd.voices[1].frequency, data, 4); },
                AUDIO.ADDR_V2_VOLUME => { snd.voices[1].volume = @truncate(data); },

                AUDIO.ADDR_V3_FQ1 => { snd.voices[2].frequency = setNibble(snd.voices[2].frequency, data, 1); },
                AUDIO.ADDR_V3_FQ2 => { snd.voices[2].frequency = setNibble(snd.voices[2].frequency, data, 2); },
                AUDIO.ADDR_V3_FQ3 => { snd.voices[2].frequency = setNibble(snd.voices[2].frequency, data, 3); },
                AUDIO.ADDR_V3_FQ4 => { snd.voices[2].frequency = setNibble(snd.voices[2].frequency, data, 4); },
                AUDIO.ADDR_V3_VOLUME => { snd.voices[2].volume = @truncate(data); },
                else => unreachable,
                // zig fmt: on
            }
        }

        fn tickAudio(self: *Self) void {
            var snd = &self.audio;
            // tick sound system?
            snd.tick_counter -= 1;
            if (snd.tick_counter == 0) {
                // handle a 96Hz tick
                snd.tick_counter = AUDIO.PERIOD;
                for (&snd.voices) |*voice| {
                    if (self.sound_enable and (voice.frequency > 0)) {
                        voice.counter +%= voice.frequency;
                        // lookup current 4-bit sample from waveform number and the
                        // topmost 5 bits of the 20-bit sample counter, multiply with 4-bit volume
                        const smp_index: u32 = ((@as(u32, voice.waveform) << 5) | ((voice.counter >> 15) & 0x1F)) & 0xFF;
                        // integer sample value now 7-bits and sign bit
                        const val: i8 = (@as(i8, @intCast(snd.rom[smp_index] & 0xF)) - 8) * voice.volume;
                        voice.sample += @floatFromInt(val);
                        voice.sample_div += 128.0;
                    }
                }
            }
            // generate a new sample?
            snd.sample_counter -= AUDIO.SAMPLE_SCALE;
            if (snd.sample_counter < 0) {
                snd.sample_counter += snd.sample_period;
                var sm: f32 = 0.0;
                for (&snd.voices) |*voice| {
                    if (voice.sample_div > 0.0) {
                        sm += voice.sample / voice.sample_div;
                        voice.sample = 0.0;
                        voice.sample_div = 0.0;
                    }
                }
                sm *= snd.volume * 0.333333;
                snd.sample_buffer[snd.sample_pos] = sm;
                snd.sample_pos += 1;
                if (snd.sample_pos == snd.num_samples) {
                    if (snd.callback) |cb| {
                        cb(snd.sample_buffer[0..snd.num_samples]);
                    }
                    snd.sample_pos = 0;
                }
            }
        }
    };
}
