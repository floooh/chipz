const build_options = @import("build_options");
const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("chipz").host;
const kc85 = @import("chipz").systems.kc85;

const ig = @import("cimgui");
const simgui = sokol.imgui;

const model: kc85.Model = switch (build_options.model) {
    .KC852 => .KC852,
    .KC853 => .KC853,
    .KC854 => .KC854,
    else => @compileError("unsupported KC85 model"),
};
const name = switch (model) {
    .KC852 => "KC85/2",
    .KC853 => "KC85/3",
    .KC854 => "KC85/4",
};
const KC85 = kc85.Type(model);

// a once-trigger for loading a file after booting has finished
var file_loaded = host.time.Once.init(switch (model) {
    .KC852, .KC853 => 8 * 1000 * 1000,
    .KC854 => 3 * 1000 * 1000,
});

var sys: KC85 = undefined;
var gpa = GeneralPurposeAllocator(.{}){};
var args: Args = undefined;

export fn init() void {
    host.audio.init(.{});
    host.time.init();
    host.prof.init();
    sys.initInPlace(.{
        .audio = .{
            .sample_rate = @intCast(host.audio.sampleRate()),
            .volume = 0.5,
            .callback = host.audio.push,
        },
        .roms = switch (model) {
            .KC852 => .{
                .caos22 = @embedFile("roms/caos22.852"),
            },
            .KC853 => .{
                .caos31 = @embedFile("roms/caos31.853"),
                .kcbasic = @embedFile("roms/basic_c0.853"),
            },
            .KC854 => .{
                .caos42c = @embedFile("roms/caos42c.854"),
                .caos42e = @embedFile("roms/caos42e.854"),
                .kcbasic = @embedFile("roms/basic_c0.853"),
            },
        },
    });
    host.gfx.init(.{ .display = sys.displayInfo() });
    // initialize sokol-imgui
    simgui.setup(.{
        .logger = .{ .func = slog.func },
    });
    host.gfx.addDrawFunc(renderGUI);

    // insert modules
    inline for (.{ &args.slot8, &args.slotc }, .{ 0x08, 0x0C }) |slot, slot_addr| {
        if (slot.mod_type != .NONE) {
            sys.insertModule(slot_addr, slot.mod_type, slot.rom_dump) catch |err| {
                print("Failed to insert module with: {}\n", .{err});
                std.process.exit(10);
            };
        }
    }
}

fn renderGUI() void {
    simgui.render();
}

fn uiDrawMenu() void {
    if (ig.igBeginMainMenuBar()) {
        if (ig.igBeginMenu("System")) {
            if (ig.igMenuItem("Reset")) {
                // TODO: implement reset
            }
            if (ig.igMenuItem("Cold Boot")) {
                // TODO: implement cold boot
            }
            ig.igEndMenu();
        }
        if (ig.igBeginMenu("Hardware")) {
            if (ig.igMenuItem("Memory Map")) {
                // TODO: open window
            }
            if (ig.igMenuItem("System State")) {
                // TODO: open window
            }
            if (ig.igMenuItem("Audio Output")) {
                // TODO: open window
            }
            if (ig.igMenuItem("Display")) {
                // TODO: open window
            }
            if (ig.igMenuItem("Z80")) {
                // TODO: open chip window
            }
            if (ig.igMenuItem("Z80 PIO")) {
                // TODO: open chip window
            }
            if (ig.igMenuItem("Z80 CTC")) {
                // TODO: open chip window
            }
            ig.igEndMenu();
        }
        if (ig.igBeginMenu("Debug")) {
            if (ig.igMenuItem("CPU Debugger")) {
                // TODO: open window
            }
            if (ig.igMenuItem("Breakpoints")) {
                // TODO: open window
            }
            if (ig.igBeginMenu("Memory Editor")) {
                if (ig.igMenuItem("Window #1")) {
                    // TODO: open window
                }
                if (ig.igMenuItem("Window #2")) {
                    // TODO: open window
                }
                if (ig.igMenuItem("Window #3")) {
                    // TODO: open window
                }
                if (ig.igMenuItem("Window #4")) {
                    // TODO: open window
                }
                ig.igEndMenu();
            }
            if (ig.igBeginMenu("Disassembler")) {
                if (ig.igMenuItem("Window #1")) {
                    // TODO: open window
                }
                if (ig.igMenuItem("Window #2")) {
                    // TODO: open window
                }
                if (ig.igMenuItem("Window #3")) {
                    // TODO: open window
                }
                if (ig.igMenuItem("Window #4")) {
                    // TODO: open window
                }
                ig.igEndMenu();
            }
            ig.igEndMenu();
        }
        ig.igEndMainMenuBar();
    }
}

export fn frame() void {
    const frame_time_us = host.time.frameTime();
    host.prof.pushMicroSeconds(.FRAME, frame_time_us);
    host.time.emuStart();
    const num_ticks = sys.exec(frame_time_us);
    host.prof.pushMicroSeconds(.EMU, host.time.emuEnd());

    // call simgui.newFrame() before any ImGui calls
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });

    uiDrawMenu();

    host.gfx.draw(.{
        .display = sys.displayInfo(),
        .status = .{
            .name = name,
            .num_ticks = num_ticks,
            .frame_stats = host.prof.stats(.FRAME),
            .emu_stats = host.prof.stats(.EMU),
        },
    });
    if (file_loaded.once(frame_time_us)) {
        if (args.file_data) |file_data| {
            sys.load(.{ .data = file_data, .start = true, .patch = .{ .func = patch } }) catch |err| {
                print("Failed to load file into emulator with {}", .{err});
            };
        }
    }
}

export fn cleanup() void {
    simgui.shutdown();
    host.gfx.shutdown();
    host.prof.shutdown();
    host.audio.shutdown();
    args.deinit();
    if (gpa.deinit() != .ok) {
        @panic("Memory leaks detected");
    }
}

export fn input(ev: ?*const sapp.Event) void {
    const event = ev.?;
    const shift = 0 != (event.modifiers & sapp.modifier_shift);

    // forward input events to sokol-imgui
    _ = simgui.handleEvent(event.*);

    switch (event.type) {
        .CHAR => {
            var c: u8 = @truncate(event.char_code);
            if ((c > 0x20) and (c < 0x7F)) {
                // need to invert case
                if (std.ascii.isUpper(c)) {
                    c = std.ascii.toLower(c);
                } else if (std.ascii.isLower(c)) {
                    c = std.ascii.toUpper(c);
                }
                sys.keyDown(c);
                sys.keyUp(c);
            }
        },
        .KEY_DOWN, .KEY_UP => {
            const c: u32 = switch (event.key_code) {
                .SPACE => 0x20,
                .ENTER => 0x0D,
                .RIGHT => 0x09,
                .LEFT => 0x08,
                .DOWN => 0x0A,
                .UP => 0x0B,
                .HOME => 0x10,
                .INSERT => 0x1A,
                .BACKSPACE => 0x01,
                .ESCAPE => 0x03,
                .F1 => 0xF1,
                .F2 => 0xF2,
                .F3 => 0xF3,
                .F4 => 0xF4,
                .F5 => 0xF5,
                .F6 => 0xF6,
                .F7 => 0xF7,
                .F8 => 0xF8,
                .F9 => 0xF9,
                .F10 => 0xFA,
                .F11 => 0xFB,
                .F12 => 0xFC,
                else => 0,
            };
            const shift_c: u32 = switch (c) {
                0x20 => 0x5B, // inverted space
                0x1A, 0x01 => 0x0C, // CLS
                0x03 => 0x13, // STOP
                else => c,
            };
            if (c != 0) {
                if (event.type == .KEY_DOWN) {
                    sys.keyDown(if (shift) shift_c else c);
                } else {
                    // see: https://github.com/floooh/chips-test/issues/20
                    sys.keyUp(c);
                    if (shift_c != c) {
                        sys.keyUp(shift_c);
                    }
                }
            }
        },
        else => {},
    }
}

pub fn main() void {
    args = Args.parse(gpa.allocator()) catch {
        return;
    };
    defer args.deinit();
    if (args.help) {
        return;
    }

    const display = KC85.displayInfo(null);
    const border = host.gfx.DEFAULT_BORDER;
    const width = 2 * display.view.width + border.left + border.right;
    const height = 2 * display.view.height + border.top + border.bottom;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = input,
        .cleanup_cb = cleanup,
        .window_title = name ++ " (chipz)",
        .width = width,
        .height = height,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}

// game patcher callback
fn patch(image_name: []const u8, userdata: usize) void {
    _ = userdata;
    if (std.mem.startsWith(u8, image_name, "JUNGLE     ")) {
        // patch start level 1 into memory
        sys.mem.wr(0x36B7, 1);
        sys.mem.wr(0x3697, 1);
        for (0..5) |idx| {
            const idx16: u16 = @truncate(idx);
            const b = sys.mem.rd(0x36B6 +% idx16);
            sys.mem.wr(0x1770 +% idx16, b);
        }
    } else if (std.mem.startsWith(u8, image_name, "DIGGER  COM\x01")) {
        // time for delay loop 0x0160 instead of 0x0260
        sys.mem.wr16(0x09AA, 0x0160);
        // OR L instead of OR (HL)
        sys.mem.wr(0x3D3A, 0xB5);
    } else if (std.mem.startsWith(u8, image_name, "DIGGERJ")) {
        sys.mem.wr16(0x09AA, 0x0260); // not a bug
        sys.mem.wr(0x3D3A, 0xB5);
    }
}

// command line args
const Args = struct {
    const Module = struct {
        mod_type: KC85.ModuleType = .NONE,
        rom_dump: ?[]const u8 = null,
    };
    allocator: std.mem.Allocator,
    help: bool = false,
    // optional file content to load (.KCC or .TAP file format)
    file_data: ?[]const u8 = null,
    // modules to insert into slot 08 and 0C
    slot8: Module = .{},
    slotc: Module = .{},

    pub fn parse(allocator: std.mem.Allocator) !Args {
        var res = Args{
            .allocator = allocator,
        };
        errdefer res.deinit();
        var arg_iter = try std.process.argsWithAllocator(res.allocator);
        defer arg_iter.deinit();
        _ = arg_iter.skip();
        while (arg_iter.next()) |arg| {
            if (isArg(arg, &.{ "-h", "-help", "--help" })) {
                res.help = true;
                const help = .{
                    "  -file path -- load .KCC or .TAP file",
                    "  -slot8 name [rom dump path] -- load module into slot 08",
                    "  -slotc name [rom dump path] -- load module into slot 0C",
                    "",
                    "  Valid module names are:",
                    "    m006 - KC85/2 BASIC ROM",
                    "    m011 - 64 KByte RAM",
                    "    m022 - 16 KByte RAM",
                    "    m012 - TEXOR text processor",
                    "    m026 - FORTH development",
                    "    m027 - assembly development",
                };
                inline for (help) |s| {
                    print(s ++ "\n", .{});
                }
            } else if (isArg(arg, &.{"-file"})) {
                const next = arg_iter.next() orelse {
                    print("Expected path to .KCC or .TAP file after '{s}'\n", .{arg});
                    return error.InvalidArgs;
                };
                res.file_data = fs.cwd().readFileAlloc(allocator, next, 64 * 1024) catch |err| {
                    print("Failed to load file '{s}'\n", .{next});
                    return err;
                };
            } else if (isArg(arg, &.{"-slot8"})) {
                res.slot8 = try parseModuleArgs(allocator, arg, &arg_iter);
            } else if (isArg(arg, &.{"-slotc"})) {
                res.slotc = try parseModuleArgs(allocator, arg, &arg_iter);
            } else {
                print("Unknown argument: {s} (run '-help' to show valid args)\n", .{arg});
                return error.InvalidArgs;
            }
        }
        return res;
    }

    pub fn deinit(self: *Args) void {
        if (self.file_data) |slice| {
            self.allocator.free(slice);
        }
        if (self.slot8.rom_dump) |slice| {
            self.allocator.free(slice);
        }
        if (self.slotc.rom_dump) |slice| {
            self.allocator.free(slice);
        }
    }

    fn isArg(arg: []const u8, comptime strings: []const []const u8) bool {
        for (strings) |str| {
            if (std.mem.eql(u8, arg, str)) {
                return true;
            }
        }
        return false;
    }

    fn parseModuleArgs(allocator: std.mem.Allocator, arg: []const u8, arg_iter: *std.process.ArgIterator) !Args.Module {
        var mod = Args.Module{};
        const mod_name = arg_iter.next() orelse {
            print("Expected module name after '{s}'\n", .{arg});
            return error.InvalidArgs;
        };
        const mod_table = .{
            .{ .name = "m006", .mod_type = .M006_BASIC, .rom = true },
            .{ .name = "m011", .mod_type = .M011_64KBYTE, .rom = false },
            .{ .name = "m012", .mod_type = .M012_TEXOR, .rom = true },
            .{ .name = "m022", .mod_type = .M022_16KBYTE, .rom = false },
            .{ .name = "m026", .mod_type = .M026_FORTH, .rom = true },
            .{ .name = "m026", .mod_type = .M027_DEV, .rom = true },
        };
        var is_rom_module = false;
        inline for (mod_table) |item| {
            if (std.mem.eql(u8, mod_name, item.name)) {
                mod.mod_type = item.mod_type;
                is_rom_module = item.rom;
                break;
            }
        }
        if (mod.mod_type == .NONE) {
            print("Invalid module name '{s} (see -help for list of valid module names)\n", .{mod_name});
            return error.InvalidArgs;
        }
        if (is_rom_module) {
            const rom_dump_path = arg_iter.next() orelse {
                print("Expect ROM dump file path after '{s} {s}'\n", .{ arg, mod_name });
                return error.InvalidArgs;
            };
            mod.rom_dump = fs.cwd().readFileAlloc(allocator, rom_dump_path, 64 * 1024) catch |err| {
                print("Failed to load module rom dump file '{s}'\n", .{rom_dump_path});
                return err;
            };
        }
        return mod;
    }
};
