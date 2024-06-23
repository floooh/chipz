//------------------------------------------------------------------------------
//  z80int.zig
//
//  Test Z80 interrupt timing.
//------------------------------------------------------------------------------
const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const bits = chips.bits;
const z80 = chips.z80;

const Z80 = z80.Z80(Z80.DefaultPins, u64);

var cpu: Z80 = undefined;
var bus: u64 = 0;
var mem = [_]u8{0} ** 0x10000;

const CTRL = Z80.CTRL;
const M1 = Z80.M1;
const MREQ = Z80.MREQ;
const IORQ = Z80.IORQ;
const RD = Z80.RD;
const WR = Z80.WR;
const INT = Z80.INT;
const NMI = Z80.NMI;

fn tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if ((bus & MREQ) != 0) {
        if ((bus & RD) != 0) {
            bus = Z80.setData(bus, mem[addr]);
        } else if ((bus & WR) != 0) {
            mem[addr] = Z80.getData(bus);
        }
    } else if ((bus & (M1 | IORQ)) == M1 | IORQ) {
        // put 0xE0 on data bus (in IM2 mode this is the low byte of the
        // interrupt vector, and in IM1 mode it is ignored)
        bus = Z80.setData(bus, 0xE0);
    }
}

// special IM0 tick function, puts the RST 38h opcode on the data bus
fn im0Tick() void {
    bus = cpu.tick(bus);
    const addr = Z80.getAddr(bus);
    if ((bus & MREQ) != 0) {
        if ((bus & RD) != 0) {
            bus = Z80.setData(bus, mem[addr]);
        } else if ((bus & WR) != 0) {
            mem[addr] = Z80.getData(bus);
        }
    } else if ((bus & (M1 | IORQ)) == M1 | IORQ) {
        bus = Z80.setData(bus, 0xFF);
    }
}

fn copy(start_addr: u16, bytes: []const u8) void {
    std.mem.copyForwards(u8, mem[start_addr..], bytes);
}

fn init(start_addr: u16, bytes: []const u8) void {
    cpu = Z80{};
    copy(start_addr, bytes);
    cpu.prefetch(start_addr);
}

pub fn main() void {
    std.debug.print("FIXME!\n", .{});
}
