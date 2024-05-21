const expect = @import("std").testing.expect;
const Z80 = @import("../Z80.zig");

test "init" {
    const z80 = Z80.init();
    try expect(z80.af2 == 0xFFFF);
}

test "tick" {
    var z80 = Z80.init();
    const bus = z80.tick(Z80.DefaultPins, u64, 0);
    try expect(bus == (1 << 24) | (1 << 30));
}
