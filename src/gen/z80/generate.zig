//! generate the switch-decoder block

const std = @import("std");
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const mem = std.mem;
const fs = std.fs;
const formatter = @import("formatter.zig");
const f = formatter.f;
const join = formatter.join;
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
            for (op.mcycles) |mcycle| {
                for (mcycle.tcycles) |tcycle| {
                    try gen_tcycle(opcode_step_index, op, tcycle, tcount);
                    tcount += 1;
                }
            }
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
        try lines.append(f("// {s} (contined...)", .{op.dasm}));
    }
    try lines.append(f("0x{X} => {{", .{step_index}));
    if (tcycle.wait) {
        try lines.append("    if (wait(bus)) break :next;");
    }
    for (tcycle.actions) |action_or_null| {
        if (action_or_null) |action| {
            try lines.append(f("    {s};", .{action}));
        }
    }
    if (tcycle.fetch) {
        try lines.append("    break :fetch;");
    } else {
        try lines.append(f("    self.step = 0x{X};", .{next_step_index}));
        try lines.append("    break :next;");
    }
    try lines.append("},");
}

fn addLine(file: fs.File, line: []const u8) !void {
    try file.writeAll("    " ** 6);
    try file.writeAll(line);
    try file.writeAll("\n");
}

pub fn write(allocator: Allocator, path: []const u8) !void {
    const max_size = 5 * 1024 * 1024;
    const src = try fs.cwd().readFileAlloc(allocator, path, max_size);
    const dst = try fs.cwd().createFile(path, .{ .truncate = true, .lock = .exclusive });
    defer dst.close();

    var in_replace = false;
    var skip = false;
    var it = mem.splitScalar(u8, src, '\n');
    while (it.next()) |src_line| {
        const trimmed = mem.trim(u8, src_line, " \t");
        if (mem.eql(u8, trimmed, "// BEGIN CODEGEN")) {
            in_replace = true;
            skip = false;
            try dst.writeAll(src_line);
            try dst.writeAll("\n");
        }
        if (mem.eql(u8, trimmed, "// END CODEGEN")) {
            in_replace = false;
        }
        if (in_replace) {
            if (!skip) {
                for (op_lines.slice()) |line| {
                    try addLine(dst, line);
                }
                for (extra_lines.slice()) |line| {
                    try addLine(dst, line);
                }
                skip = true;
            }
        } else {
            // outside replace block, write current line to dst
            try dst.writeAll(src_line);
            if (it.peek() != null) {
                try dst.writeAll("\n");
            }
        }
    }
}
