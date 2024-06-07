//! machine cycles are are instruction building blocks
const MCycle = @import("types.zig").MCycle;
const ac = @import("accumulate.zig").ac;
const tc = @import("accumulate.zig").tc;
const mrd = @import("actions.zig").mrd;
const mwr = @import("actions.zig").mwr;
const gd = @import("actions.zig").gd;

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
