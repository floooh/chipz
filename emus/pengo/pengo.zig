const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const slog = sokol.log;
const host = @import("host");

export fn init() void {
    host.init();
}

export fn frame() void {
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
        .window_title = "Pengo (chipz)",
        .width = 640,
        .height = 480,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
