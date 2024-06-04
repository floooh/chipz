//! action functions are low-level tcycle building blocks
const f = @import("formatter.zig").f;

pub fn mrd(addr: []const u8) []const u8 {
    return f("bus = mrd(bus, {s})", .{addr});
}

pub fn mwr(addr: []const u8, data: []const u8) []const u8 {
    return f("bus = mwr(bus, {s}, {s})", .{ addr, data });
}

pub fn gd(dst: []const u8) []const u8 {
    return f("{s} = gd(bus)", .{dst});
}
