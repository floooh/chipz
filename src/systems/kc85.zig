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
const pin = common.bitutils.pin;
const cp = common.utils.cp;
const fillNoise = common.utils.fillNoise;
const AudioCallback = common.glue.AudioCallback;
const AudioOptions = common.glue.AudioOptions;
const DisplayInfo = common.glue.DisplayInfo;

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

// NOTE: 64 bits isn't enough for the system bus
const Bus = u128;
const Memory = memory.Type(.{ .page_size = 0x0400 });
const Z80 = z80.Type(.{ .pins = CPU_PINS, .bus = Bus });
const Z80PIO = z80pio.Type(.{ .pins = PIO_PINS, .bus = Bus });
const Z80CTC = z80ctc.Type(.{ .pins = CTC_PINS, .bus = Bus });

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
            audio: AudioOptions,
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
        };

        // CTC output pins
        pub const CTC = struct {
            pub const BEEPER1 = Z80CTC.ZCTO0;
            pub const BEEPER2 = Z80CTC.ZCTO1;
            pub const BLINK = Z80CTC.ZCTO2;
        };

        // KC85/4 IO address 0x84 latch
        pub const IO84 = struct {
            pub const SEL_VIEW_IMG = 1 << 0; // 0: display img0, 1: display img1
            pub const SEL_CPU_COLOR = 1 << 1; // 0: access pixels, 1: access colors
            pub const SEL_CPU_IMG = 1 << 2; // 0: access img 0, 1: access img 1
            pub const HICOLOR = 1 << 3; // 0: hicolor mode off, 1: hicolor mode on
            pub const SEL_RAM8 = 1 << 4; // select RAM8 block 0 or 1

            // latch bits which affect memory mapping
            pub const MEMORY_BITS = SEL_CPU_COLOR | SEL_CPU_IMG | SEL_RAM8;
        };

        // KC85/4 IO address 0x86 latch
        pub const IO86 = struct {
            pub const RAM4 = 1 << 0;
            pub const RAM4_RO = 1 << 1;
            pub const CAOS_ROM_C = 1 << 7;

            // latch bits which affect memory mapping
            pub const MEMORY_BITS = RAM4 | RAM4_RO | CAOS_ROM_C;
        };

        // expansion system constant
        pub const EXP = struct {
            pub const NUM_SLOTS = 2; // number of expansion slots in the base device
            pub const BUF_SIZE = NUM_SLOTS * 64 * 1024; // expansion system buffer size (64 KB per slot)
        };

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
        io84: u8 = 0, // KC85/4 only: byte latch at IO address 0x84
        io86: u8 = 0, // KC85/4 only: byte latch at IO address 0x86
        // FIXME: beepers
        // FIXME: keyboard
        exp: Exp = .{},
        mem: Memory,

        // memory buffers
        ram: [8][0x4000]u8,
        rom: Rom,
        ext_buf: [EXP.BUF_SIZE]u8,
        fb: [DISPLAY.FB_SIZE]u8 align(128),
        junk_page: [Memory.PAGE_SIZE]u8,
        unmapped_page: [Memory.PAGE_SIZE]u8,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .cpu = Z80.init(),
                .pio = Z80PIO.init(),
                .ctc = Z80CTC.init(),
                .mem = Memory.init(.{
                    .junk_page = &self.junk_page,
                    .unmapped_page = &self.unmapped_page,
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
                .ext_buf = std.mem.zeroes(@TypeOf(self.ext_buf)),
                .fb = std.mem.zeroes(@TypeOf(self.fb)),
                .junk_page = std.mem.zeroes(@TypeOf(self.junk_page)),
                .unmapped_page = [_]u8{0xFF} ** Memory.PAGE_SIZE,
            };
            // initial memory map
            self.updateMemoryMap(PIO.RAM | PIO.RAM_RO | PIO.IRM | PIO.CAOS_ROM);
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
            return num_ticks;
        }

        pub fn tick(self: *Self, in_bus: Bus) Bus {
            var bus = self.cpu.tick(in_bus);
            const addr = getAddr(bus);
            if (pin(bus, MREQ)) {
                if (pin(bus, RD)) {
                    bus = setData(bus, self.mem.rd(addr));
                } else if (pin(bus, WR)) {
                    self.mem.wr(addr, getData(bus));
                }
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
            self.mem.unmap(0x0000, 0x10000);
            // all models have 16 KB builtin RAM at address 0x0000
            if (pin(bus, PIO.RAM)) {
                if (pin(bus, PIO.RAM_RO)) {
                    self.mem.mapRAM(0x0000, 0x4000, &self.ram[0]);
                } else {
                    self.mem.mapROM(0x0000, 0x4000, &self.ram[0]);
                }
            }

            // all models have 8 KBytes ROM at address 0xE000
            if (pin(bus, PIO.CAOS_ROM)) {
                self.mem.mapROM(0xE000, 0x2000, &self.rom.caos_e);
            }

            // KC85/3 and /4 have a BASIC ROM at address 0xC000
            if (model != .KC852) {
                if (pin(bus, PIO.BASIC_ROM)) {
                    self.mem.mapROM(0xC000, 0x2000, &self.rom.basic);
                }
            }

            // KC85/2 and /3 have fixed 16 KB video RAM at 0x8000
            if (model != .KC854) {
                if (pin(bus, PIO.IRM)) {
                    self.mem.mapRAM(0x8000, 0x4000, &self.ram[IRM0_PAGE]);
                }
            }

            // remaining KC85/4 specific memory mapping
            if (model == .KC854) {
                @panic("FIXME: KC85/4 memory mapping");
            }
        }
    };
}
