//! generate the switch-decoder block

const std = @import("std");
const formatter = @import("formatter.zig");
const f = formatter.f;
const join = formatter.join;
const acc = @import("accumulate.zig");
const types = @import("types.zig");
const Op = types.Op;
const TCycle = types.TCycle;

const MAX_LINES = 4000;
pub var lines = [_]?[]const u8{null} ** MAX_LINES;

var opcode_index: usize = undefined;
var payload_index: usize = undefined;

pub fn generate() void {
    opcode_index = 0;
    payload_index = 3 * 256;

    // write main ops
    for (acc.main_ops) |op| {
        var tcount: usize = 0;
        if (op.mcycles.len > 0) {
            for (op.mcycles) |mcycle| {
                for (mcycle.tcycles) |tcycle| {
                    gen_tcycle(op, tcycle, tcount);
                    tcount += 1;
                }
            }
        } else {}
    }
}

fn gen_tcycle(op: Op, tcycle: TCycle, tcount: usize) void {
    var index: usize = undefined;
    var next_index: usize = undefined;
    if (tcount == 0) {
        index = opcode_index;
        opcode_index += 1;
        next_index = payload_index;
    } else {
        index = payload_index;
        payload_index += 1;
        next_index = payload_index;
    }
    const pre = if (tcycle.wait) "if (test(bus, WAIT)) break :next; " else "";
    const post = if (tcycle.fetch) "break :fetch," else f("self.step = {}; break :next,", .{next_index});
    const semi = if (tcycle.numValidActions() == 0) "" else "; ";
    const comment = switch (tcount) {
        0 => f(" // {s}", .{op.dasm}),
        1 => f(" // {s} (cont...)", .{op.dasm}),
        else => "",
    };
    lines[index] = f("{} => {s}{s}{s}{s}{s}", .{ index, pre, join(tcycle.actions), semi, post, comment });
}

pub fn dump() void {
    for (lines) |lineOrNull| {
        if (lineOrNull) |line| {
            std.debug.print("{s}\n", .{line});
        }
    }
}
