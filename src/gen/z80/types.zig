const f = @import("format.zig").f;

// a tcycle is everything that happens in a specific clock tick
pub const TCycle = struct {
    // slice into actions array
    actions: []?[]const u8 = &.{},
    wait: bool = false, // if true check for wait state
    fetch: bool = false, // if true, fetch next instruction
    prefix: bool = false, // a special prefix-overlapped cycle
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

        pub fn str(t: Type) []const u8 {
            return @tagName(t);
        }
    };
    type: Type = .Invalid,
    // slice into tcycles array
    tcycles: []TCycle = &.{},
};

// an Op is a collection of MCycles
pub const Op = struct {
    // disassembly
    dasm: []const u8 = "",
    // loads an 8-bit immediate value
    imm8: bool = false,
    // indirect load via (HL) / (IX+d) / (IY+d)
    indirect: bool = false,
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

    pub fn asEnum(any: anytype) R {
        if (@TypeOf(any) != u3 and @TypeOf(any) != R) {
            @compileError("arg must be of type u3 or R!");
        }
        return if (@TypeOf(any) == R) any else @enumFromInt(any);
    }

    pub fn dasm(any: anytype) []const u8 {
        return @tagName(asEnum(any));
    }
};

pub fn r(any: anytype) []const u8 {
    const e = R.asEnum(any);
    if ((e == .H) or (e == .L)) {
        return f("self.r[{s} + self.rixy]", .{@tagName(e)});
    } else {
        return f("self.r[{s}]", .{@tagName(e)});
    }
}

pub fn rr(any: anytype) []const u8 {
    return f("self.r[{s}]", .{@tagName(R.asEnum(any))});
}

pub const RP = enum(u2) {
    BC,
    DE,
    HL,
    SP,

    fn asEnum(any: anytype) RP {
        if (@TypeOf(any) != u2 and @TypeOf(any) != RP) {
            @compileError("arg must be of type u2 or RP");
        }
        return if (@TypeOf(any) == RP) any else @enumFromInt(any);
    }

    pub fn dasm(any: anytype) []const u8 {
        return @tagName(asEnum(any));
    }
};

pub fn rp(any: anytype) []const u8 {
    return switch (RP.asEnum(any)) {
        .BC => "BC",
        .DE => "DE",
        .HL => "HLIXY",
        .SP => "SP",
    };
}

pub fn rpl(any: anytype) []const u8 {
    return switch (RP.asEnum(any)) {
        .BC => "self.r[C]",
        .DE => "self.r[E]",
        .HL => "self.r[L + self.rixy]",
        .SP => "self.r[SPL]",
    };
}

pub fn rph(any: anytype) []const u8 {
    return switch (RP.asEnum(any)) {
        .BC => "self.r[B]",
        .DE => "self.r[D]",
        .HL => "self.r[H + self.rixy]",
        .SP => "self.r[SPH]",
    };
}

pub const RP2 = enum(u2) {
    BC,
    DE,
    HL,
    AF,

    fn asEnum(any: anytype) RP2 {
        if (@TypeOf(any) != u2 and @TypeOf(any) != RP2) {
            @compileError("arg must be of type u2 or RP2");
        }
        return if (@TypeOf(any) == RP2) any else @enumFromInt(any);
    }

    pub fn dasm(any: anytype) []const u8 {
        return @tagName(asEnum(any));
    }
};

pub fn rp2l(any: anytype) []const u8 {
    return switch (RP2.asEnum(any)) {
        .BC => "self.r[C]",
        .DE => "self.r[E]",
        .HL => "self.r[L + self.rixy]",
        .AF => "self.r[F]",
    };
}

pub fn rp2h(any: anytype) []const u8 {
    return switch (RP2.asEnum(any)) {
        .BC => "self.r[B]",
        .DE => "self.r[D]",
        .HL => "self.r[H + self.rixy]",
        .AF => "self.r[A]",
    };
}

pub const ALU = enum(u3) {
    ADD,
    ADC,
    SUB,
    SBC,
    AND,
    XOR,
    OR,
    CP,

    fn asEnum(any: anytype) ALU {
        if (@TypeOf(any) != u3 and @TypeOf(any) != ALU) {
            @compileError("arg must be of type u3 or ALU");
        }
        return if (@TypeOf(any) == ALU) any else @enumFromInt(any);
    }

    pub fn dasm(any: anytype) []const u8 {
        return @tagName(asEnum(any));
    }
};

pub fn alu(any: anytype) []const u8 {
    return switch (ALU.asEnum(any)) {
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

pub const CC = enum(u3) {
    NZ,
    Z,
    NC,
    C,
    PO,
    PE,
    P,
    M,

    fn asEnum(any: anytype) CC {
        if (@TypeOf(any) != u3 and @TypeOf(any) != ALU) {
            @compileError("arg must be of type u3 or ALU");
        }
        return if (@TypeOf(any) == CC) any else @enumFromInt(any);
    }

    pub fn dasm(any: anytype) []const u8 {
        return @tagName(asEnum(any));
    }
};

pub fn cc(any: anytype) []const u8 {
    return @tagName(CC.asEnum(any));
}

pub const ROT = enum(u3) { RLC, RRC, RL, RR, SLA, SRA, SLL, SRL };
