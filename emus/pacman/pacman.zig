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
    host.audio.init(.{});
    host.time.init();
    state.sys.initInPlace(.{
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
        .display_info = state.sys.displayInfo(),
        .pixel_aspect = .{ .width = 2, .height = 3 },
    });
}

export fn frame() void {
    state.frame_time_us = host.time.frameTime();
    state.ticks_per_frame = state.sys.exec(state.frame_time_us);
    host.gfx.draw(state.sys.displayInfo());
}

export fn cleanup() void {
    host.gfx.shutdown();
    host.audio.shutdown();
}

fn keyToInput(key: sapp.Keycode) Pacman.Input {
    return switch (key) {
        .RIGHT => .P1_RIGHT,
        .LEFT => .P1_LEFT,
        .UP => .P1_UP,
        .DOWN => .P1_DOWN,
        ._1 => .P1_COIN,
        ._2 => .P2_COIN,
        else => .P1_START,
    };
}

export fn input(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_DOWN => state.sys.setInput(keyToInput(ev.*.key_code)),
        .KEY_UP => state.sys.clearInput(keyToInput(ev.*.key_code)),
        else => {},
    }
}

pub fn main() void {
    const display_info = Pacman.displayInfo(null);
    const border = host.gfx.DEFAULT_BORDER;
    const width = 2 * display_info.view.width + border.left + border.right;
    const height = 3 * display_info.view.height + border.top + border.bottom;
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
