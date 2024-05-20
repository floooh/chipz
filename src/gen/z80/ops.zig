//! op structure declarations
const mainOp = @import("accumulate.zig").mainOp;
const formatter = @import("formatter.zig");
const f = formatter.f;
const types = @import("types.zig");
const R = types.R;
const ALU = types.ALU;
const mc = @import("accumulate.zig").mc;
const mcycles = @import("mcycles.zig");
const mread = mcycles.mread;
const fetch = mcycles.fetch;
const mwrite = mcycles.mwrite;

pub fn halt(opcode: u8) void {
    mainOp(opcode, .{
        .dasm = "HALT",
        .mcycles = mc(&.{
            fetch("pins=self.halt(pins)"),
        }),
    });
}

pub fn @"LD (HL),r"(opcode: u8, z: u3) void {
    mainOp(opcode, .{
        .dasm = f("LD (HL),{s}", .{R.strAsmV(z)}),
        .mcycles = mc(&.{
            mwrite("self.addr()", R.rrv(z), null),
            fetch(null),
        }),
    });
}

pub fn @"LD r,(HL)"(opcode: u8, y: u3) void {
    mainOp(opcode, .{
        .dasm = f("LD {s},(HL)", .{R.strAsmV(y)}),
        .mcycles = mc(&.{
            mread("self.addr()", R.rrv(y), null),
            fetch(null),
        }),
    });
}

pub fn @"LD r,r"(opcode: u8, y: u3, z: u3) void {
    mainOp(opcode, .{
        .dasm = f("LD {s},{s}", .{ R.strAsmV(y), R.strAsmV(z) }),
        .mcycles = mc(&.{
            fetch(f("{s}={s}", .{ R.rv(y), R.rv(z) })),
        }),
    });
}

pub fn @"ALU (HL)"(opcode: u8, y: u3) void {
    mainOp(opcode, .{
        .dasm = f("{s} (HL)", .{ALU.strAsmV(y)}),
        .mcycles = mc(&.{
            mread("self.addr()", "self.dlatch", null),
            fetch(f("{s}(self.dlatch)", .{ALU.funv(y)})),
        }),
    });
}

pub fn @"ALU r"(opcode: u8, y: u3, z: u3) void {
    mainOp(opcode, .{
        .dasm = f("{s} {s}", .{ ALU.strAsmV(y), R.strAsmV(z) }),
        .mcycles = mc(&.{
            fetch(f("{s}({s})", .{ ALU.funv(y), R.rv(z) })),
        }),
    });
}
