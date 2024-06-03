//! machine cycles are are instruction building blocks
const MCycle = @import("types.zig").MCycle;
const accum = @import("accumulate.zig");
const ac = accum.ac;
const tc = accum.tc;
const actions = @import("actions.zig");
const mreq_rd = actions.mreq_rd;
const mreq_wr = actions.mreq_wr;
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
            .{ .wait = true, .actions = ac(&.{mreq_rd(abus)}) },
            .{ .actions = ac(&.{ gd(dst), action }) },
        }),
    };
}

pub fn mwrite(abus: []const u8, src: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Write,
        .tcycles = tc(&.{
            .{},
            .{ .wait = true, .actions = ac(&.{ mreq_wr(abus, src), action }) },
            .{},
        }),
    };
}
