pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const time = @import("time.zig");

pub fn init() void {
    time.init();
    gfx.init();
    audio.init();
}

pub fn shutdown() void {
    audio.shutdown();
    gfx.shutdown();
}
