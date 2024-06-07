//! op structure declarations
const op = @import("accumulate.zig").op;
const f = @import("formatter.zig").f;
const types = @import("types.zig");
const R = types.R;
const r = types.r;
const rr = types.rr;
const ALU = types.ALU;
const alu = types.alu;
const mc = @import("accumulate.zig").mc;
const mcycles = @import("mcycles.zig");
const mread = mcycles.mread;
const overlapped = mcycles.overlapped;
const mwrite = mcycles.mwrite;

pub fn nop(code: u8) void {
    op(code, .{
        .dasm = "NOP",
        .mcycles = mc(&.{
            overlapped(null),
        }),
    });
}

pub fn halt(code: u8) void {
    op(code, .{
        .dasm = "HALT",
        .mcycles = mc(&.{
            overlapped("bus = self.halt(bus)"),
        }),
    });
}

pub fn @"LD (HL),r"(code: u8, z: u3) void {
    op(code, .{
        .dasm = f("LD (HL),{s}", .{R.dasm(z)}),
        .indirect = true,
        .mcycles = mc(&.{
            mwrite("self.addr", rr(z), null),
            overlapped(null),
        }),
    });
}

pub fn @"LD r,(HL)"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("LD {s},(HL)", .{R.dasm(y)}),
        .indirect = true,
        .mcycles = mc(&.{
            mread("self.addr", rr(y), null, null),
            overlapped(null),
        }),
    });
}

pub fn @"LD r,r"(code: u8, y: u3, z: u3) void {
    op(code, .{
        .dasm = f("LD {s},{s}", .{ R.dasm(y), R.dasm(z) }),
        .mcycles = mc(&.{
            overlapped(f("{s} = {s}", .{ r(y), r(z) })),
        }),
    });
}

pub fn @"LD r,n"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("LD {s},n", .{R.dasm(y)}),
        .imm8 = true,
        .mcycles = mc(&.{
            mread("self.pc", r(y), "self.pc +%= 1", null),
            overlapped(null),
        }),
    });
}

pub fn @"LD (HL),n"(code: u8) void {
    op(code, .{
        .dasm = "LD (HL),n",
        .indirect = true,
        .imm8 = true,
        .mcycles = mc(&.{
            mread("self.pc", "self.dlatch", "self.pc +%=1", null),
            mwrite("self.addr", "self.dlatch", null),
            overlapped(null),
        }),
    });
}

pub fn @"ALU (HL)"(code: u8, y: u3) void {
    op(code, .{
        .dasm = f("{s} (HL)", .{ALU.dasm(y)}),
        .indirect = true,
        .mcycles = mc(&.{
            mread("self.addr", "self.dlatch", null, null),
            overlapped(f("{s}(self.dlatch)", .{alu(y)})),
        }),
    });
}

pub fn @"ALU r"(code: u8, y: u3, z: u3) void {
    op(code, .{
        .dasm = f("{s} {s}", .{ ALU.dasm(y), R.dasm(z) }),
        .mcycles = mc(&.{
            overlapped(f("{s}({s})", .{ alu(y), r(z) })),
        }),
    });
}
