const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");
const chipz = @import("chipz");

const Pengo = chipz.systems.namco.Namco(.Pengo);

const state = struct {
    var sys: Pengo = undefined;
    var frame_time_us: u32 = 0;
    var ticks_per_frame: u32 = 0;
};

export fn init() void {
    // setup system emulator
    state.sys = Pengo.init(.{
        .audio = .{
            .sample_rate = host.audio.sampleRate(),
            .callback = host.audio.push,
        },
        .roms = .{
            .sys_0000_0FFF = @embedFile("roms/ep5120.8"),
            .sys_1000_1FFF = @embedFile("roms/ep5121.7"),
            .sys_2000_2FFF = @embedFile("roms/ep5122.15"),
            .sys_3000_3FFF = @embedFile("roms/ep5123.14"),
            .sys_4000_4FFF = @embedFile("roms/ep5124.21"),
            .sys_5000_5FFF = @embedFile("roms/ep5125.20"),
            .sys_6000_6FFF = @embedFile("roms/ep5126.32"),
            .sys_7000_7FFF = @embedFile("roms/ep5127.31"),
            .gfx_0000_1FFF = @embedFile("roms/ep1640.92"),
            .gfx_2000_3FFF = @embedFile("roms/ep1695.105"),
            .prom_0000_001F = @embedFile("roms/pr1633.78"),
            .prom_0020_041F = @embedFile("roms/pr1634.88"),
            .sound_0000_00FF = @embedFile("roms/pr1635.51"),
            .sound_0100_01FF = @embedFile("roms/pr1636.70"),
        },
    });
    // setup host bindings
    host.init(.{
        .gfx = .{
            .display_info = state.sys.displayInfo(),
            .pixel_aspect = .{ .width = 2, .height = 3 },
        },
    });
}

export fn frame() void {
    state.frame_time_us = host.time.frameTime();
    state.ticks_per_frame = state.sys.exec(state.frame_time_us);
    host.gfx.draw(state.sys.displayInfo());
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
        .window_title = "Pengo (chipz)",
        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
