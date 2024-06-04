const std = @import("std");
const bits = @import("../chips/bits.zig");
const z80 = @import("../chips/z80.zig");

const Z80 = z80.Z80(z80.DefaultPins, u64);

var cpu: Z80 = undefined;
var bus: u64 = 0;
var mem: [1 << 16]u8 = undefined;

const MREQ = z80.DefaultPins.MREQ;
const RD = z80.DefaultPins.RD;
const WR = z80.DefaultPins.WR;

fn tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if (bits.tst(bus, MREQ)) {
        if (bits.tst(bus, RD)) {
            bus = Z80.setData(bus, mem[addr]);
        } else if (bits.tst(bus, WR)) {
            mem[addr] = Z80.getData(bus);
        }
    }
    // FIXME: IORQ
}

pub fn main() void {
    std.debug.print("FIXME!\n", .{});
}
