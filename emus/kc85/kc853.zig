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

export fn input(ev: [*c]const sapp.Event) void {
    _ = ev; // autofix
    // FIXME
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
