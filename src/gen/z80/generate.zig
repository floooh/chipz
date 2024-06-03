//! generate the switch-decoder block

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const fs = std.fs;
const formatter = @import("formatter.zig");
const f = formatter.f;
const join = formatter.join;
const acc = @import("accumulate.zig");
const types = @import("types.zig");
const Op = types.Op;
const TCycle = types.TCycle;

const MAX_LINES = 4000;
pub var lines = [_]?[]const u8{null} ** MAX_LINES;

var payload_index: usize = undefined;

pub fn generate() void {
    payload_index = 3 * 256;

    // write main ops
    for (acc.main_ops, 0..) |op, opcode_index| {
        var tcount: usize = 0;
        if (op.mcycles.len > 0) {
            for (op.mcycles) |mcycle| {
                for (mcycle.tcycles) |tcycle| {
                    gen_tcycle(opcode_index, op, tcycle, tcount);
                    tcount += 1;
                }
            }
        }
    }
}

fn gen_tcycle(opcode_index: usize, op: Op, tcycle: TCycle, tcount: usize) void {
    var index: usize = undefined;
    var next_index: usize = undefined;
    if (tcount == 0) {
        index = opcode_index;
        next_index = payload_index;
    } else {
        index = payload_index;
        payload_index += 1;
        next_index = payload_index;
    }
    const pre = if (tcycle.wait) "if (tst(bus, WAIT)) break :next; " else "";
    const post = if (tcycle.fetch) "break :fetch;" else f("self.step = 0x{X}; break :next;", .{next_index});
    const semi = if (tcycle.numValidActions() == 0) "" else "; ";
    const comment = switch (tcount) {
        0 => f(" // {s}", .{op.dasm}),
        1 => f(" // {s} (cont...)", .{op.dasm}),
        else => "",
    };
    lines[index] = f("0x{X} => {{ {s}{s}{s}{s} }},{s}", .{ index, pre, join(tcycle.actions), semi, post, comment });
}

pub fn write(allocator: Allocator, path: []const u8) !void {
    const max_size = 5 * 1024 * 1024;
    const src = try fs.cwd().readFileAlloc(allocator, path, max_size);
    const dst = try fs.cwd().openFile(path, .{ .mode = .write_only, .lock = .exclusive });
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
                for (lines) |lineOrNull| {
                    if (lineOrNull) |gen_line| {
                        try dst.writeAll("    " ** 6);
                        try dst.writeAll(gen_line);
                        try dst.writeAll("\n");
                    }
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

pub fn dump() void {
    for (lines) |lineOrNull| {
        if (lineOrNull) |line| {
            std.debug.print("{s}\n", .{line});
        }
    }
}
