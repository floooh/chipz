//! action functions are low-level tcycle building blocks
const f = @import("formatter.zig").f;

pub fn next() []const u8 {
    return "break :step_next";
}

pub fn fetch_next() []const u8 {
    return "break :fetch_next";
}

pub fn wait() []const u8 {
    return "if (!wait(pins)) break :track_int_bits";
}

pub fn mreq_rd(addr: []const u8) []const u8 {
    return f("pins=sax({s}, MREQ|RD)", .{addr});
}

pub fn mreq_wr(addr: []const u8, data: []const u8) []const u8 {
    return f("pins=sadx({s}, {s}, MREQ|WR)", .{ addr, data });
}

pub fn gd(dst: []const u8) []const u8 {
    return f("{s}=gd()", .{dst});
}
