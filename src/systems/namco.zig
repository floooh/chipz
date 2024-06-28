const z80 = @import("chips").z80;
const memory = @import("common").memory;

//! the emulated arcade machine type
pub const System = enum {
    Pacman,
    Pengo,
};

// bus wire definitions

const Z80_PINS = z80.Pins{
    .DBUS = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    .ABUS = .{ 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 };
    .M1 = 24;
    .MREQ = 25;
    .IORQ = 26;
    .RD = 27;
    .WR = 28;
    .RFSH = 29;
    .HALT = 30;
    .WAIT = 31;
    .INT = 32;
    .NMI = 33;
    .RETI = 35;
};

// setup types
const Z80 = z80.Z80(Z80_PINS, u64);
const Memory = memory.Memory(0x400);

pub fn Namco(comptime sys: System) type {

    return struct {

        const VIDEO_RAM_SIZE = 0x0400;
        const COLOR_RAM_SIZE = 0x0400;
        const MAIN_RAM_IZE = if (sys == .Pacman) 0x0400 else 0x0800;
        const CPU_ROM_SIZE = if (sys == .Pacman) 0x4000 else 0x8000;
        const GFX_ROM_SIZE = if (sys == .Pacman) 0x2000 else 0x4000;
        const COLOR_ROM_SIZE = 0x0420;  // palette and color ROM
        const FRAMEBUFFER_WIDTH = 512;
        const FRAMEBUFFER_HEIGHT = 224;
        const FRAMEBUFFER_SIZE = FRAMEBUFFER_WIDTH * FRAMEBUFFER_HEIGHT;
        const DISPLAY_WIDTH = 288;
        const DISPLAY_HEIGHT = 224;
        const PALETTE_MAP_SIZE = if (sys == .Pacman) 256 else 512;

        cpu: Z80,
        mem: Memory,

        video_ram: [VIDEO_RAM_SIZE]u8,
        color_ram: [COLOR_RAM_SIZE]u8,
        main_ram: [MAIN_RAM_SIZE]u8,
        cpu_rom: [CPU_ROM_SIZE]u8,
        gfx_rom: [GFX_ROM_SIZE]u8,
        pal_rom: [COLOR_ROM_SIZE]u8,

        hw_colors: [32]u32, // 8-bit colors from pal_rom[0..32] decoded to RGBA8
        pal_map: [PAL_MAP_SIZE]u5,  // color decoded into indices into hw_colors
        fb: align(64) [FRAMEBUFFER_SIZE]u8, // indices into hw_colors
    };
}