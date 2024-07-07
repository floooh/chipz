const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const common = @import("common");
const memory = common.memory;
const clock = common.clock;
const AudioCallback = common.host.AudioCallback;
const AudioOptions = common.host.AudioOptions;
const DisplayInfo = common.host.DisplayInfo;

const Bus = u64;

// Z80 bus definitions (same for main and sound board)
const CPU_BUS = chips.z80.Pins{
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
    .RETI = 34,
};

// bus definition for the first AY
const PSG0_BUS = chips.ay3891.Pins{
    .DBUS = CPU_BUS.DBUS,
    .BDIR = 35,
    .BC1 = 36,
    .IOA = AY_PORT,
    .IOB = AY_PORT,
};

// bus definition for the second AY
const PSG1_BUS = chips.ay3891.Pins{
    .DBUS = CPU_BUS.DBUS,
    .BDIR = 37,
    .BC1 = 38,
    .IOA = AY_PORT,
    .IOB = AY_PORT,
};

// bus definition for the third AY
const PSG2_BUS = chips.ay3891.Pins{
    .DBUS = CPU_BUS.DBUS,
    .BDIR = 39,
    .BC1 = 40,
    .IOA = AY_PORT,
    .IOB = AY_PORT,
};

// AY IO ports are unused, to preserve pin space we'll just map them all to the same pins
const AY_PORT = .{ 41, 42, 43, 44, 45, 46, 47, 48 };

// type definitions
const Memory = memory.Memory(Bombjack.MEM.PAGE_SIZE);
const Z80 = chips.z80.Z80(CPU_BUS, Bus);
const PSG0 = chips.ay3891.AY3891(.AY38910, PSG0_BUS, Bus);
const PSG1 = chips.ay3891.AY3891(.AY38910, PSG1_BUS, Bus);
const PSG2 = chips.ay3891.AY3891(.AY38910, PSG2_BUS, Bus);

pub const Bombjack = struct {
    const Self = @This();

    // system init options
    pub const Options = struct {
        audio: AudioOptions,
        roms: struct {
            main_0000_1FFF: []const u8, // main-board ROM 0x0000..0x1FFF
            main_2000_3FFF: []const u8, // main-board ROM 0x2000..0x3FFF
            main_4000_5FFF: []const u8, // main-board ROM 0x4000..0x5FFF
            main_6000_7FFF: []const u8, // main-board ROM 0x6000..0x7FFF
            main_C000_DFFF: []const u8, // main-board ROM 0xC000..0xDFFF
            sound_0000_1FFF: []const u8, // sound-board ROM 0x0000..0x2000
            chars_0000_0FFF: []const u8, // char ROM 0x0000..0x0FFF
            chars_1000_1FFF: []const u8, // char ROM 0x1000..0x1FFF
            chars_2000_2FFF: []const u8, // char ROM 0x2000..0x2FFF
            tiles_0000_1FFF: []const u8, // tile ROM 0x0000..0x1FFF
            tiles_2000_3FFF: []const u8, // tile ROM 0x2000..0x3FFF
            tiles_4000_5FFF: []const u8, // tile ROM 0x4000..0x5FFF
            sprites_0000_1FFF: []const u8, // sprite ROM 0x0000..0x1FFF
            sprites_2000_3FFF: []const u8, // sprite ROM 0x2000..0x3FFF
            sprites_4000_5FFF: []const u8, // sprite ROM 0x4000..0x5FFF
            maps_0000_0FFF: []const u8, // map ROM 0x0000..0x0FFF
        },
    };

    // general constants
    const MAINBOARD_FREQUENCY = 4000000; // 4.0 MHz
    const SOUNDBOARD_FREQUENCY = 3000000; // 3.0 MHz
    const PSG_FREQUENCY = SOUNDBOARD_FREQUENCY / 2; // 1.5 MHz
    const VSYNC_PERIOD_4MHZ = MAINBOARD_FREQUENCY / 60;
    const VSYNC_PERIOD_3MHZ = SOUNDBOARD_FREQUENCY / 60;
    const VBLANK_DURATION_4MHZ = (VSYNC_PERIOD_4MHZ * (525 - 483)) / 525;

    // display constants
    const DISPLAY = struct {
        const WIDTH = 256;
        const HEIGHT = 256;
        const FB_WIDTH = 256;
        const FB_HEIGHT = 288; // save space for sprites
    };

    // audio constants
    const AUDIO = struct {
        const MAX_SAMPLES = 256;
    };

    // memory related constants
    const MEM = struct {
        const PAGE_SIZE = 0x0400;
        const MAIN_RAM_SIZE = 0x1C00;
        const SOUND_RAM_SIZE = 0x0400;
        const MAIN_ROM_SIZE = 5 * 0x2000;
        const SOUND_ROM_SIZE = 0x2000;
        const CHARS_ROM_SIZE = 3 * 0x1000;
        const TILES_ROM_SIZE = 3 * 0x2000;
        const SPRITES_ROM_SIZE = 3 * 0x2000;
        const MAPS_ROM_SIZE = 0x1000;
    };

    // joystick mask bits
    pub const JOY = struct {
        pub const RIGHT: u8 = (1 << 0);
        pub const LEFT: u8 = (1 << 1);
        pub const UP: u8 = (1 << 2);
        pub const DOWN: u8 = (1 << 3);
        pub const BUTTON: u8 = (1 << 4);
    };

    // system  mask bits
    pub const SYS = struct {
        pub const P1_COIN: u8 = (1 << 0);
        pub const P2_COIN: u8 = (1 << 1);
        pub const P1_START: u8 = (1 << 2);
        pub const P2_START: u8 = (1 << 3);
    };

    // DIP switches 1
    pub const DSW1 = struct {
        pub const P1_MASK: u8 = (3 << 0);
        pub const P1_1COIN_1PLAY: u8 = (0 << 0);
        pub const P1_1COIN_2PLAY: u8 = (1 << 0);
        pub const P1_1COIN_3PLAY: u8 = (2 << 0);
        pub const P1_1COIN_5PLAY: u8 = (3 << 0);

        pub const P2_MASK: u8 = (3 << 2);
        pub const P2_1COIN_1PLAY: u8 = (0 << 2);
        pub const P2_1COIN_2PLAY: u8 = (1 << 2);
        pub const P2_1COIN_3PLAY: u8 = (2 << 2);
        pub const P2_1COIN_5PLAY: u8 = (3 << 2);

        pub const JACKS_MASK: u8 = (3 << 4);
        pub const JACKS_3: u8 = (0 << 4);
        pub const JACKS_4: u8 = (1 << 4);
        pub const JACKS_5: u8 = (2 << 4);
        pub const JACKS_2: u8 = (3 << 4);

        pub const CABINET_MASK: u8 = (1 << 6);
        pub const CABINET_COCKTAIL: u8 = (0 << 6);
        pub const CABINET_UPRIGHT: u8 = (1 << 6);

        pub const DEMOSOUND_MASK: u8 = (1 << 7);
        pub const DEMOSOUND_OFF: u8 = (0 << 7);
        pub const DEMOSOUND_ON: u8 = (1 << 7);

        pub const DEFAULT: u8 = CABINET_UPRIGHT | DEMOSOUND_ON;
    };

    // DIP switches 2
    pub const DSW2 = struct {
        pub const BIRDSPEED_MASK: u8 = (3 << 3);
        pub const BIRDSPEED_EASY: u8 = (0 << 3);
        pub const BIRDSPEED_MODERATE: u8 = (1 << 3);
        pub const BIRDSPEED_HARD: u8 = (2 << 3);
        pub const BIRDSPEED_HARDER: u8 = (3 << 3);

        pub const DIFFICULTY_MASK: u8 = (3 << 5);
        pub const DIFFICULTY_MODERATE: u8 = (0 << 5);
        pub const DIFFICULTY_EASY: u8 = (1 << 5);
        pub const DIFFICULTY_HARD: u8 = (2 << 5);
        pub const DIFFICULTY_HARDER: u8 = (3 << 5);

        pub const SPECIALCOIN_MASK: u8 = (1 << 7);
        pub const SPECIALCOIN_EASY: u8 = (0 << 7);
        pub const SPECIALCOIN_HARD: u8 = (1 << 7);

        const DEFAULT: u8 = DIFFICULTY_EASY;
    };

    const MainBoard = struct {
        cpu: Z80,
        p1: u8 = 0,
        p2: u8 = 0,
        sys: u8 = 0,
        dsw1: u8 = DSW1.DEFAULT,
        dsw2: u8 = DSW2.DEFAULT,
        nmi_mask: u8 = 0, // if 0 no NMIs are generated
        bg_image: u8 = 0, // current background image
        vsync_count: u32 = 0,
        vblank_count: u32 = 0,
        mem: Memory,
        palette: [128]u32,
    };

    pub const SoundBoard = struct {
        cpu: Z80,
        psg0: PSG0,
        psg1: PSG1,
        psg2: PSG2,
        vsync_count: u32 = 0,
        mem: Memory,
    };

    pub const Audio = struct {
        volume: f32,
        num_samples: u32,
        sample_pos: u32,
        callback: AudioCallback,
        sample_buffer: [AUDIO.MAX_SAMPLES]f32,
    };

    main_board: MainBoard,
    sound_board: SoundBoard,
    sound_latch: u8 = 0,

    ram: struct {
        main: [MEM.MAIN_RAM_SIZE]u8,
        sound: [MEM.SOUND_RAM_SIZE]u8,
    },
    rom: struct {
        main: [MEM.MAIN_ROM_SIZE]u8,
        sound: [MEM.SOUND_ROM_SIZE]u8,
        chars: [MEM.CHARS_ROM_SIZE]u8,
        tiles: [MEM.TILES_ROM_SIZE]u8,
        sprites: [MEM.SPRITES_ROM_SIZE]u8,
        maps: [MEM.MAPS_ROM_SIZE]u8,
    },
    audio: Audio,
    fb: [DISPLAY.FB_WIDTH * DISPLAY.FB_HEIGHT]u32 align(128),
    junk_page: [Memory.PAGE_SIZE]u8,
    unmapped_page: [Memory.PAGE_SIZE]u8,

    pub fn initInPlace(self: *Self, opts: Options) void {
        self.* = .{
            .main_board = .{
                .cpu = .{},
                .vsync_count = VSYNC_PERIOD_4MHZ,
                .mem = Memory.init(.{
                    .junk_page = &self.junk_page,
                    .unmapped_page = &self.unmapped_page,
                }),
                .palette = std.mem.zeroes(@TypeOf(self.main_board.palette)),
            },
            .sound_board = .{
                .cpu = .{},
                .psg0 = PSG0.init(.{
                    .tick_hz = PSG_FREQUENCY,
                    .sound_hz = @intCast(opts.audio.sample_rate),
                    .volume = 0.2,
                }),
                .psg1 = PSG1.init(.{
                    .tick_hz = PSG_FREQUENCY,
                    .sound_hz = @intCast(opts.audio.sample_rate),
                    .volume = 0.2,
                }),
                .psg2 = PSG2.init(.{
                    .tick_hz = PSG_FREQUENCY,
                    .sound_hz = @intCast(opts.audio.sample_rate),
                    .volume = 0.2,
                }),
                .vsync_count = VSYNC_PERIOD_3MHZ,
                .mem = Memory.init(.{
                    .junk_page = &self.junk_page,
                    .unmapped_page = &self.unmapped_page,
                }),
            },
            .audio = .{
                .num_samples = opts.audio.num_samples,
                .sample_pos = 0,
                .volume = opts.audio.volume,
                .callback = opts.audio.callback,
                .sample_buffer = std.mem.zeroes([AUDIO.MAX_SAMPLES]f32),
            },
            .ram = .{
                .main = std.mem.zeroes(@TypeOf(self.ram.main)),
                .sound = std.mem.zeroes(@TypeOf(self.ram.sound)),
            },
            .rom = .{
                .main = initMainRom(opts),
                .sound = initSoundRom(opts),
                .chars = initCharsRom(opts),
                .tiles = initTilesRom(opts),
                .sprites = initSpritesRom(opts),
                .maps = initMapsRom(opts),
            },
            .fb = std.mem.zeroes(@TypeOf(self.fb)),
            .junk_page = std.mem.zeroes(@TypeOf(self.junk_page)),
            .unmapped_page = [_]u8{0xFF} ** Memory.PAGE_SIZE,
        };
    }

    pub fn displayInfo(selfOrNull: ?*const Self) DisplayInfo {
        return .{
            .fb = .{
                .dim = .{
                    .width = DISPLAY.FB_WIDTH,
                    .height = DISPLAY.FB_HEIGHT,
                },
                .buffer = if (selfOrNull) |self| .{ .Rgba8 = &self.fb } else null,
            },
            .view = .{
                .x = 0,
                .y = 0,
                .width = DISPLAY.WIDTH,
                .height = DISPLAY.HEIGHT,
            },
            .palette = null,
            .orientation = .Portrait,
        };
    }

    fn cp(src: []const u8, dst: []u8) void {
        std.mem.copyForwards(u8, dst, src);
    }

    fn initMainRom(opts: Options) [MEM.MAIN_ROM_SIZE]u8 {
        var rom: [MEM.MAIN_ROM_SIZE]u8 = undefined;
        cp(opts.roms.main_0000_1FFF, rom[0x0000..0x2000]);
        cp(opts.roms.main_2000_3FFF, rom[0x2000..0x4000]);
        cp(opts.roms.main_4000_5FFF, rom[0x4000..0x6000]);
        cp(opts.roms.main_6000_7FFF, rom[0x6000..0x8000]);
        cp(opts.roms.main_C000_DFFF, rom[0x8000..0xA000]);
        return rom;
    }

    fn initSoundRom(opts: Options) [MEM.SOUND_ROM_SIZE]u8 {
        var rom: [MEM.SOUND_ROM_SIZE]u8 = undefined;
        cp(opts.roms.sound_0000_1FFF, rom[0x0000..0x2000]);
        return rom;
    }

    fn initCharsRom(opts: Options) [MEM.CHARS_ROM_SIZE]u8 {
        var rom: [MEM.CHARS_ROM_SIZE]u8 = undefined;
        cp(opts.roms.chars_0000_0FFF, rom[0x0000..0x1000]);
        cp(opts.roms.chars_1000_1FFF, rom[0x1000..0x2000]);
        cp(opts.roms.chars_2000_2FFF, rom[0x2000..0x3000]);
        return rom;
    }

    fn initTilesRom(opts: Options) [MEM.TILES_ROM_SIZE]u8 {
        var rom: [MEM.TILES_ROM_SIZE]u8 = undefined;
        cp(opts.roms.tiles_0000_1FFF, rom[0x0000..0x2000]);
        cp(opts.roms.tiles_2000_3FFF, rom[0x2000..0x4000]);
        cp(opts.roms.tiles_4000_5FFF, rom[0x4000..0x6000]);
        return rom;
    }

    fn initSpritesRom(opts: Options) [MEM.SPRITES_ROM_SIZE]u8 {
        var rom: [MEM.SPRITES_ROM_SIZE]u8 = undefined;
        cp(opts.roms.sprites_0000_1FFF, rom[0x0000..0x2000]);
        cp(opts.roms.sprites_2000_3FFF, rom[0x2000..0x4000]);
        cp(opts.roms.sprites_4000_5FFF, rom[0x4000..0x6000]);
        return rom;
    }

    fn initMapsRom(opts: Options) [MEM.MAPS_ROM_SIZE]u8 {
        var rom: [MEM.MAPS_ROM_SIZE]u8 = undefined;
        cp(opts.roms.maps_0000_0FFF, rom[0x0000..0x1000]);
        return rom;
    }
};
