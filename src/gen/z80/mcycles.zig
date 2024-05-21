//! machine cycles are are instruction building blocks
const MCycle = @import("types.zig").MCycle;
const accum = @import("accumulate.zig");
const ac = accum.ac;
const tc = accum.tc;
const actions = @import("actions.zig");
const next = actions.next;
const fetch_next = actions.fetch_next;
const wait = actions.wait;
const mreq_rd = actions.mreq_rd;
const mreq_wr = actions.mreq_wr;
const gd = actions.gd;

pub fn fetch(action: ?[]const u8) MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tc(&.{
            .{ .actions = ac(&.{ action, fetch_next() }) },
        }),
    };
}

pub fn mread(abus: []const u8, dst: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Read,
        .tcycles = tc(&.{
            .{ .actions = ac(&.{next()}) },
            .{ .actions = ac(&.{ wait(), mreq_rd(abus), next() }) },
            .{ .actions = ac(&.{ gd(dst), action, next() }) },
        }),
    };
}

pub fn mwrite(abus: []const u8, src: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Write,
        .tcycles = tc(&.{
            .{ .actions = ac(&.{next()}) },
            .{ .actions = ac(&.{ wait(), mreq_wr(abus, src), action, next() }) },
            .{ .actions = ac(&.{next()}) },
        }),
    };
}