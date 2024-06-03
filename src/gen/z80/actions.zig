//! action functions are low-level tcycle building blocks
const f = @import("formatter.zig").f;

pub fn mreq_rd(addr: []const u8) []const u8 {
    return f("bus = mread(bus, {s})", .{addr});
}

pub fn mreq_wr(addr: []const u8, data: []const u8) []const u8 {
    return f("bus = mwrite(bus, {s}, {s})", .{ addr, data });
}

pub fn gd(dst: []const u8) []const u8 {
    return f("{s} = gd(bus)", .{dst});
}
