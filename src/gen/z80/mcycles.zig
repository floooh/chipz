//! machine cycles are are instruction building blocks
const f = @import("format.zig").f;
const MCycle = @import("types.zig").MCycle;
const ac = @import("accumulate.zig").ac;
const tc = @import("accumulate.zig").tc;

pub fn mrd(addr: []const u8) []const u8 {
    return f("bus = mrd(bus, {s})", .{addr});
}

pub fn mwr(addr: []const u8, data: []const u8) []const u8 {
    return f("bus = mwr(bus, {s}, {s})", .{ addr, data });
}

pub fn gd(dst: []const u8) []const u8 {
    return f("{s} = gd(bus)", .{dst});
}

pub fn overlapped(action: ?[]const u8) MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tc(&.{
            .{ .fetch = true, .actions = ac(&.{action}) },
        }),
    };
}

pub fn mread(abus: []const u8, dst: []const u8, abus_action: ?[]const u8, dst_action: ?[]const u8) MCycle {
    return .{
        .type = .Read,
        .tcycles = tc(&.{
            .{},
            .{ .wait = true, .actions = ac(&.{ mrd(abus), abus_action }) },
            .{ .actions = ac(&.{ gd(dst), dst_action }) },
        }),
    };
}

pub fn mwrite(abus: []const u8, src: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Write,
        .tcycles = tc(&.{
            .{},
            .{ .wait = true, .actions = ac(&.{ mwr(abus, src), action }) },
            .{},
        }),
    };
}
