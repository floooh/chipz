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
const Memory = memory.Memory(0x0400);
const Z80 = chips.z80.Z80(CPU_BUS, Bus);
const PSG0 = chips.ay3891.AY3891(.AY38910, PSG0_BUS, Bus);
const PSG1 = chips.ay3891.AY3891(.AY38910, PSG1_BUS, Bus);
const PSG2 = chips.ay3891.AY3891(.AY38910, PSG2_BUS, Bus);

const getData = Z80.getData;
const setData = Z80.setData;
const getAddr = Z80.getAddr;
const NMI = Z80.NMI;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RD = Z80.RD;
const WR = Z80.WR;

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
        bus: Bus = 0,
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
        bus: Bus = 0,
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
        main: [0x1C00]u8,
        sound: [0x0400]u8,
    },
    rom: struct {
        main: [5][0x2000]u8,
        sound: [0x2000]u8,
        chars: [3][0x1000]u8,
        tiles: [3][0x2000]u8,
        sprites: [3][0x2000]u8,
        maps: [0x1000]u8,
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
        self.initMemoryMap();
    }

    // FIXME: initAlloc()?

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

    // Run the main board and sound board interleaved for half a frame.
    // This simplifies the communication via the sound latch (the main CPU
    // writes a command byte to the sound latch, the sound board reads
    // the command latch in its interrupt service routine.
    //
    // The main board issues at most one command per 60Hz frame, but since the
    // host machine is also running at roughly 60 Hz it may happen that the
    // main board writes 2 sound commands per host frame. For this reason
    // run the 2 boards interleaved for half a frame, so it is guaranteed
    // that at most one sound command can be written by the main board
    // before the sound board is ticked (that way we don't need to implement
    // a complicated command queue.
    //
    // NOTE: with the new cycle-stepped Z80 we could just as well do
    // a much more finer grained interleaving (e.g. per tick), but this
    // turns out to be quite a bit slower.
    //
    pub fn exec(self: *Self, micro_seconds: u32) u32 {
        const half_us = micro_seconds / 2;
        const mb_num_ticks = clock.microSecondsToTicks(MAINBOARD_FREQUENCY, half_us);
        const sb_num_ticks = clock.microSecondsToTicks(SOUNDBOARD_FREQUENCY, half_us);
        for (0..2) |_| {
            // tick main board
            var bus = self.main_board.bus;
            for (0..mb_num_ticks) |_| {
                bus = self.tickMainBoard(bus);
            }
            self.main_board.bus = bus;

            // tick sound board
            bus = self.sound_board.bus;
            for (0..sb_num_ticks) |_| {
                bus = self.tickSoundBoard(bus);
            }
            self.sound_board.bus = bus;
        }
        self.decodeVideo();
        return 2 * (mb_num_ticks + sb_num_ticks);
    }

    inline fn pin(bus: u64, p: comptime_int) bool {
        return (bus & p) != 0;
    }

    fn tickMainBoard(self: *Self, in_bus: Bus) Bus {
        var bus = in_bus;
        var board: *MainBoard = &self.main_board;

        // activate NMI pin during vblank
        if (board.vblank_count > 0) {
            board.vblank_count -= 1;
        }
        board.vsync_count -= 1;
        if (board.vsync_count == 0) {
            board.vsync_count = VSYNC_PERIOD_4MHZ;
            board.vblank_count = VBLANK_DURATION_4MHZ;
        }
        if ((board.nmi_mask != 0) and (board.vblank_count > 0)) {
            bus |= NMI;
        } else {
            bus &= ~NMI;
        }

        // tick the CPU
        bus = board.cpu.tick(bus);

        // handle memory requests
        //
        // In hardware, the address decoding is mostly implemented
        // with cascaded 1-in-4 and 1-in-8 decoder chips. We'll take
        // a little shortcut and just check for the expected address ranges.
        if (pin(bus, MREQ)) {
            const addr = getAddr(bus);
            if (pin(bus, WR)) {
                // memory write access
                const data = getData(bus);
                switch (addr) {
                    0x8000...0x98FF => board.mem.wr(addr, data),
                    0x9C00...0x9D00 => self.updatePaletteCache(addr, data),
                    0x9E00 => board.bg_image = data,
                    0xB000 => board.nmi_mask = data,
                    // FIXME: 0xB004 flip screen
                    0xB800 => self.sound_latch = data,
                    else => {},
                }
            } else if (pin(bus, RD)) {
                // memory read access
                bus = switch (addr) {
                    0xB000 => setData(bus, board.p1),
                    0xB001 => setData(bus, board.p2),
                    0xB002 => setData(bus, board.sys),
                    0xB004 => setData(bus, board.dsw1),
                    0xB005 => setData(bus, board.dsw2),
                    else => setData(bus, board.mem.rd(addr)),
                };
            }
        }
        // the IORQ pin isn't connected, so no point in checking for IO requests
        return bus;
    }

    fn tickSoundBoard(self: *Self, bus: Bus) Bus {
        _ = self; // autofix
        // FIXME
        return bus;
    }

    fn decodeVideo(self: *Self) void {
        _ = self; // autofix
        // FIXME
    }

    fn updatePaletteCache(self: *Self, addr: u16, data: u8) void {
        assert((addr >= 0x9C00) and (addr < 0x9D00));
        const pal_index = (addr - 0x9C00) / 2;
        var c = self.main_board.palette[pal_index];
        if ((addr & 1) != 0) {
            // uneven addresses are the xxxxBBBB part
            const b: u32 = (data & 0x0F) | ((data << 4) & 0xF0);
            c = 0xFF000000 | (c & 0x0000FFFF) | (b << 16);
        } else {
            // even addresses are the GGGGRRRR part
            const g: u32 = (data & 0xF0) | ((data >> 4) & 0x0F);
            const r: u32 = (data & 0x0F) | ((data << 4) & 0xF0);
            c = 0xFF000000 | (c & 0x00FF0000) | (g << 8) | r;
        }
        self.main_board.palette[pal_index] = c;
    }

    fn cp(src: []const u8, dst: []u8) void {
        std.mem.copyForwards(u8, dst, src);
    }

    fn initMainRom(opts: Options) [5][0x2000]u8 {
        var rom: [5][0x2000]u8 = undefined;
        cp(opts.roms.main_0000_1FFF, &rom[0]);
        cp(opts.roms.main_2000_3FFF, &rom[1]);
        cp(opts.roms.main_4000_5FFF, &rom[2]);
        cp(opts.roms.main_6000_7FFF, &rom[3]);
        cp(opts.roms.main_C000_DFFF, &rom[4]);
        return rom;
    }

    fn initSoundRom(opts: Options) [0x2000]u8 {
        var rom: [0x2000]u8 = undefined;
        cp(opts.roms.sound_0000_1FFF, &rom);
        return rom;
    }

    fn initCharsRom(opts: Options) [3][0x1000]u8 {
        var rom: [3][0x1000]u8 = undefined;
        cp(opts.roms.chars_0000_0FFF, &rom[0]);
        cp(opts.roms.chars_1000_1FFF, &rom[1]);
        cp(opts.roms.chars_2000_2FFF, &rom[2]);
        return rom;
    }

    fn initTilesRom(opts: Options) [3][0x2000]u8 {
        var rom: [3][0x2000]u8 = undefined;
        cp(opts.roms.tiles_0000_1FFF, &rom[0]);
        cp(opts.roms.tiles_2000_3FFF, &rom[1]);
        cp(opts.roms.tiles_4000_5FFF, &rom[2]);
        return rom;
    }

    fn initSpritesRom(opts: Options) [3][0x2000]u8 {
        var rom: [3][0x2000]u8 = undefined;
        cp(opts.roms.sprites_0000_1FFF, &rom[0]);
        cp(opts.roms.sprites_2000_3FFF, &rom[1]);
        cp(opts.roms.sprites_4000_5FFF, &rom[2]);
        return rom;
    }

    fn initMapsRom(opts: Options) [0x1000]u8 {
        var rom: [0x1000]u8 = undefined;
        cp(opts.roms.maps_0000_0FFF, &rom);
        return rom;
    }

    fn initMemoryMap(self: *Self) void {
        //  main board memory map:
        //    0000..7FFF: ROM
        //    8000..8FFF: RAM
        //    9000..93FF: video ram
        //    9400..97FF: color ram
        //    9820..987F: sprite ram
        //    9C00..9CFF: palette ram (write-only?)
        //    9E00:       select background (write-only?)
        //    B000:       read: joystick 1, write: NMI mask
        //    B001:       read: joystick 2
        //    B002:       read: coins and start button
        //    B003:       read/write: watchdog reset (not emulated)
        //    B004:       read: dip-switches 1, write: flip screen
        //    B005:       read: dip-switches 2
        //    B800:       sound latch
        //    C000..DFFF: ROM
        //
        //  palette RAM is 128 entries with 16-bit per entry (xxxxBBBBGGGGRRRR).
        //
        //  NOTE that ROM data that's not accessible by CPU isn't accessed
        //  through a memory mapper.
        //
        self.main_board.mem.mapROM(0x0000, 0x2000, &self.rom.main[0]);
        self.main_board.mem.mapROM(0x2000, 0x2000, &self.rom.main[1]);
        self.main_board.mem.mapROM(0x4000, 0x2000, &self.rom.main[2]);
        self.main_board.mem.mapROM(0x6000, 0x2000, &self.rom.main[3]);
        self.main_board.mem.mapRAM(0x8000, 0x1C00, &self.ram.main);
        self.main_board.mem.mapROM(0xC000, 0x2000, &self.rom.main[4]);

        // sound board memory map
        self.sound_board.mem.mapROM(0x0000, 0x2000, &self.rom.sound);
        self.sound_board.mem.mapRAM(0x4000, 0x0400, &self.ram.sound);
    }
};
