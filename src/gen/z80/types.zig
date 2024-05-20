const f = @import("formatter.zig").f;

// a tcycle is everything that happens in a specific clock tick
pub const TCycle = struct {
    // slice into actions array
    actions: []?[]const u8 = &.{},
};

// an mcycle is a collection of tcycles
pub const MCycle = struct {
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
pub const Op = struct {
    // disassembly
    dasm: []const u8 = "",
    // slice into mcycles array
    mcycles: []MCycle = &.{},
};

// see http://www.z80.info/decoding.htm
pub const R = enum(u3) {
    B,
    C,
    D,
    E,
    H,
    L,
    @"(HL)",
    A,

    // emit register access without mapping H and L to IXL/IYL and IXH/IYH
    pub fn rr(e: R) []const u8 {
        return f("self.r[{s}]", .{@tagName(e)});
    }

    // emit register access with mapping H and L to IXL/IYL and IXH/IYH
    pub fn r(e: R) []const u8 {
        if ((e == .H) or (e == .L)) {
            return f("self.r[{s}+self.rixy]", .{@tagName(e)});
        } else {
            return rr(e);
        }
    }

    pub fn rv(v: u3) []const u8 {
        return r(@enumFromInt(v));
    }

    pub fn rrv(v: u3) []const u8 {
        return rr(@enumFromInt(v));
    }

    pub fn strAsm(e: R) []const u8 {
        return @tagName(e);
    }

    pub fn strAsmV(v: u3) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

pub const RP = enum(u2) {
    BC,
    DE,
    HL,
    SP,

    pub fn str(e: RP) []const u8 {
        return @tagName(e);
    }

    pub fn strV(v: u2) []const u8 {
        return str(@enumFromInt(v));
    }

    pub fn strAsm(e: RP) []const u8 {
        return @tagName(e);
    }

    pub fn strAsmV(v: u2) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

pub const RP2 = enum(u2) {
    BC,
    DE,
    HL,
    AF,

    pub fn str(e: RP) []const u8 {
        return @tagName(e);
    }

    pub fn strV(v: u2) []const u8 {
        return str(@enumFromInt(v));
    }

    pub fn strAsm(e: RP) []const u8 {
        return @tagName(e);
    }

    pub fn strAsmV(v: u2) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

pub const ALU = enum(u3) {
    ADD,
    ADC,
    SUB,
    SBC,
    AND,
    XOR,
    OR,
    CP,

    pub fn fun(e: ALU) []const u8 {
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

    pub fn funv(v: u3) []const u8 {
        return fun(@enumFromInt(v));
    }

    pub fn strAsm(e: ALU) []const u8 {
        return @tagName(e);
    }

    pub fn strAsmV(v: u3) []const u8 {
        return strAsm(@enumFromInt(v));
    }
};

pub const CC = enum(u3) { NZ, Z, NC, C, PO, PE, P, M };
pub const ROT = enum(u3) { RLC, RRC, RL, RR, SLA, SRA, SLL, SRL };
