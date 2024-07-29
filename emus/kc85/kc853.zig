const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");
const kc85 = @import("chipz").systems.kc85;

const KC853 = kc85.Type(.KC853);

var sys: KC853 = undefined;

export fn init() void {
    host.audio.init(.{ .disable_audio = true });
    host.time.init();
    host.prof.init();
    sys.initInPlace(.{
        .audio = .{
            .sample_rate = host.audio.sampleRate(),
            .callback = host.audio.push,
        },
        .roms = .{
            .caos31 = @embedFile("roms/caos31.853"),
            .kcbasic = @embedFile("roms/basic_c0.853"),
        },
    });
    host.gfx.init(.{ .display = sys.displayInfo() });
}

export fn frame() void {
    const frame_time_us = host.time.frameTime();
    host.prof.pushMicroSeconds(.FRAME, frame_time_us);
    host.time.emuStart();
    const num_ticks = sys.exec(frame_time_us);
    host.prof.pushMicroSeconds(.EMU, host.time.emuEnd());
    host.gfx.draw(.{
        .display = sys.displayInfo(),
        .status = .{
            .name = "KC85/3",
            .num_ticks = num_ticks,
            .frame_stats = host.prof.stats(.FRAME),
            .emu_stats = host.prof.stats(.EMU),
        },
    });
}

export fn cleanup() void {
    host.gfx.shutdown();
    host.prof.shutdown();
    host.audio.shutdown();
}

export fn input(ev: ?*const sapp.Event) void {
    const event = ev.?;
    const shift = 0 != (event.modifiers & sapp.modifier_shift);
    switch (event.type) {
        .CHAR => {
            var c: u8 = @truncate(event.char_code);
            if ((c >= 0x20) and (c < 0x7F)) {
                // need to invert case
                if (std.ascii.isUpper(c)) {
                    c = std.ascii.toLower(c);
                } else if (std.ascii.isLower(c)) {
                    c = std.ascii.toUpper(c);
                }
            }
            sys.keyDown(c);
            sys.keyUp(c);
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
    const display = KC853.displayInfo(null);
    const border = host.gfx.DEFAULT_BORDER;
    const width = 2 * display.view.width + border.left + border.right;
    const height = 2 * display.view.height + border.top + border.bottom;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = input,
        .cleanup_cb = cleanup,
        .window_title = "KC85/3 (chipz)",
        .width = width,
        .height = height,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
