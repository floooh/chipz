const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const allocPrint = std.fmt.allocPrint;

var alloc: std.mem.Allocator = undefined;

// global array, referencing each other via slices
var actions = FixedArray(?[]const u8, 1024 * 1024){};
var tcycles = FixedArray(TCycle, 256 * 1024){};
var mcycles = FixedArray(MCycle, 64 * 1024){};
var main_ops = FixedArray(Op, 256){};
var ed_ops = FixedArray(Op, 256){};
var cb_ops = FixedArray(Op, 256){};
// TODO: special decoder block 'ops'

// formatted print into allocated slice
fn f(comptime fmt_str: []const u8, args: anytype) []const u8 {
    return allocPrint(alloc, fmt_str, args) catch @panic("allocation failed");
}

fn mainOp(opcode: usize, op: Op) void {
    main_ops.items[opcode] = op;
}

// see http://www.z80.info/decoding.htm
const R = enum(u3) {
    B,
    C,
    D,
    E,
    H,
    L,
    @"(HL)",
    A,

    // emit register access without mapping H and L to IXL/IYL and IXH/IYH
    fn rr(e: R) []const u8 {
        return f("self.r[{s}]", .{@tagName(e)});
    }

    // emit register access with mapping H and L to IXL/IYL and IXH/IYH
    fn r(e: R) []const u8 {
        if ((e == .H) or (e == .L)) {
            return f("self.r[{s}+self.rixy]", .{@tagName(e)});
        } else {
            return rr(e);
        }
    }

    fn rv(v: u3) []const u8 {
        return r(@enumFromInt(v));
    }

    fn rrv(v: u3) []const u8 {
        return rr(@enumFromInt(v));
    }

    fn strAsm(e: R) []const u8 {
        return @tagName(e);
    }

    fn strAsmV(v: u3) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

const RP = enum(u2) {
    BC,
    DE,
    HL,
    SP,

    fn str(e: RP) []const u8 {
        return @tagName(e);
    }

    fn strV(v: u2) []const u8 {
        return str(@enumFromInt(v));
    }

    fn strAsm(e: RP) []const u8 {
        return @tagName(e);
    }

    fn strAsmV(v: u2) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

const RP2 = enum(u2) {
    BC,
    DE,
    HL,
    AF,

    fn str(e: RP) []const u8 {
        return @tagName(e);
    }

    fn strV(v: u2) []const u8 {
        return str(@enumFromInt(v));
    }

    fn strAsm(e: RP) []const u8 {
        return @tagName(e);
    }

    fn strAsmV(v: u2) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

const ALU = enum(u3) {
    ADD,
    ADC,
    SUB,
    SBC,
    AND,
    XOR,
    OR,
    CP,

    fn fun(e: ALU) []const u8 {
        return switch (e) {
            .ADD => "self.add8",
            .ADC => "self.adc8",
            .SUB => "self.sub8",
            .SBC => "self.sbc8",
            .AND => "self.and8",
            .XOR => "self.xor8",
            .OR => "self.or8",
            .CP => "self.cp8",
        };
    }

    fn funv(v: u3) []const u8 {
        return fun(@enumFromInt(v));
    }

    fn strAsm(e: ALU) []const u8 {
        return @tagName(e);
    }

    fn strAsmV(v: u3) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

const CC = enum(u3) { NZ, Z, NC, C, PO, PE, P, M };
const ROT = enum(u3) { RLC, RRC, RL, RR, SLA, SRA, SLL, SRL };

// a tcycle is everything that happens in a specific clock tick
const TCycle = struct {
    // slice into actions array
    actions: []?[]const u8 = &.{},
};

// an mcycle is a collection of tcycles
const MCycle = struct {
    const Type = enum {
        Invalid,
        Read,
        Write,
        In,
        Out,
        Generic,
        Overlapped,
    };
    type: Type = .Invalid,
    // slice into tcycles array
    tcycles: []TCycle = &.{},
};

// an Op is a collection of MCycles
const Op = struct {
    // disassembly
    dasm: []const u8,
    // slice into mcycles array
    mcycles: []MCycle = &.{},
};

// a generic fixed-capacity array
fn FixedArray(comptime T: type, comptime C: usize) type {
    return struct {
        items: [C]T = undefined,
        len: usize = 0,

        fn add(self: *@This(), items: []const T) []T {
            assert(self.len < (C + items.len));
            const res = self.items[self.len..(self.len + items.len)];
            for (items) |item| {
                self.items[self.len] = item;
                self.len += 1;
            }
            return res;
        }
    };
}

fn step() []const u8 {
    return "break :step_next";
}

fn wait() []const u8 {
    return "if (!wait(pins)) break :track_int_bits";
}

fn mreq_rd(addr: []const u8) []const u8 {
    return f("pins=sax({s}, MREQ|RD)", .{addr});
}

fn mreq_wr(addr: []const u8, data: []const u8) []const u8 {
    return f("pins=sadx({s}, {s}, MREQ|WR)", .{ addr, data });
}

fn gd(dst: []const u8) []const u8 {
    return f("{s}=gd()", .{dst});
}

fn fetch(action: ?[]const u8) MCycle {
    return .{
        .type = .Overlapped,
        .tcycles = tcycles.add(&.{
            .{ .actions = actions.add(&.{ action, "break :fetch_next" }) },
        }),
    };
}

fn mread(abus: []const u8, dst: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Read,
        .tcycles = tcycles.add(&.{
            .{ .actions = actions.add(&.{step()}) },
            .{ .actions = actions.add(&.{ wait(), mreq_rd(abus), step() }) },
            .{ .actions = actions.add(&.{ gd(dst), action, step() }) },
        }),
    };
}

fn mwrite(abus: []const u8, src: []const u8, action: ?[]const u8) MCycle {
    return .{
        .type = .Write,
        .tcycles = tcycles.add(&.{
            .{ .actions = actions.add(&.{step()}) },
            .{ .actions = actions.add(&.{ wait(), mreq_wr(abus, src), action, step() }) },
            .{ .actions = actions.add(&.{step()}) },
        }),
    };
}

pub fn decode(allocator: std.mem.Allocator) void {
    alloc = allocator;
    decodeMain();
    decodeED();
    decodeCB();
}

pub fn dump() void {
    for (main_ops.items, 0..) |op, opcode| {
        if (op.mcycles.len > 0) {
            print("{X} => {s}:\n", .{ opcode, op.dasm });
            for (op.mcycles) |mcycle| {
                print("  type: {any}\n", .{mcycle.type});
                print("  tcycles:\n", .{});
                for (mcycle.tcycles, 0..) |tcycle, i| {
                    print("    {}: ", .{i});
                    for (tcycle.actions) |action_or_null| {
                        if (action_or_null) |action| {
                            print("{s}; ", .{action});
                        }
                    }
                    print("\n", .{});
                }
            }
        }
    }
}

fn decodeMain() void {
    for (0..256) |i| {
        const op: u8 = @truncate(i);
        const x: u2 = @truncate((i >> 6) & 3);
        const y: u3 = @truncate((i >> 3) & 7);
        const z: u3 = @truncate(i & 7);
        switch (x) {
            0 => {
                // quadrant 0
            },
            1 => {
                // quadrant 1: 8-bit loads
                if ((y == 6) and (z == 6)) {
                    halt(op);
                } else if (y == 6) {
                    @"LD (HL),r"(op, z);
                } else if (z == 6) {
                    @"LD r,(HL)"(op, y);
                } else {
                    @"LD r,r"(op, y, z);
                }
            },
            2 => {
                // quadrant 2: 8-bit ALU instructions
                if (z == 6) {
                    @"ALU (HL)"(op, y);
                } else {
                    @"ALU r"(op, y, z);
                }
            },
            3 => {
                // quadrant 3
            },
        }
    }
}

fn decodeED() void {}

fn decodeCB() void {}

fn halt(opcode: u8) void {
    mainOp(opcode, .{
        .dasm = "HALT",
        .mcycles = mcycles.add(&.{
            fetch("pins=self.halt(pins)"),
        }),
    });
}

fn @"LD (HL),r"(opcode: u8, z: u3) void {
    mainOp(opcode, .{
        .dasm = f("LD (HL),{s}", .{R.strAsmV(z)}),
        .mcycles = mcycles.add(&.{
            mwrite("self.addr()", R.rrv(z), null),
            fetch(null),
        }),
    });
}

fn @"LD r,(HL)"(opcode: u8, y: u3) void {
    mainOp(opcode, .{
        .dasm = f("LD {s},(HL)", .{R.strAsmV(y)}),
        .mcycles = mcycles.add(&.{
            mread("self.addr()", R.rrv(y), null),
            fetch(null),
        }),
    });
}

fn @"LD r,r"(opcode: u8, y: u3, z: u3) void {
    mainOp(opcode, .{
        .dasm = f("LD {s},{s}", .{ R.strAsmV(y), R.strAsmV(z) }),
        .mcycles = mcycles.add(&.{
            fetch(f("{s}={s}", .{ R.rv(y), R.rv(z) })),
        }),
    });
}

fn @"ALU (HL)"(opcode: u8, y: u3) void {
    mainOp(opcode, .{
        .dasm = f("{s} (HL)", .{ALU.strAsmV(y)}),
        .mcycles = mcycles.add(&.{
            mread("self.addr()", "self.dlatch", null),
            fetch(f("{s}(self.dlatch)", .{ALU.funv(y)})),
        }),
    });
}

fn @"ALU r"(opcode: u8, y: u3, z: u3) void {
    mainOp(opcode, .{
        .dasm = f("{s} {s}", .{ ALU.strAsmV(y), R.strAsmV(z) }),
        .mcycles = mcycles.add(&.{
            fetch(f("{s}({s})", .{ ALU.funv(y), R.rv(z) })),
        }),
    });
}
