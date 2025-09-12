//! generate the switch-decoder block

const std = @import("std");
const assert = std.debug.assert;
const f = @import("string.zig").f;
const dup = @import("string.zig").dup;
const replace = @import("string.zig").replace;
const accumulate = @import("accumulate.zig");
const Op = @import("types.zig").Op;
const TCycle = @import("types.zig").TCycle;
const BoundedArray = @import("common").BoundedArray;

const MAX_LINES = 16 * 1024;
const MAX_LINE_LENGTH = 1024;
var op_lines = BoundedArray([]const u8, MAX_LINES){};
var extra_lines = BoundedArray([]const u8, MAX_LINES){};

var extra_step_index: usize = undefined;

pub fn generate() !void {
    extra_step_index = 2 * 256;
    for (accumulate.main_ops, 0..) |op, opcode_step_index| {
        try genOp(op, opcode_step_index);
    }
    for (accumulate.ed_ops, 256..) |op, opcode_step_index| {
        try genOp(op, opcode_step_index);
    }
}

fn genOp(op: Op, opcode_step_index: usize) !void {
    var tcount: usize = 0;
    if (op.mcycles.len > 0) {
        var last_mcycle_valid = false;
        for (op.mcycles) |mcycle| {
            last_mcycle_valid = mcycle.type == .Overlapped;
            for (mcycle.tcycles) |tcycle| {
                try genTcycle(opcode_step_index, op, tcycle, tcount);
                tcount += 1;
            }
        }
        assert(last_mcycle_valid);
    }
}

fn genTcycle(opcode_step_index: usize, op: Op, tcycle: TCycle, tcount: usize) !void {
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
    var line = BoundedArray(u8, MAX_LINE_LENGTH){};
    try line.appendSlice(f("0x{X} => {{", .{step_index}));
    if (tcycle.wait) {
        try line.appendSlice(" if (wait(bus)) break :next;");
    }
    for (tcycle.actions) |action_or_null| {
        if (action_or_null) |action| {
            const l = replace(action, "$NEXTSTEP", f("0x{X}", .{next_step_index}));
            try line.appendSlice(f(" {s};", .{l}));
        }
    }
    switch (tcycle.next) {
        .BreakNext => {
            try line.appendSlice(" break :next;");
        },
        .StepAndBreakNext => {
            try line.appendSlice(f(" self.step = 0x{X}; break :next;", .{next_step_index}));
        },
        .Fetch => {},
    }
    try line.appendSlice(" },");
    if (tcount == 0) {
        try line.appendSlice(f(" // {s}", .{op.dasm}));
    } else if (tcount == 1) {
        try line.appendSlice(f(" // {s} (cont...)", .{op.dasm}));
    }
    try lines.append(dup(line.slice()));
}

fn addLine(file: std.fs.File, prefix: []const u8, line: []const u8) !void {
    try file.writeAll(prefix);
    try file.writeAll(line);
    try file.writeAll("\n");
}

const BeginEndState = struct {
    inside: bool,
    skip: bool,
};

fn checkBeginEnd(line: []const u8, file: std.fs.File, comptime key: []const u8, cur_state: BeginEndState) !BeginEndState {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.eql(u8, trimmed, "// BEGIN " ++ key)) {
        try file.writeAll(line);
        try file.writeAll("\n");
        return .{ .inside = true, .skip = false };
    }
    if (std.mem.eql(u8, trimmed, "// END " ++ key)) {
        return .{ .inside = false, .skip = cur_state.skip };
    }
    return cur_state;
}

pub fn write(allocator: std.mem.Allocator, path: []const u8) !void {
    const max_size = 5 * 1024 * 1024;
    const src = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    const dst = try std.fs.cwd().createFile(path, .{ .truncate = true, .lock = .exclusive });
    defer dst.close();

    var decode = BeginEndState{ .inside = false, .skip = false };
    var consts = BeginEndState{ .inside = false, .skip = false };
    var it = std.mem.splitScalar(u8, src, '\n');
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
                    "ED_M1_T2",
                    "ED_M1_T3",
                    "ED_M1_T4",
                    "CB_M1_T2",
                    "CB_M1_T3",
                    "CB_M1_T4",
                    "CB_M1_OVERLAPPED",
                    "CB_HL_T1",
                    "CB_HL_T2",
                    "CB_HL_T3",
                    "CB_HL_T4",
                    "CB_HL_T5",
                    "CB_HL_T6",
                    "CB_HL_T7",
                    "CB_HL_OVERLAPPED",
                    "DDFDCB_T1",
                    "DDFDCB_T2",
                    "DDFDCB_T3",
                    "DDFDCB_T4",
                    "DDFDCB_T5",
                    "DDFDCB_T6",
                    "DDFDCB_T7",
                    "DDFDCB_T8",
                    "DDFDCB_T9",
                    "DDFDCB_T10",
                    "DDFDCB_T11",
                    "DDFDCB_T12",
                    "DDFDCB_T13",
                    "DDFDCB_T14",
                    "DDFDCB_OVERLAPPED",
                    "NMI_T2",
                    "NMI_T3",
                    "NMI_T4",
                    "NMI_T5",
                    "NMI_T6",
                    "NMI_T7",
                    "NMI_T8",
                    "NMI_T9",
                    "NMI_T10",
                    "NMI_T11",
                    "NMI_OVERLAPPED",
                    "INT_IM0_T2",
                    "INT_IM0_T3",
                    "INT_IM0_T4",
                    "INT_IM0_T5",
                    "INT_IM0_T6",
                    "INT_IM1_T2",
                    "INT_IM1_T3",
                    "INT_IM1_T4",
                    "INT_IM1_T5",
                    "INT_IM1_T6",
                    "INT_IM1_T7",
                    "INT_IM1_T8",
                    "INT_IM1_T9",
                    "INT_IM1_T10",
                    "INT_IM1_T11",
                    "INT_IM1_T12",
                    "INT_IM1_T13",
                    "INT_IM1_OVERLAPPED",
                    "INT_IM2_T2",
                    "INT_IM2_T3",
                    "INT_IM2_T4",
                    "INT_IM2_T5",
                    "INT_IM2_T6",
                    "INT_IM2_T7",
                    "INT_IM2_T8",
                    "INT_IM2_T9",
                    "INT_IM2_T10",
                    "INT_IM2_T11",
                    "INT_IM2_T12",
                    "INT_IM2_T13",
                    "INT_IM2_T14",
                    "INT_IM2_T15",
                    "INT_IM2_T16",
                    "INT_IM2_T17",
                    "INT_IM2_T18",
                    "INT_IM2_T19",
                    "INT_IM2_OVERLAPPED",
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
