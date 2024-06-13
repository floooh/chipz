//! generate the switch-decoder block

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const mem = std.mem;
const fs = std.fs;
const format = @import("format.zig");
const f = format.f;
const replace = format.replace;
const join = format.join;
const acc = @import("accumulate.zig");
const types = @import("types.zig");
const Op = types.Op;
const TCycle = types.TCycle;

const MAX_LINES = 16 * 1024;
var op_lines = BoundedArray([]const u8, MAX_LINES){};
var extra_lines = BoundedArray([]const u8, MAX_LINES){};

var extra_step_index: usize = undefined;

pub fn generate() !void {
    extra_step_index = 3 * 256;

    // write main ops
    for (acc.main_ops, 0..) |op, opcode_step_index| {
        var tcount: usize = 0;
        if (op.mcycles.len > 0) {
            var last_mcycle_valid = false;
            for (op.mcycles) |mcycle| {
                last_mcycle_valid = mcycle.type == .Overlapped;
                for (mcycle.tcycles) |tcycle| {
                    try gen_tcycle(opcode_step_index, op, tcycle, tcount);
                    tcount += 1;
                }
            }
            assert(last_mcycle_valid);
        }
    }
}

fn gen_tcycle(opcode_step_index: usize, op: Op, tcycle: TCycle, tcount: usize) !void {
    var step_index: usize = undefined;
    var next_step_index: usize = undefined;
    var lines: *BoundedArray([]const u8, MAX_LINES) = undefined;
    if (tcount == 0) {
        lines = &op_lines;
        step_index = opcode_step_index;
        next_step_index = extra_step_index;
    } else {
        lines = &extra_lines;
        step_index = extra_step_index;
        extra_step_index += 1;
        next_step_index = extra_step_index;
    }
    if (tcount == 0) {
        try lines.append(f("// {s}", .{op.dasm}));
    } else if (tcount == 1) {
        try lines.append(f("// {s} (continued...)", .{op.dasm}));
    }
    try lines.append(f("0x{X} => {{", .{step_index}));
    if (tcycle.wait) {
        try lines.append("    if (wait(bus)) break :next;");
    }
    for (tcycle.actions) |action_or_null| {
        if (action_or_null) |action| {
            const l = replace(action, "$NEXTSTEP", f("0x{X}", .{next_step_index}));
            try lines.append(f("    {s};", .{l}));
        }
    }

    switch (tcycle.next) {
        .BreakNext => {
            try lines.append("    break :next;");
        },
        .StepAndBreakNext => {
            try lines.append(f("    self.step = 0x{X};", .{next_step_index}));
            try lines.append("    break :next;");
        },
        .Fetch => {},
    }
    try lines.append("},");
}

fn addLine(file: fs.File, prefix: []const u8, line: []const u8) !void {
    try file.writeAll(prefix);
    try file.writeAll(line);
    try file.writeAll("\n");
}

const BeginEndState = struct {
    inside: bool,
    skip: bool,
};

fn checkBeginEnd(line: []const u8, file: fs.File, comptime key: []const u8, cur_state: BeginEndState) !BeginEndState {
    const trimmed = mem.trim(u8, line, " \t");
    if (mem.eql(u8, trimmed, "// BEGIN " ++ key)) {
        try file.writeAll(line);
        try file.writeAll("\n");
        return .{ .inside = true, .skip = false };
    }
    if (mem.eql(u8, trimmed, "// END " ++ key)) {
        return .{ .inside = false, .skip = cur_state.skip };
    }
    return cur_state;
}

pub fn write(allocator: Allocator, path: []const u8) !void {
    const max_size = 5 * 1024 * 1024;
    const src = try fs.cwd().readFileAlloc(allocator, path, max_size);
    const dst = try fs.cwd().createFile(path, .{ .truncate = true, .lock = .exclusive });
    defer dst.close();

    var decode = BeginEndState{ .inside = false, .skip = false };
    var consts = BeginEndState{ .inside = false, .skip = false };
    var it = mem.splitScalar(u8, src, '\n');
    const decode_prefix = "    " ** 5;
    const consts_prefix = "    " ** 2;
    const m1_t1 = extra_step_index;
    while (it.next()) |src_line| {
        decode = try checkBeginEnd(src_line, dst, "DECODE", decode);
        consts = try checkBeginEnd(src_line, dst, "CONSTS", consts);
        if (decode.inside) {
            if (!decode.skip) {
                for (op_lines.slice()) |line| {
                    try addLine(dst, decode_prefix, line);
                }
                for (extra_lines.slice()) |line| {
                    try addLine(dst, decode_prefix, line);
                }
                decode.skip = true;
            }
        } else if (consts.inside) {
            if (!consts.skip) {
                inline for (.{
                    "M1_T2",
                    "M1_T3",
                    "M1_T4",
                    "DDFD_M1_T2",
                    "DDFD_M1_T3",
                    "DDFD_M1_T4",
                    "DDFD_D_T1",
                    "DDFD_D_T2",
                    "DDFD_D_T3",
                    "DDFD_D_T4",
                    "DDFD_D_T5",
                    "DDFD_D_T6",
                    "DDFD_D_T7",
                    "DDFD_D_T8",
                    "DDFD_LDHLN_WR_T1",
                    "DDFD_LDHLN_WR_T2",
                    "DDFD_LDHLN_WR_T3",
                    "DDFD_LDHLN_OVERLAPPED",
                }, 0..) |str, i| {
                    try addLine(dst, consts_prefix, f("const {s}: u16 = 0x{X};", .{ str, m1_t1 + i }));
                }
            }
            consts.skip = true;
        } else {
            // outside replace block, write current line to dst
            try dst.writeAll(src_line);
            if (it.peek() != null) {
                try dst.writeAll("\n");
            }
        }
    }
}
