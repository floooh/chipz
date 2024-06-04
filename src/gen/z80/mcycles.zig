//! machine cycles are are instruction building blocks
const MCycle = @import("types.zig").MCycle;
const accum = @import("accumulate.zig");
const ac = accum.ac;
const tc = accum.tc;
const actions = @import("actions.zig");
const mrd = actions.mrd;
const mwr = actions.mwr;
const gd = actions.gd;

pub fn overlapped(action: ?[]const u8) MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tc(&.{
            .{ .fetch = true, .actions = ac(&.{action}) },
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
