const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");
const chipz = @import("chipz");

const Bombjack = chipz.systems.bombjack.Bombjack;

const state = struct {
    var sys: Bombjack = undefined;
    var frame_time_us: u32 = 0;
    var ticks_per_frame: u32 = 0;
};

export fn init() void {
    host.audio.init(.{
        .disable_audio = true,
    });
    host.time.init();
    state.sys.initInPlace(.{
        .audio = .{
            .sample_rate = host.audio.sampleRate(),
            .callback = host.audio.push,
        },
        .roms = .{
            .main_0000_1FFF = @embedFile("roms/09_j01b.bin"),
            .main_2000_3FFF = @embedFile("roms/10_l01b.bin"),
            .main_4000_5FFF = @embedFile("roms/11_m01b.bin"),
            .main_6000_7FFF = @embedFile("roms/12_n01b.bin"),
            .main_C000_DFFF = @embedFile("roms/13.1r"),
            .sound_0000_1FFF = @embedFile("roms/01_h03t.bin"),
            .chars_0000_0FFF = @embedFile("roms/03_e08t.bin"),
            .chars_1000_1FFF = @embedFile("roms/04_h08t.bin"),
            .chars_2000_2FFF = @embedFile("roms/05_k08t.bin"),
            .tiles_0000_1FFF = @embedFile("roms/06_l08t.bin"),
            .tiles_2000_3FFF = @embedFile("roms/07_n08t.bin"),
            .tiles_4000_5FFF = @embedFile("roms/08_r08t.bin"),
            .sprites_0000_1FFF = @embedFile("roms/16_m07b.bin"),
            .sprites_2000_3FFF = @embedFile("roms/15_l07b.bin"),
            .sprites_4000_5FFF = @embedFile("roms/14_j07b.bin"),
            .maps_0000_0FFF = @embedFile("roms/02_p04t.bin"),
        },
    });
    host.gfx.init(.{
        .border = host.gfx.DEFAULT_BORDER,
        .display_info = state.sys.displayInfo(),
        .pixel_aspect = .{ .width = 4, .height = 5 },
    });
}

export fn frame() void {
    state.frame_time_us = host.time.frameTime();
    // FIXME: state.ticks_per_frame = state.sys.exec(state.frame_time_us);
    host.gfx.draw(state.sys.displayInfo());
}

export fn cleanup() void {
    host.gfx.shutdown();
    host.audio.shutdown();
}

export fn input(ev: [*c]const sapp.Event) void {
    _ = ev; // autofix
    // FIXME
}

pub fn main() void {
    const display_info = Bombjack.displayInfo(null);
    const border = host.gfx.DEFAULT_BORDER;
    const width = 3 * display_info.view.width + border.left + border.right;
    const height = 3 * display_info.view.height + border.top + border.bottom;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = input,
        .window_title = "Bombjack (chipz)",
        .width = width,
        .height = height,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
