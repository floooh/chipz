const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const bits = chips.bits;
const z80 = chips.z80;

const Z80 = z80.Z80(z80.DefaultPins, u64);

var cpu: Z80 = undefined;
var bus: u64 = 0;
var mem = [_]u8{0} ** 0x10000;

const MREQ = z80.DefaultPins.MREQ;
const RD = z80.DefaultPins.RD;
const WR = z80.DefaultPins.WR;

fn T(cond: bool) void {
    assert(cond);
}

fn start(msg: []const u8) void {
    std.debug.print("=> {s} ... ", .{msg});
}

fn ok() void {
    std.debug.print("ok\n", .{});
}

fn init(start_addr: u16, bytes: []const u8) void {
    cpu = Z80{};
    cpu.r[z80.F] = 0;
    cpu.af2 = 0xFF00;
    cpu.bc2 = 0xFFFF;
    cpu.de2 = 0xFFFF;
    cpu.hl2 = 0xFFFF;
    copy(start_addr, bytes);
    cpu.prefetch(start_addr);
    _ = step();
}

fn copy(start_addr: u16, bytes: []const u8) void {
    std.mem.copyForwards(u8, mem[start_addr..bytes.len], bytes);
}

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

fn step() usize {
    var num_ticks: usize = 1;
    bus = cpu.tick(bus);
    while (!cpu.opdone(bus)) {
        bus = cpu.tick(bus);
        num_ticks += 1;
    }
    return num_ticks;
}

fn NOP() void {
    start("NOP");
    const prog = [_]u8{0};
    init(0, &prog);
    T(4 == step());
    T(4 == step());
    ok();
}

pub fn main() void {
    NOP();
}
