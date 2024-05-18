const std = @import("std");
const print = std.debug.print;

var alloc: std.mem.Allocator = undefined;

pub fn decode(allocator: std.mem.Allocator) void {
    alloc = allocator;
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

fn r(v: u3) []const u8 {
    return switch (v) {
        0 => "B",
        1 => "C",
        2 => "D",
        3 => "E",
        4 => "H",
        5 => "L",
        6 => @panic("r() called with value 6"),
        7 => "A",
    };
}

fn rName(v: u3) []const u8 {
    return switch (v) {
        0 => "B",
        1 => "C",
        2 => "D",
        3 => "E",
        4 => "H",
        5 => "L",
        6 => @panic("r() called with value 6"),
        7 => "A",
    };
}

fn alu(v: u3) []const u8 {
    return switch (v) {
        0 => "add8",
        1 => "adc8",
        2 => "sub8",
        3 => "sbc8",
        4 => "and8",
        5 => "xor8",
        6 => "or8",
        7 => "cp8",
    };
}

fn aluName(v: u3) []const u8 {
    return switch (v) {
        0 => "ADD",
        1 => "ADC",
        2 => "SUB",
        3 => "SBC",
        4 => "AND",
        5 => "XOR",
        6 => "OR",
        7 => "CP",
    };
}

fn halt(op: u8) void {
    print("{X}: HALT\n", .{op});
}

fn @"LD (HL),r"(op: u8, z: u3) void {
    print("{X}: LD (HL),{s}\n", .{ op, rName(z) });
    // FIXME: this should have a syntax like
    //     mwrite(.{ .from = z, .abus = .HL })
    //     fetch(.{});
}

fn @"LD r,(HL)"(op: u8, y: u3) void {
    print("{X}: LD {s},(HL)\n", .{ op, rName(y) });
    // FIXME: this should have a syntax like
    //     mread(.{ abus: .HL, into: y})
    //     fetch(.{});
}

fn @"LD r,r"(op: u8, y: u3, z: u3) void {
    print("{X}: LD {s},{s}\n", .{ op, rName(y), rName(z) });
}

fn @"ALU (HL)"(op: u8, y: u3) void {
    print("{X}: {s} (HL)\n", .{ op, aluName(y) });
}

fn @"ALU r"(op: u8, y: u3, z: u3) void {
    print("{X}: {s} {s}\n", .{ op, aluName(y), rName(z) });
}
