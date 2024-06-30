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
const AudioOptions = common.host.AudioOptions;

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

pub fn Namco(comptime sys: System) type {
    return struct {
        const Self = @This();

        /// Namco system init options
        pub const Options = struct {
            audio: AudioOptions,
            roms: struct {
                common: struct {
                    sys_0000_0FFF: []const u8,
                    sys_1000_1FFF: []const u8,
                    sys_2000_2FFF: []const u8,
                    sys_3000_3FFF: []const u8,
                    prom_0000_001F: []const u8,
                    sound_0000_00FF: []const u8,
                    sound_0100_01FF: []const u8,
                },
                pengo: ?struct {
                    sys_4000_4FFF: []const u8,
                    sys_5000_5FFF: []const u8,
                    sys_6000_6FFF: []const u8,
                    sys_7000_7FFF: []const u8,
                    gfx_0000_1FFF: []const u8,
                    gfx_2000_3FFF: []const u8,
                    prom_0020_041F: []const u8,
                } = null,
                pacman: ?struct {
                    gfx_0000_0FFF: []const u8,
                    gfx_1000_1FFF: []const u8,
                    prom_0020_011F: []const u8,
                } = null,
            },
        };

        const VIDEO_RAM_SIZE = 0x0400;
        const COLOR_RAM_SIZE = 0x0400;
        const MAIN_RAM_SIZE = if (sys == .Pacman) 0x0400 else 0x0800;
        const ADDR_MASK = if (sys == .Pacman) 0x7FFF else 0xFFFF; // Pacman address bus only has 15 wires
        const IOMAP_BASE = 0x5000;
        const ADDR_SPRITES_ATTR = 0x03F0; // offset of sprite attributes in main RAM
        const CPU_ROM_SIZE = if (sys == .Pacman) 0x4000 else 0x8000;
        const GFX_ROM_SIZE = if (sys == .Pacman) 0x2000 else 0x4000;
        const PROM_SIZE = if (sys == .Pacman) 0x120 else 0x0420; // palette and color ROM
        const FRAMEBUFFER_WIDTH = 512;
        const FRAMEBUFFER_HEIGHT = 224;
        const FRAMEBUFFER_SIZE = FRAMEBUFFER_WIDTH * FRAMEBUFFER_HEIGHT;
        const DISPLAY_WIDTH = 288;
        const DISPLAY_HEIGHT = 224;
        const PALETTE_MAP_SIZE = if (sys == .Pacman) 256 else 512;
        const MASTER_FREQUENCY = 18432000;
        const CPU_FREQUENCY = MASTER_FREQUENCY / 6;
        const VSYNC_PERIOD = CPU_FREQUENCY / 60;

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
                    const SOUND_BASE: u16 = BASE + 0x40;
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
                    const SOUND_BASE: u16 = BASE;
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
        pub const IN0 = switch (sys) {
            .Pacman => struct {
                pub const UP: u8 = 1 << 0;
                pub const LEFT: u8 = 1 << 1;
                pub const RIGHT: u8 = 1 << 2;
                pub const DOWN: u8 = 1 << 3;
                pub const RACK_ADVANCE: u8 = 1 << 4;
                pub const COIN1: u8 = 1 << 5;
                pub const COIN2: u8 = 1 << 6;
                pub const CREDIT: u8 = 1 << 7;
            },
            .Pengo => struct {
                pub const UP: u8 = 1 << 0;
                pub const DOWN: u8 = 1 << 1;
                pub const LEFT: u8 = 1 << 2;
                pub const RIGHT: u8 = 1 << 3;
                pub const COIN1: u8 = 1 << 4;
                pub const COIN2: u8 = 1 << 5;
                pub const COIN3: u8 = 1 << 6; // aka coin-aux, not supported
                pub const BUTTON: u8 = 1 << 7;
            },
        };

        // IN1 bits (active-low)
        pub const IN1 = switch (sys) {
            .Pacman => struct {
                pub const UP: u8 = 1 << 0;
                pub const LEFT: u8 = 1 << 1;
                pub const RIGHT: u8 = 1 << 2;
                pub const DOWN: u8 = 1 << 3;
                pub const BOARD_TEST: u8 = 1 << 4;
                pub const P1_START: u8 = 1 << 5;
                pub const P2_START: u8 = 1 << 6;
            },
            .Pengo => struct {
                pub const UP: u8 = 1 << 0;
                pub const DOWN: u8 = 1 << 1;
                pub const LEFT: u8 = 1 << 2;
                pub const RIGHT: u8 = 1 << 3;
                pub const BOARD_TEST: u8 = 1 << 4;
                pub const P1_START: u8 = 1 << 5;
                pub const P2_START: u8 = 1 << 6;
                pub const BUTTON: u8 = 1 << 7;
            },
        };

        // DSW1 bits (active-high)
        pub const DSW1 = switch (sys) {
            .Pacman => struct {
                pub const COINS_MASK: u8 = 3 << 0;
                pub const COINS_FREE: u8 = 0; // free play
                pub const COINS_1C1G: u8 = 1 << 0; // 1 coin 1 game
                pub const COINS_1C2G: u8 = 2 << 0; // 1 coin 2 games
                pub const COINS_2C1G: u8 = 3 << 0; // 2 coins 1 game
                pub const LIVES_MASK: u8 = 3 << 2;
                pub const LIVES_1: u8 = 0 << 2;
                pub const LIVES_2: u8 = 1 << 2;
                pub const LIVES_3: u8 = 2 << 2;
                pub const LIVES_5: u8 = 3 << 2;
                pub const EXTRALIFE_MASK: u8 = 3 << 4;
                pub const EXTRALIFE_10K: u8 = 0 << 4;
                pub const EXTRALIFE_15K: u8 = 1 << 4;
                pub const EXTRALIFE_20K: u8 = 2 << 4;
                pub const EXTRALIFE_NONE: u8 = 3 << 4;
                pub const DIFFICULTY_MASK: u8 = 1 << 6;
                pub const DIFFICULTY_HARD: u8 = 0 << 6;
                pub const DIFFICULTY_NORM: u8 = 1 << 6;
                pub const GHOSTNAMES_MASK: u8 = 1 << 7;
                pub const GHOSTNAMES_ALT: u8 = 0 << 7;
                pub const GHOSTNAMES_NORM: u8 = 1 << 7;
                pub const DEFAULT: u8 = COINS_1C1G | LIVES_3 | EXTRALIFE_15K | DIFFICULTY_NORM | GHOSTNAMES_NORM;
            },
            .Pengo => struct {
                pub const EXTRALIFE_MASK: u8 = 1 << 0;
                pub const EXTRALIFE_30K: u8 = 0 << 0;
                pub const EXTRALIFE_50K: u8 = 1 << 0;
                pub const DEMOSOUND_MASK: u8 = 1 << 1;
                pub const DEMOSOUND_ON: u8 = 0 << 1;
                pub const DEMOSOUND_OFF: u8 = 1 << 1;
                pub const CABINET_MASK: u8 = 1 << 2;
                pub const CABINET_UPRIGHT: u8 = 0 << 2;
                pub const CABINET_COCKTAIL: u8 = 1 << 2;
                pub const LIVES_MASK: u8 = 3 << 3;
                pub const LIVES_2: u8 = 0 << 3;
                pub const LIVES_3: u8 = 1 << 3;
                pub const LIVES_4: u8 = 2 << 3;
                pub const LIVES_5: u8 = 3 << 3;
                pub const RACKTEST_MASK: u8 = 1 << 5;
                pub const RACKTEST_ON: u8 = 0 << 5;
                pub const RACKTEST_OFF: u8 = 1 << 5;
                pub const DIFFICULTY_MASK: u8 = 3 << 6;
                pub const DIFFICULTY_EASY: u8 = 0 << 6;
                pub const DIFFICULTY_MEDIUM: u8 = 1 << 6;
                pub const DIFFICULTY_HARD: u8 = 2 << 6;
                pub const DIFFICULTY_HARDEST: u8 = 3 << 6;
                pub const DEFAULT: u8 = EXTRALIFE_30K | DEMOSOUND_ON | CABINET_UPRIGHT | LIVES_3 | RACKTEST_OFF | DIFFICULTY_MEDIUM;
            },
        };

        // DSW2 bits (active-high)
        pub const DSW2 = switch (sys) {
            .Pacman => struct {
                pub const DEFAULT: u8 = 0;
            },
            .Pengo => struct {
                pub const COINA_MASK: u8 = 0xF << 0; // 16 combinations of N coins -> M games
                pub const COINA_1C1G: u8 = 0xC << 0;
                pub const COINB_MASK: u8 = 0xF << 4;
                pub const COINB_1C1G: u8 = 0xC << 4;
                pub const DEFAULT: u8 = COINA_1C1G | COINB_1C1G;
            },
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
        pal_select: u1 = 0, // Pengo only
        clut_select: u1 = 0, // Pengo only
        tile_select: u1 = 0, // Pengo only
        sprite_coords: [16]u8, // 8 sprites x/y pairs
        vsync_count: u32 = VSYNC_PERIOD,

        ram: struct {
            video: [VIDEO_RAM_SIZE]u8,
            color: [COLOR_RAM_SIZE]u8,
            main: [MAIN_RAM_SIZE]u8,
        },
        rom: struct {
            cpu: [CPU_ROM_SIZE]u8,
            gfx: [GFX_ROM_SIZE]u8,
            prom: [PROM_SIZE]u8,
        },

        hw_colors: [32]u32, // 8-bit colors from pal_rom[0..32] decoded to RGBA8
        pal_map: [PALETTE_MAP_SIZE]u4, // indirect indices into hw_colors (u4 is not a but, Pengo has an additon pal_select bit)
        fb: [FRAMEBUFFER_SIZE]u8 align(128), // framebuffer bytes are indices into hw_colors

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

                // FIXME!
                .hw_colors = decodeHwColors(&self.rom.prom),
                .pal_map = decodePaletteMap(&self.rom.prom),

                .fb = std.mem.zeroes(@TypeOf(self.fb)),
                .junk_page = std.mem.zeroes(@TypeOf(self.junk_page)),
                .unmapped_page = [_]u8{0xFF} ** Memory.PAGE_SIZE,
            };
            self.initMemoryMap();
        }

        pub fn init(opts: Options) Self {
            var self: Self = undefined;
            self.initInPlace(opts);
            return self;
        }

        inline fn pin(bus: u64, p: comptime_int) bool {
            return (bus & p) != 0;
        }

        pub fn exec(self: *Self, micro_seconds: u32) u32 {
            const num_ticks = clock.microSecondsToTicks(CPU_FREQUENCY, micro_seconds);
            var bus = self.bus;
            for (0..num_ticks) |_| {
                bus = self.tick(bus);
            }
            self.bus = bus;
            return num_ticks;
        }

        pub fn tick(self: *Self, in_bus: u64) u64 {
            var bus = in_bus;

            // update vscync counter and trigger interrupt
            self.vsync_count -= 1;
            if (self.vsync_count == 0) {
                self.vsync_count = VSYNC_PERIOD;
                if (self.int_enable) {
                    bus |= Z80.INT;
                }
            }

            // FIXME: tick sound

            // tick the CPU
            bus = self.cpu.tick(bus);
            const addr = Z80.getAddr(bus) & ADDR_MASK;
            if (pin(bus, Z80.MREQ)) {
                if (pin(bus, Z80.WR)) {
                    const data = Z80.getData(bus);
                    if (addr < MEMIO.BASE) {
                        // a regular memory write
                        self.mem.wr(addr, data);
                    } else {
                        // a memory-mapped IO write
                        if (addr == MEMIO.WR.INT_ENABLE) {
                            self.int_enable = (data & 1) != 0;
                        } else if (addr == MEMIO.WR.SOUND_ENABLE) {
                            self.sound_enable = (data & 1) != 0;
                        } else if (addr == MEMIO.WR.FLIP_SCREEN) {
                            self.flip_screen = (data & 1) != 0;
                        } else if (sys == .Pengo and addr == MEMIO.WR.PAL_SELECT) {
                            self.pal_select = data & 1;
                        } else if (sys == .Pengo and addr == MEMIO.WR.CLUT_SELECT) {
                            self.clut_select = data & 1;
                        } else if (sys == .Pengo and addr == MEMIO.WR.TILE_SELECT) {
                            self.tile_select = data & 1;
                        } else if (addr >= MEMIO.WR.SOUND_BASE and addr < (MEMIO.WR.SOUND_BASE + 0x20)) {
                            // FIXME: self.soundWrite(addr, data);
                        } else if (addr >= MEMIO.WR.SPRITES_BASE and addr < (MEMIO.WR.SPRITES_BASE + 0x10)) {
                            self.sprite_coords[addr & 0x000F] = data;
                        }
                    }
                } else if (pin(bus, Z80.RD)) {
                    if (addr < MEMIO.BASE) {
                        // a regular memory read
                        bus = Z80.setData(bus, self.mem.rd(addr));
                    } else {
                        // FIXME: IN0, IN1, DSW1 are mirrored for 0x40 bytes
                        const data: u8 = switch (addr) {
                            MEMIO.RD.IN0 => ~self.in0,
                            MEMIO.RD.IN1 => ~self.in1,
                            MEMIO.RD.DSW1 => self.dsw1,
                            else => if (sys == .Pengo and addr == MEMIO.RD.DSW2) self.dsw2 else 0xFF,
                        };
                        bus = Z80.setData(bus, data);
                    }
                }
            } else if (pin(bus, Z80.IORQ)) {
                if (pin(bus, Z80.WR)) {
                    if ((addr & 0x00FF) == 0) {
                        // OUT to port 0: set interrupt vector latch
                        self.int_vector = Z80.getData(bus);
                    }
                } else if (pin(bus, Z80.M1)) {
                    // an interrupt machine cycle, set interrupt vector on data bus
                    // and clear the interrupt pin
                    bus = Z80.setData(bus, self.int_vector) & ~Z80.INT;
                }
            }
            return bus;
        }

        /// decode 8-bit ROM colors into 32-bit RGBA8
        fn decodeHwColors(prom: []const u8) [32]u32 {
            // Each color ROM entry describes an RGB color in 1 byte:
            //
            // | 7| 6| 5| 4| 3| 2| 1| 0|
            // |B1|B0|G2|G1|G0|R2|R1|R0|
            //
            // Intensities are: 0x97 + 0x47 + 0x21
            var rgba8: [32]u32 = undefined;
            for (0..0x20) |i| {
                const rgb: u8 = prom[i];
                const r: u32 = ((rgb >> 0) & 1) * 0x21 + ((rgb >> 1) & 1) * 0x47 + ((rgb >> 2) & 1) * 0x97;
                const g: u32 = ((rgb >> 3) & 1) * 0x21 + ((rgb >> 4) & 1) * 0x47 + ((rgb >> 5) & 1) & 0x97;
                const b: u32 = ((rgb >> 6) & 1) * 0x47 + ((rgb >> 7) & 1) * 0x97;
                rgba8[i] = 0xFF000000 | (b << 16) | (g << 8) | r;
            }
            return rgba8;
        }

        // decode PROM palette map
        fn decodePaletteMap(prom: []const u8) [PALETTE_MAP_SIZE]u4 {
            var map: [PALETTE_MAP_SIZE]u4 = undefined;
            for (0..256) |i| {
                const pal_index: u4 = @truncate(prom[i + 0x20] & 0x0F);
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

        fn initSysRom(opts: Options) [CPU_ROM_SIZE]u8 {
            var rom: [CPU_ROM_SIZE]u8 = undefined;
            if (sys == .Pacman) {
                assert(rom.len == 0x4000);
            }
            cp(opts.roms.common.sys_0000_0FFF, rom[0x0000..0x1000]);
            cp(opts.roms.common.sys_1000_1FFF, rom[0x1000..0x2000]);
            cp(opts.roms.common.sys_2000_2FFF, rom[0x2000..0x3000]);
            cp(opts.roms.common.sys_3000_3FFF, rom[0x3000..0x4000]);
            if (sys == .Pengo) {
                assert((sys == .Pengo) and (rom.len == 0x8000));
                cp(opts.roms.pengo.?.sys_4000_4FFF, rom[0x4000..0x5000]);
                cp(opts.roms.pengo.?.sys_5000_5FFF, rom[0x5000..0x6000]);
                cp(opts.roms.pengo.?.sys_6000_6FFF, rom[0x6000..0x7000]);
                cp(opts.roms.pengo.?.sys_7000_7FFF, rom[0x7000..0x8000]);
            }
            return rom;
        }

        fn initGfxRom(opts: Options) [GFX_ROM_SIZE]u8 {
            var rom: [GFX_ROM_SIZE]u8 = undefined;
            if (sys == .Pacman) {
                assert(rom.len == 0x2000);
                cp(opts.roms.pacman.?.gfx_0000_0FFF, rom[0x0000..0x1000]);
                cp(opts.roms.pacman.?.gfx_1000_1FFF, rom[0x1000..0x2000]);
            } else {
                assert((sys == .Pengo) and (rom.len == 0x4000));
                cp(opts.roms.pengo.?.gfx_0000_1FFFF, rom[0x0000..0x2000]);
                cp(opts.roms.pengo.?.gfx_2000_3FFFF, rom[0x2000..0x4000]);
            }
            return rom;
        }

        fn initPRom(opts: Options) [PROM_SIZE]u8 {
            var rom: [PROM_SIZE]u8 = undefined;
            cp(opts.roms.common.prom_0000_001F, rom[0x0000..0x0020]);
            if (sys == .Pacman) {
                assert(rom.len == 0x120);
                cp(opts.roms.pacman.?.prom_0020_011F, rom[0x0020..0x0120]);
            } else {
                assert((sys == .Pengo) and (rom.len == 0x420));
                cp(opts.roms.pengo.?.prom_0020_041F, rom[0x0020..0x420]);
            }
            return rom;
        }
    };
}
