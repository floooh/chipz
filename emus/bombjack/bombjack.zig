const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");
const Bombjack = @import("chipz").systems.bombjack.Bombjack;

var sys: Bombjack = undefined;

export fn init() void {
    host.audio.init(.{});
    host.time.init();
    host.prof.init();
    sys.initInPlace(.{
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
        .display = sys.displayInfo(),
        .pixel_aspect = .{ .width = 4, .height = 5 },
    });
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
            .name = "Bombjack",
            .num_ticks = num_ticks,
            .frame_stats = host.prof.stats(.FRAME),
            .emu_stats = host.prof.stats(.EMU),
        },
    });
}

export fn cleanup() void {
    host.gfx.shutdown();
    host.audio.shutdown();
}

fn keyToInput(key: sapp.Keycode) Bombjack.Input {
    return switch (key) {
        .RIGHT => .{ .p1_right = true },
        .LEFT => .{ .p1_left = true },
        .UP => .{ .p1_up = true },
        .DOWN => .{ .p1_down = true },
        .SPACE => .{ .p1_button = true },
        ._1 => .{ .p1_coin = true },
        ._2 => .{ .p2_coin = true },
        else => .{ .p1_start = true },
    };
}

export fn input(event: ?*const sapp.Event) void {
    const ev = event.?;
    switch (ev.type) {
        .KEY_DOWN => sys.setInput(keyToInput(ev.key_code)),
        .KEY_UP => sys.clearInput(keyToInput(ev.key_code)),
        else => {},
    }
}

pub fn main() void {
    const display = Bombjack.displayInfo(null);
    const border = host.gfx.DEFAULT_BORDER;
    const width = 3 * display.view.width + border.left + border.right;
    const height = 3 * display.view.height + border.top + border.bottom;
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
