const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const common = @import("common");
const memory = common.memory;
const clock = common.clock;
const pin = common.bitutils.pin;
const AudioCallback = common.glue.AudioCallback;
const AudioOptions = common.glue.AudioOptions;
const DisplayInfo = common.glue.DisplayInfo;

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
const Psg0 = chips.ay3891.AY3891(.AY38910, PSG0_BUS, Bus);
const Psg1 = chips.ay3891.AY3891(.AY38910, PSG1_BUS, Bus);
const Psg2 = chips.ay3891.AY3891(.AY38910, PSG2_BUS, Bus);

const getData = Z80.getData;
const setData = Z80.setData;
const getAddr = Z80.getAddr;
const NMI = Z80.NMI;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RD = Z80.RD;
const WR = Z80.WR;
const A0 = Z80.A0;
const A4 = Z80.A4;
const A7 = Z80.A7;

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

    pub const Input = packed struct {
        p1_right: bool = false,
        p1_left: bool = false,
        p1_up: bool = false,
        p1_down: bool = false,
        p1_button: bool = false,
        p1_coin: bool = false,
        p1_start: bool = false,
        p2_right: bool = false,
        p2_left: bool = false,
        p2_up: bool = false,
        p2_down: bool = false,
        p2_button: bool = false,
        p2_coin: bool = false,
        p2_start: bool = false,
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
        tick_count: u32 = 0,
        psg0: Psg0,
        psg1: Psg1,
        psg2: Psg2,
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
                .psg0 = Psg0.init(.{
                    .tick_hz = PSG_FREQUENCY,
                    .sound_hz = @intCast(opts.audio.sample_rate),
                    .volume = 0.3,
                }),
                .psg1 = Psg1.init(.{
                    .tick_hz = PSG_FREQUENCY,
                    .sound_hz = @intCast(opts.audio.sample_rate),
                    .volume = 0.3,
                }),
                .psg2 = Psg2.init(.{
                    .tick_hz = PSG_FREQUENCY,
                    .sound_hz = @intCast(opts.audio.sample_rate),
                    .volume = 0.3,
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

    pub fn setInput(self: *Self, inp: Input) void {
        self.setClearInput(inp, true);
    }

    pub fn clearInput(self: *Self, inp: Input) void {
        self.setClearInput(inp, false);
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

    fn tickSoundBoard(self: *Self, in_bus: Bus) Bus {
        var bus = in_bus;
        var board: *SoundBoard = &self.sound_board;

        // vsync triggers a flip-flop connected to the CPU's NMI, the flip-flop
        // is reset on a read from address 0x6000 (this read happens in the
        // interrupt service routine
        board.vsync_count -= 1;
        if (board.vsync_count == 0) {
            board.vsync_count = VSYNC_PERIOD_3MHZ;
            bus |= NMI;
        }

        // tick the sound board CPU
        bus = board.cpu.tick(bus);

        // handle memory and IO requests
        if (pin(bus, MREQ)) {
            const addr = getAddr(bus);
            if (pin(bus, RD)) {
                // special case: read and clear sound latch and NMI flip-flop
                if (addr == 0x6000) {
                    bus = setData(bus, self.sound_latch);
                    self.sound_latch = 0;
                    bus &= ~NMI;
                } else {
                    // regular memory read
                    bus = setData(bus, board.mem.rd(addr));
                }
            } else if (pin(bus, WR)) {
                // regular memory write
                board.mem.wr(addr, getData(bus));
            }
        } else if (pin(bus, IORQ)) {
            // For IO address decoding, see schematics page 9 and 10:
            //
            // PSG1, PSG2 and PSG3 are selected through a
            // LS-138 1-of-4 decoder from address lines 4 and 7:
            //
            // A7 A4
            // 0  0   -> PSG 1
            // 0  1   -> PSG 2
            // 1  0   -> PSG 3
            // 1  1   -> not connected
            //
            // A0 is connected to BC1(!) (I guess that's an error in the
            // schematics since these show BC2).
            //
            switch (bus & (A7 | A4)) {
                0 => { // PSG0
                    if (pin(bus, WR)) bus |= Psg0.BDIR;
                    if (!pin(bus, A0)) bus |= Psg0.BC1;
                },
                A4 => { // PSG1
                    if (pin(bus, WR)) bus |= Psg1.BDIR;
                    if (!pin(bus, A0)) bus |= Psg1.BC1;
                },
                A7 => {
                    if (pin(bus, WR)) bus |= Psg2.BDIR;
                    if (!pin(bus, A0)) bus |= Psg2.BC1;
                },
                else => {},
            }
        }

        // tick the AY chips at half frequency
        board.tick_count +%= 1;
        if ((board.tick_count & 1) == 0) {
            bus = board.psg0.tick(bus);
            bus = board.psg1.tick(bus);
            bus = board.psg2.tick(bus);

            // clear AY control bits (this cannot happen each CPU tick because
            // the AY chips are clocked at half frequency and might miss them)
            bus &= ~(Psg0.BDIR | Psg0.BC1 | Psg1.BDIR | Psg1.BC1 | Psg2.BDIR | Psg2.BC1);

            if (board.psg0.sample.ready) {
                const s = board.psg0.sample.value + board.psg1.sample.value + board.psg2.sample.value;
                self.audio.sample_buffer[self.audio.sample_pos] = s * self.audio.volume;
                self.audio.sample_pos += 1;
                if (self.audio.sample_pos == self.audio.num_samples) {
                    if (self.audio.callback) |cb| {
                        cb(self.audio.sample_buffer[0..self.audio.num_samples]);
                    }
                    self.audio.sample_pos = 0;
                }
            }
        }

        return bus;
    }

    // helper function to gather 16 bits of tile data from tile rom
    inline fn gather16(rom: []const u8, offset: usize) u16 {
        return (@as(u16, rom[offset]) << 8) | rom[8 + offset];
    }

    // helper function to gather 32 bits of tile data from tile rom
    inline fn gather32(rom: []const u8, offset: usize) u32 {
        return (@as(u32, rom[offset]) << 24) |
            (@as(u32, rom[offset + 8]) << 16) |
            (@as(u32, rom[offset + 32]) << 8) |
            (@as(u32, rom[offset + 40]) << 0);
    }

    // render background tiles
    //
    // Background tiles are 16x16 pixels, and the screen is made of
    // 16x16 tiles. A background images consists of 16x16=256 tile
    // 'char codes', followed by 256 color code bytes. So each background
    // image occupies 512 (0x200) bytes in the 'map rom'.
    //
    // The map-rom is 4 KByte, room for 8 background images (although I'm
    // not sure yet whether all 8 are actually used). The background
    // image number is written to address 0x9E00 (only the 3 LSB bits are
    // considered). If bit 4 is cleared, no background image is shown
    // (all tile codes are 0).
    //
    // A tile's image is created from 3 bitmaps, each bitmap stored in
    // 32 bytes with the following layout (the numbers are the byte index,
    // each byte contains the bitmap pattern for 8 pixels):
    //
    // 0: +--------+   8: +--------+
    // 1: +--------+   9: +--------+
    // 2: +--------+   10:+--------+
    // 3: +--------+   11:+--------+
    // 4: +--------+   12:+--------+
    // 5: +--------+   13:+--------+
    // 6: +--------+   14:+--------+
    // 7: +--------+   15:+--------+
    //
    // 16:+--------+   24:+--------+
    // 17:+--------+   25:+--------+
    // 18:+--------+   26:+--------+
    // 19:+--------+   27:+--------+
    // 20:+--------+   28:+--------+
    // 21:+--------+   29:+--------+
    // 22:+--------+   30:+--------+
    // 23:+--------+   31:+--------+
    //
    // The 3 bitmaps for each tile are 8 KBytes apart (basically each
    // of the 3 background-tile ROM chips contains one set of bitmaps
    // for all 256 tiles).
    //
    // The 3 bitmaps are combined to get the lower 3 bits of the
    // color palette index. The remaining 4 bits of the palette
    // index are provided by the color attribute byte (for 7 bits
    // = 128 color palette entries).
    //
    // This is how a color palette entry is constructed from the 4
    // attribute bits, and 3 tile bitmap bits:
    //
    // |x|attr3|attr2|attr1|attr0|bm0|bm1|bm2|
    //
    // This basically means that each 16x16 background tile
    // can select one of 16 color blocks from the palette, and
    // each pixel of the tile can select one of 8 colors in the
    // tile's color block.
    //
    // Bit 7 in the attribute byte defines whether the tile should
    // be flipped around the Y axis.
    //
    fn decodeBackground(self: *Self) void {
        var fb_idx: usize = 0;
        const fb_width = DISPLAY.FB_WIDTH;
        const img_base_addr: usize = @as(usize, self.main_board.bg_image & 7) * 0x0200;
        const img_valid = (self.main_board.bg_image & 0x10) != 0;
        for (0..16) |y| {
            for (0..16) |x| {
                const addr = img_base_addr + (y * 16 + x);
                const tile_code: usize = if (img_valid) self.rom.maps[addr] else 0;
                const attr = self.rom.maps[addr + 0x0100];
                const color_block: usize = (attr & 0x0F) << 3;
                const flip_y = (attr & 0x80) != 0;
                if (flip_y) {
                    fb_idx +%= 15 * fb_width;
                }
                // every tile is 32 bytes
                var offset = tile_code * 32;
                for (0..16) |yy| {
                    const bm0 = gather16(&self.rom.tiles[0], offset);
                    const bm1 = gather16(&self.rom.tiles[1], offset);
                    const bm2 = gather16(&self.rom.tiles[2], offset);
                    offset += 1;
                    if (yy == 7) {
                        offset += 8;
                    }
                    for (0..16) |ixx| {
                        const xx: u4 = @truncate(15 - ixx);
                        const pen: usize = ((bm2 >> xx) & 1) | (((bm1 >> xx) & 1) << 1) | (((bm0 >> xx) & 1) << 2);
                        self.fb[fb_idx] = self.main_board.palette[color_block | pen];
                        fb_idx +%= 1;
                    }
                    if (flip_y) {
                        fb_idx -%= 272;
                    } else {
                        fb_idx += 240;
                    }
                }
                if (flip_y) {
                    fb_idx +%= fb_width + 16;
                } else {
                    fb_idx -%= (fb_width * 16) - 16;
                }
            }
            fb_idx +%= 15 * fb_width;
        }
        assert(fb_idx == fb_width * DISPLAY.HEIGHT);
    }

    // render foreground tiles
    //
    //  Similar to the background tiles, but each tile is 8x8 pixels,
    //  for 32x32 tiles on the screen.
    //
    //  Tile char- and color-bytes are not stored in ROM, but in RAM
    //  at address 0x9000 (1 KB char codes) and 0x9400 (1 KB color codes).
    //
    //  There are actually 512 char-codes, bit 4 of the color byte
    //  is used as the missing bit 8 of the char-code.
    //
    //  The color decoding is the same as the background tiles, the lower
    //  3 bits are provided by the 3 tile bitmaps, and the remaining
    //  4 upper bits by the color byte.
    //
    //  Only 7 foreground colors are possible, since 0 defines a transparent
    //  pixel.
    //
    fn decodeForeground(self: *Self) void {
        var fb_idx: usize = 0;
        const fb_width = DISPLAY.FB_WIDTH;
        // 32x32 tiles, each 8x8 pixels
        for (0..32) |y| {
            for (0..32) |x| {
                const addr = y * 32 + x;
                // char codes are at 0x9000, color codes at 0x9400, RAM starts at 0x8000
                const chr = self.ram.main[(0x9000 - 0x8000) + addr];
                const clr = self.ram.main[(0x9400 - 0x8000) + addr];
                // 512 foreground tiles, take 9th bit from color code
                const tile_code: usize = chr | (@as(usize, clr) & 0x10) << 4;
                // 16 color blocks at 8 colors
                const color_block: usize = (clr & 0x0F) << 3;
                // 8 bytes per char bitmap
                var offset = tile_code * 8;
                for (0..8) |_| {
                    // 3 bit planes per char (8 colors per pixel within
                    // the palette color block of the char
                    const bm0 = self.rom.chars[0][offset];
                    const bm1 = self.rom.chars[1][offset];
                    const bm2 = self.rom.chars[2][offset];
                    offset += 1;
                    for (0..8) |ixx| {
                        const xx: u3 = @truncate(7 - ixx);
                        const pen: usize = ((bm2 >> xx) & 1) | (((bm1 >> xx) & 1) << 1) | (((bm0 >> xx) & 1) << 2);
                        if (pen != 0) {
                            self.fb[fb_idx] = self.main_board.palette[color_block | pen];
                        }
                        fb_idx +%= 1;
                    }
                    fb_idx +%= 248;
                }
                fb_idx -%= (8 * fb_width) - 8;
            }
            fb_idx +%= 7 * fb_width;
        }
        assert(fb_idx == fb_width * DISPLAY.HEIGHT);
    }

    // render sprites
    //
    // Each sprite is described by 4 bytes in the 'sprite RAM'
    // (0x9820..0x987F => 96 bytes => 24 sprites):
    //
    // ABBBBBBB CDEFGGGG XXXXXXXX YYYYYYYY
    //
    // A:  sprite size (16x16 or 32x32)
    // B:  sprite index
    // C:  X flip
    // D:  Y flip
    // E:  ?
    // F:  ?
    // G:  color
    // X:  x pos
    // Y:  y pos
    //
    fn decodeSprites(self: *Self) void {
        const fb_width = DISPLAY.FB_WIDTH;
        // 24 hardware sprites, sprite 0 has highest priority
        for (0..24) |i| {
            const sprite_nr = 23 - i;
            // sprite RAM starts at 0x9820, RAM starts at 0x8000
            const addr: usize = (0x9820 - 0x8000) + sprite_nr * 4;
            const b0 = self.ram.main[addr + 0];
            const b1 = self.ram.main[addr + 1];
            const b2 = self.ram.main[addr + 2];
            const b3 = self.ram.main[addr + 3];
            const color_block: usize = (b1 & 0x0F) << 3;

            // screen is 90 degrees rotated, so x and y are switched
            const px: usize = b3;
            const sprite_code: u32 = b0 & 0x7F;
            if ((b0 & 0x80) != 0) {
                // 32x32 large sprite (no flip x/y needed)
                const py: usize = 225 - b2;
                var fb_idx: usize = py * fb_width + px;
                // offset into sprite rom to gather sprite bitmap pixels
                var offset: usize = sprite_code * 128;
                for (0..32) |y| {
                    const bm0 = gather32(&self.rom.sprites[0], offset);
                    const bm1 = gather32(&self.rom.sprites[1], offset);
                    const bm2 = gather32(&self.rom.sprites[2], offset);
                    offset += 1;
                    if ((y & 7) == 7) {
                        offset += 8;
                    }
                    if ((y & 15) == 15) {
                        offset += 32;
                    }
                    for (0..32) |ix| {
                        const x: u5 = @truncate(31 - ix);
                        const pen: usize = ((bm2 >> x) & 1) | (((bm1 >> x) & 1) << 1) | (((bm0 >> x) & 1) << 2);
                        if (0 != pen) {
                            self.fb[fb_idx] = self.main_board.palette[color_block | pen];
                        }
                        fb_idx +%= 1;
                    }
                    fb_idx +%= 224;
                }
            } else {
                // 16*16 sprites are decoded like background tiles
                const py: usize = 241 - b2;
                var fb_idx: usize = py * fb_width + px;
                const flip_x = (b1 & 0x80) != 0;
                const flip_y = (b1 & 0x40) != 0;
                if (flip_x) {
                    fb_idx +%= 16 * fb_width;
                }
                // offset into sprite rom to gather sprite bitmap pixels
                var offset: usize = sprite_code * 32;
                for (0..16) |y| {
                    const bm0 = gather16(&self.rom.sprites[0], offset);
                    const bm1 = gather16(&self.rom.sprites[1], offset);
                    const bm2 = gather16(&self.rom.sprites[2], offset);
                    offset += 1;
                    if (y == 7) {
                        offset += 8;
                    }
                    for (0..16) |ix| {
                        const x: u4 = @truncate(if (flip_y) ix else 15 - ix);
                        const pen: usize = ((bm2 >> x) & 1) | (((bm1 >> x) & 1) << 1) | (((bm0 >> x) & 1) << 2);
                        if (0 != pen) {
                            self.fb[fb_idx] = self.main_board.palette[color_block | pen];
                        }
                        fb_idx +%= 1;
                    }
                    if (flip_x) {
                        fb_idx -%= 272;
                    } else {
                        fb_idx +%= 240;
                    }
                }
            }
        }
    }

    fn decodeVideo(self: *Self) void {
        self.decodeBackground();
        self.decodeForeground();
        self.decodeSprites();
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

    fn setClearBits(val: u8, comptime mask: u8, comptime set: bool) u8 {
        if (set) {
            return val | mask;
        } else {
            return val & ~mask;
        }
    }

    fn setClearInput(self: *Self, inp: Input, comptime set: bool) void {
        var b = &self.main_board;
        if (inp.p1_right) b.p1 = setClearBits(b.p1, JOY.RIGHT, set);
        if (inp.p1_left) b.p1 = setClearBits(b.p1, JOY.LEFT, set);
        if (inp.p1_up) b.p1 = setClearBits(b.p1, JOY.UP, set);
        if (inp.p1_down) b.p1 = setClearBits(b.p1, JOY.DOWN, set);
        if (inp.p1_button) b.p1 = setClearBits(b.p1, JOY.BUTTON, set);
        if (inp.p1_coin) b.sys = setClearBits(b.sys, SYS.P1_COIN, set);
        if (inp.p1_start) b.sys = setClearBits(b.sys, SYS.P1_START, set);
        if (inp.p2_right) b.p2 = setClearBits(b.p2, JOY.RIGHT, set);
        if (inp.p2_left) b.p2 = setClearBits(b.p2, JOY.LEFT, set);
        if (inp.p2_up) b.p2 = setClearBits(b.p2, JOY.UP, set);
        if (inp.p2_down) b.p2 = setClearBits(b.p2, JOY.DOWN, set);
        if (inp.p2_button) b.p2 = setClearBits(b.p2, JOY.BUTTON, set);
        if (inp.p2_coin) b.sys = setClearBits(b.sys, SYS.P2_COIN, set);
        if (inp.p2_start) b.sys = setClearBits(b.sys, SYS.P2_START, set);
    }
};
