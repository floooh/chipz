const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");
const chipz = @import("chipz");

const Pacman = chipz.systems.namco.Namco(.Pacman);

const state = struct {
    var sys: Pacman = undefined;
    var frame_time_us: u32 = 0;
    var ticks_per_frame: u32 = 0;
};

export fn init() void {
    // setup host bindings
    host.init();

    // setup system emulator
    state.sys = Pacman.init(.{
        .audio = .{
            .sample_rate = host.audio.sampleRate(),
            .callback = host.audio.push,
        },
        .roms = .{
            .common = .{
                .sys_0000_0FFF = @embedFile("roms/pacman.6e"),
                .sys_1000_1FFF = @embedFile("roms/pacman.6f"),
                .sys_2000_2FFF = @embedFile("roms/pacman.6h"),
                .sys_3000_3FFF = @embedFile("roms/pacman.6j"),
                .prom_0000_001F = @embedFile("roms/82s123.7f"),
                .sound_0000_00FF = @embedFile("roms/82s126.1m"),
                .sound_0100_01FF = @embedFile("roms/82s126.3m"),
            },
            .pacman = .{
                .gfx_0000_0FFF = @embedFile("roms/pacman.5e"),
                .gfx_1000_1FFF = @embedFile("roms/pacman.5f"),
                .prom_0020_011F = @embedFile("roms/82s126.4a"),
            },
        },
    });
}

export fn frame() void {
    state.frame_time_us = host.time.frameTime();
    state.ticks_per_frame = state.sys.exec(state.frame_time_us);
    host.gfx.draw();
}

export fn cleanup() void {
    host.shutdown();
}

export fn input(ev: [*c]const sapp.Event) void {
    _ = ev;
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = input,
        .window_title = "Pacman (chipz)",
        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
