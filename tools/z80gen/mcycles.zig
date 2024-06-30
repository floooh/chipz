//! machine cycles are are instruction building blocks
const f = @import("string.zig").f;
const ac = @import("accumulate.zig").ac;
const tc = @import("accumulate.zig").tc;
const MCycle = @import("types.zig").MCycle;

pub fn mrd(addr: []const u8) []const u8 {
    return f("bus = mrd(bus, {s})", .{addr});
}

pub fn mwr(addr: []const u8, data: []const u8) []const u8 {
    return f("bus = mwr(bus, {s}, {s})", .{ addr, data });
}

pub fn iord(addr: []const u8) []const u8 {
    return f("bus = iord(bus, {s})", .{addr});
}

pub fn iowr(addr: []const u8, data: []const u8) []const u8 {
    return f("bus = iowr(bus, {s}, {s})", .{ addr, data });
}

pub fn gd(dst: []const u8) []const u8 {
    return f("{s} = gd(bus)", .{dst});
}

pub fn endFetch() MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tc(&.{
            .{ .next = .Fetch, .actions = ac(&.{}) },
        }),
    };
}

pub fn endOverlapped(action: ?[]const u8) MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tc(&.{
            .{ .next = .Fetch, .actions = ac(&.{action}) },
        }),
    };
}

pub fn endBreak(action: ?[]const u8) MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tc(&.{
            .{ .next = .BreakNext, .actions = ac(&.{action}) },
        }),
    };
}

pub fn tick(actions: ?[]const u8) MCycle {
    return .{
        .type = .Generic,
        .tcycles = tc(&.{
            .{ .actions = ac(&.{actions}) },
        }),
    };
}

pub fn mread(abus: []const u8, dst: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Read,
        .tcycles = tc(&.{
            .{},
            .{ .wait = true, .actions = ac(&.{mrd(abus)}) },
            .{ .actions = ac(&.{ gd(dst), action }) },
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

pub fn ioread(abus: []const u8, dst: []const u8, abus_action: ?[]const u8, dst_action: ?[]const u8) MCycle {
    return .{
        .type = .In,
        .tcycles = tc(&.{
            .{},
            .{},
            .{ .wait = true, .actions = ac(&.{ iord(abus), abus_action }) },
            .{ .actions = ac(&.{ gd(dst), dst_action }) },
        }),
    };
}

pub fn iowrite(abus: []const u8, src: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Out,
        .tcycles = tc(&.{
            .{},
            .{ .actions = ac(&.{iowr(abus, src)}) },
            .{ .wait = true, .actions = ac(&.{action}) },
            .{},
        }),
    };
}

pub fn imm(dst: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Read,
        .tcycles = tc(&.{
            .{},
            .{ .wait = true, .actions = ac(&.{ mrd("self.@\"PC++\"()"), null }) },
            .{ .actions = ac(&.{ gd(dst), action }) },
        }),
    };
}
