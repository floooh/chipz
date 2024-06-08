const std = @import("std");
const format = @import("format.zig");
const ops = @import("ops.zig");

pub fn decode(allocator: std.mem.Allocator) void {
    format.init(allocator);
    decodeMain();
    decodeED();
    decodeCB();
}

fn decodeMain() void {
    for (0..256) |i| {
        const op: u8 = @truncate(i);
        const x: u2 = @truncate((i >> 6) & 3);
        const y: u3 = @truncate((i >> 3) & 7);
        const z: u3 = @truncate(i & 7);
        const p: u2 = @truncate(y >> 1);
        const q: u1 = @truncate(y);
        switch (x) {
            // quadrant 0
            0 => switch (z) {
                0 => switch (y) {
                    0 => ops.nop(op),
                    else => {},
                },
                1 => switch (q) {
                    0 => ops.@"LD RP,nn"(op, p),
                    else => {},
                },
                2 => switch (q) {
                    0 => switch (p) {
                        0 => ops.@"LD (BC),A"(op),
                        1 => ops.@"LD (DE),A"(op),
                        2 => ops.@"LD (nn),HL"(op),
                        3 => ops.@"LD (nn),A"(op),
                    },
                    1 => switch (p) {
                        0 => ops.@"LD A,(BC)"(op),
                        1 => ops.@"LD A,(DE)"(op),
                        2 => ops.@"LD HL,(nn)"(op),
                        3 => ops.@"LD A,(nn)"(op),
                    },
                },
                6 => switch (y) {
                    6 => ops.@"LD (HL),n"(op),
                    else => ops.@"LD r,n"(op, y),
                },
                else => {},
            },
            // quadrant 1: 8-bit loads
            1 => {
                if ((y == 6) and (z == 6)) {
                    ops.halt(op);
                } else if (y == 6) {
                    ops.@"LD (HL),r"(op, z);
                } else if (z == 6) {
                    ops.@"LD r,(HL)"(op, y);
                } else {
                    ops.@"LD r,r"(op, y, z);
                }
            },
            // quadrant 2: 8-bit ALU instructions
            2 => {
                if (z == 6) {
                    ops.@"ALU (HL)"(op, y);
                } else {
                    ops.@"ALU r"(op, y, z);
                }
            },
            // quadrant 3
            3 => {
                switch (z) {
                    6 => ops.@"ALU n"(op, y),
                    else => {},
                }
            },
        }
    }
}

fn decodeED() void {}

fn decodeCB() void {}
