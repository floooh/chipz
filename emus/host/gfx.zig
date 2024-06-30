const sokol = @import("sokol");
const sg = sokol.gfx;
const sglue = sokol.glue;
const slog = sokol.log;

const state = struct {
    var pass_action: sg.PassAction = .{};
};

pub fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
    };
}

pub fn draw() void {
    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    sg.endPass();
    sg.commit();
}

pub fn shutdown() void {
    sg.shutdown();
}
