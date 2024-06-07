// zig fmt: off
const std = @import("std");
const assert = std.debug.assert;
const chips = @import("chips");
const bits = chips.bits;
const z80 = chips.z80;

const Z80 = z80.Z80(z80.DefaultPins, u64);

const A = z80.A;
const F = z80.F;
const B = z80.B;
const C = z80.C;
const D = z80.D;
const E = z80.E;
const L = z80.L;
const H = z80.H;

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
    tick();
    while (!cpu.opdone(bus)) {
        tick();
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

fn LD_r_sn() void {
    start("LD r,s/n");
    const prog = [_]u8{
        0x3E, 0x12, // LD A,0x12
        0x47, // LD B,A
        0x4F, // LD C,A
        0x57, // LD D,A
        0x5F, // LD E,A
        0x67, // LD H,A
        0x6F, // LD L,A
        0x7F, // LD A,A
        0x06, 0x13, // LD B,0x13
        0x40, // LD B,B
        0x48, // LD C,B
        0x50, // LD D,B
        0x58, // LD E,B
        0x60, // LD H,B
        0x68, // LD L,B
        0x78, // LD A,B
        0x0E, 0x14, // LD C,0x14
        0x41, // LD B,C
        0x49, // LD C,C
        0x51, // LD D,C
        0x59, // LD E,C
        0x61, // LD H,C
        0x69, // LD L,C
        0x79, // LD A,C
        0x16, 0x15, // LD D,0x15
        0x42, // LD B,D
        0x4A, // LD C,D
        0x52, // LD D,D
        0x5A, // LD E,D
        0x62, // LD H,D
        0x6A, // LD L,D
        0x7A, // LD A,D
        0x1E, 0x16, // LD E,0x16
        0x43, // LD B,E
        0x4B, // LD C,E
        0x53, // LD D,E
        0x5B, // LD E,E
        0x63, // LD H,E
        0x6B, // LD L,E
        0x7B, // LD A,E
        0x26, 0x17, // LD H,0x17
        0x44, // LD B,H
        0x4C, // LD C,H
        0x54, // LD D,H
        0x5C, // LD E,H
        0x64, // LD H,H
        0x6C, // LD L,H
        0x7C, // LD A,H
        0x2E, 0x18, // LD L,0x18
        0x45, // LD B,L
        0x4D, // LD C,L
        0x55, // LD D,L
        0x5D, // LD E,L
        0x65, // LD H,L
        0x6D, // LD L,L
        0x7D, // LD A,L
    };
    init(0, &prog);
    T(7==step()); T(0x12==cpu.r[A]);
    T(4==step()); T(0x12==cpu.r[B]);
    T(4==step()); T(0x12==cpu.r[C]);
    T(4==step()); T(0x12==cpu.r[D]);
    T(4==step()); T(0x12==cpu.r[E]);
    T(4==step()); T(0x12==cpu.r[H]);
    T(4==step()); T(0x12==cpu.r[L]);
    T(4==step()); T(0x12==cpu.r[A]);
    T(7==step()); T(0x13==cpu.r[B]);
    T(4==step()); T(0x13==cpu.r[B]);
    T(4==step()); T(0x13==cpu.r[C]);
    T(4==step()); T(0x13==cpu.r[D]);
    T(4==step()); T(0x13==cpu.r[E]);
    T(4==step()); T(0x13==cpu.r[H]);
    T(4==step()); T(0x13==cpu.r[L]);
    T(4==step()); T(0x13==cpu.r[A]);
    T(7==step()); T(0x14==cpu.r[C]);
    T(4==step()); T(0x14==cpu.r[B]);
    T(4==step()); T(0x14==cpu.r[C]);
    T(4==step()); T(0x14==cpu.r[D]);
    T(4==step()); T(0x14==cpu.r[E]);
    T(4==step()); T(0x14==cpu.r[H]);
    T(4==step()); T(0x14==cpu.r[L]);
    T(4==step()); T(0x14==cpu.r[A]);
    T(7==step()); T(0x15==cpu.r[D]);
    T(4==step()); T(0x15==cpu.r[B]);
    T(4==step()); T(0x15==cpu.r[C]);
    T(4==step()); T(0x15==cpu.r[D]);
    T(4==step()); T(0x15==cpu.r[E]);
    T(4==step()); T(0x15==cpu.r[H]);
    T(4==step()); T(0x15==cpu.r[L]);
    T(4==step()); T(0x15==cpu.r[A]);
    T(7==step()); T(0x16==cpu.r[E]);
    T(4==step()); T(0x16==cpu.r[B]);
    T(4==step()); T(0x16==cpu.r[C]);
    T(4==step()); T(0x16==cpu.r[D]);
    T(4==step()); T(0x16==cpu.r[E]);
    T(4==step()); T(0x16==cpu.r[H]);
    T(4==step()); T(0x16==cpu.r[L]);
    T(4==step()); T(0x16==cpu.r[A]);
    T(7==step()); T(0x17==cpu.r[H]);
    T(4==step()); T(0x17==cpu.r[B]);
    T(4==step()); T(0x17==cpu.r[C]);
    T(4==step()); T(0x17==cpu.r[D]);
    T(4==step()); T(0x17==cpu.r[E]);
    T(4==step()); T(0x17==cpu.r[H]);
    T(4==step()); T(0x17==cpu.r[L]);
    T(4==step()); T(0x17==cpu.r[A]);
    T(7==step()); T(0x18==cpu.r[L]);
    T(4==step()); T(0x18==cpu.r[B]);
    T(4==step()); T(0x18==cpu.r[C]);
    T(4==step()); T(0x18==cpu.r[D]);
    T(4==step()); T(0x18==cpu.r[E]);
    T(4==step()); T(0x18==cpu.r[H]);
    T(4==step()); T(0x18==cpu.r[L]);
    T(4==step()); T(0x18==cpu.r[A]);
    ok();
}

pub fn main() void {
    NOP();
    LD_r_sn();
}
