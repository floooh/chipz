const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");
const namco = @import("chipz").systems.namco;

const Pacman = namco.Type(.Pacman);

var sys: Pacman = undefined;

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
            .sys_0000_0FFF = @embedFile("roms/pacman.6e"),
            .sys_1000_1FFF = @embedFile("roms/pacman.6f"),
            .sys_2000_2FFF = @embedFile("roms/pacman.6h"),
            .sys_3000_3FFF = @embedFile("roms/pacman.6j"),
            .gfx_0000_0FFF = @embedFile("roms/pacman.5e"),
            .gfx_1000_1FFF = @embedFile("roms/pacman.5f"),
            .prom_0000_001F = @embedFile("roms/82s123.7f"),
            .prom_0020_011F = @embedFile("roms/82s126.4a"),
            .sound_0000_00FF = @embedFile("roms/82s126.1m"),
            .sound_0100_01FF = @embedFile("roms/82s126.3m"),
        },
    });
    host.gfx.init(.{
        .border = host.gfx.DEFAULT_BORDER,
        .display = sys.displayInfo(),
        .pixel_aspect = .{ .width = 2, .height = 3 },
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
            .name = "Pacman",
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

fn keyToInput(key: sapp.Keycode) Pacman.Input {
    return switch (key) {
        .RIGHT => .{ .p1_right = true },
        .LEFT => .{ .p1_left = true },
        .UP => .{ .p1_up = true },
        .DOWN => .{ .p1_down = true },
        ._1 => .{ .p1_coin = true },
        ._2 => .{ .p2_coin = true },
        else => .{ .p1_start = true },
    };
}

export fn input(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_DOWN => sys.setInput(keyToInput(ev.*.key_code)),
        .KEY_UP => sys.clearInput(keyToInput(ev.*.key_code)),
        else => {},
    }
}

pub fn main() void {
    const display = Pacman.displayInfo(null);
    const border = host.gfx.DEFAULT_BORDER;
    const width = 2 * display.view.width + border.left + border.right;
    const height = 3 * display.view.height + border.top + border.bottom;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = input,
        .window_title = "Pacman (chipz)",
        .width = width,
        .height = height,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
