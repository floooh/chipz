const std = @import("std");
const assert = std.debug.assert;
const z80 = @import("chips").z80;
const memory = @import("common").memory;
const AudioOptions = @import("common").host.AudioOptions;

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
            roms: Roms,

            const Roms = struct {
                common: Common,
                pengo: ?Pengo = null,
                pacman: ?Pacman = null,

                const Common = struct {
                    sys_0000_0FFF: []const u8,
                    sys_1000_1FFF: []const u8,
                    sys_2000_2FFF: []const u8,
                    sys_3000_3FFF: []const u8,
                    prom_0000_001F: []const u8,
                    sound_0000_00FF: []const u8,
                    sound_0100_01FF: []const u8,
                };

                const Pengo = struct {
                    sys_4000_4FFF: []const u8,
                    sys_5000_5FFF: []const u8,
                    sys_6000_6FFF: []const u8,
                    sys_7000_7FFF: []const u8,
                    gfx_0000_1FFF: []const u8,
                    gfx_2000_3FFF: []const u8,
                    prom_0020_041F: []const u8,
                };

                const Pacman = struct {
                    gfx_0000_0FFF: []const u8,
                    gfx_1000_1FFF: []const u8,
                    prom_0020_011F: []const u8,
                };
            };
        };

        pub const VIDEO_RAM_SIZE = 0x0400;
        pub const COLOR_RAM_SIZE = 0x0400;
        pub const MAIN_RAM_SIZE = if (sys == .Pacman) 0x0400 else 0x0800;
        pub const CPU_ROM_SIZE = if (sys == .Pacman) 0x4000 else 0x8000;
        pub const GFX_ROM_SIZE = if (sys == .Pacman) 0x2000 else 0x4000;
        pub const PROM_SIZE = if (sys == .Pacman) 0x120 else 0x0420; // palette and color ROM
        pub const FRAMEBUFFER_WIDTH = 512;
        pub const FRAMEBUFFER_HEIGHT = 224;
        pub const FRAMEBUFFER_SIZE = FRAMEBUFFER_WIDTH * FRAMEBUFFER_HEIGHT;
        pub const DISPLAY_WIDTH = 288;
        pub const DISPLAY_HEIGHT = 224;
        pub const PALETTE_MAP_SIZE = if (sys == .Pacman) 256 else 512;

        cpu: Z80,
        mem: Memory,

        ram_video: [VIDEO_RAM_SIZE]u8,
        ram_color: [COLOR_RAM_SIZE]u8,
        ram_sys: [MAIN_RAM_SIZE]u8,
        rom_sys: [CPU_ROM_SIZE]u8,
        rom_gfx: [GFX_ROM_SIZE]u8,
        rom_prom: [PROM_SIZE]u8,

        hw_colors: [32]u32, // 8-bit colors from pal_rom[0..32] decoded to RGBA8
        pal_map: [PALETTE_MAP_SIZE]u5, // color decoded into indices into hw_colors
        fb: [FRAMEBUFFER_SIZE]u8 align(128), // framebuffer bytes are indices into hw_colors

        junk_page: [Memory.PAGE_SIZE]u8,
        unmapped_page: [Memory.PAGE_SIZE]u8,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .cpu = .{ .pc = 0xF000 }, // execution starts at
                .mem = Memory.init(.{
                    .junk_page = &self.junk_page,
                    .unmapped_page = &self.unmapped_page,
                }),
                .ram_video = std.mem.zeroes(@TypeOf(self.ram_video)),
                .ram_color = std.mem.zeroes(@TypeOf(self.ram_color)),
                .ram_sys = std.mem.zeroes(@TypeOf(self.ram_sys)),
                .rom_sys = initSysRom(opts),
                .rom_gfx = initGfxRom(opts),
                .rom_prom = initPRom(opts),

                // FIXME!
                .hw_colors = std.mem.zeroes(@TypeOf(self.hw_colors)),
                .pal_map = std.mem.zeroes(@TypeOf(self.pal_map)),

                .fb = std.mem.zeroes(@TypeOf(self.fb)),
                .junk_page = std.mem.zeroes(@TypeOf(self.junk_page)),
                .unmapped_page = [_]u8{0xFF} ** Memory.PAGE_SIZE,
            };
        }

        pub fn init(opts: Options) Self {
            var self: Self = undefined;
            self.initInPlace(opts);
            return self;
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
