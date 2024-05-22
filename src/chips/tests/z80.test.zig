const expect = @import("std").testing.expect;
const Z80 = @import("../z80.zig").Z80;
const DefaultPins = @import("../z80.zig").DefaultPins;

test "init" {
    const cpu = Z80(DefaultPins, u64){};
    try expect(cpu.af2 == 0xFFFF);
}

test "tick" {
    var cpu = Z80(DefaultPins, u64){};
    const bus = cpu.tick(0);
    try expect(bus == (1 << 24) | (1 << 30));
}
