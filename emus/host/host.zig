pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const time = @import("time.zig");

pub const Options = struct {
    gfx: gfx.Options,
};

pub fn init(opts: Options) void {
    time.init();
    gfx.init(opts.gfx);
    audio.init();
}

pub fn shutdown() void {
    audio.shutdown();
    gfx.shutdown();
}
