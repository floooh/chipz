const expect = @import("std").testing.expect;
const expectApproxEqAbs = @import("std").testing.expectApproxEqAbs;
const ay3891 = @import("chipz").chips.ay3891;

const pins = ay3891.DefaultPins;
const AY38910 = ay3891.AY3891(.AY38910, pins, u32);
const AY38912 = ay3891.AY3891(.AY38912, pins, u32);
const AY38913 = ay3891.AY3891(.AY38913, pins, u32);

const BDIR = AY38910.BDIR;
const BC1 = AY38910.BC1;
const setData = AY38910.setData;
const getData = AY38910.getData;

const PERIOD_A_FINE = @intFromEnum(AY38910.Reg.PERIOD_A_FINE);
const PERIOD_A_COARSE = @intFromEnum(AY38910.Reg.PERIOD_A_COARSE);
const PERIOD_B_FINE = @intFromEnum(AY38910.Reg.PERIOD_B_FINE);
const PERIOD_B_COARSE = @intFromEnum(AY38910.Reg.PERIOD_B_COARSE);
const PERIOD_C_FINE = @intFromEnum(AY38910.Reg.PERIOD_C_FINE);
const PERIOD_C_COARSE = @intFromEnum(AY38910.Reg.PERIOD_C_COARSE);
const PERIOD_NOISE = @intFromEnum(AY38910.Reg.PERIOD_NOISE);
const ENABLE = @intFromEnum(AY38910.Reg.ENABLE);
const AMP_A = @intFromEnum(AY38910.Reg.AMP_A);
const AMP_B = @intFromEnum(AY38910.Reg.AMP_B);
const AMP_C = @intFromEnum(AY38910.Reg.AMP_C);
const ENV_PERIOD_FINE = @intFromEnum(AY38910.Reg.ENV_PERIOD_FINE);
const ENV_PERIOD_COARSE = @intFromEnum(AY38910.Reg.ENV_PERIOD_COARSE);
const ENV_SHAPE_CYCLE = @intFromEnum(AY38910.Reg.ENV_SHAPE_CYCLE);
const IO_PORT_A = @intFromEnum(AY38910.Reg.IO_PORT_A);
const IO_PORT_B = @intFromEnum(AY38910.Reg.IO_PORT_B);

test "init AY38910" {
    const ay = AY38910.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .volume = 0.5,
    });
    try expect(ay.noise.rng == 1);
    try expectApproxEqAbs(ay.smp.volume, 0.5, 0.001);
    try expect(ay.tone[0].period == 1);
    try expect(ay.tone[1].period == 1);
    try expect(ay.tone[2].period == 1);
}

test "init AY38912" {
    const ay = AY38912.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .volume = 0.5,
    });
    try expect(ay.noise.rng == 1);
    try expectApproxEqAbs(ay.smp.volume, 0.5, 0.001);
    try expect(ay.tone[0].period == 1);
    try expect(ay.tone[1].period == 1);
    try expect(ay.tone[2].period == 1);
}

test "init AY38913" {
    const ay = AY38913.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .volume = 0.5,
    });
    try expect(ay.noise.rng == 1);
    try expectApproxEqAbs(ay.smp.volume, 0.5, 0.001);
    try expect(ay.tone[0].period == 1);
    try expect(ay.tone[1].period == 1);
    try expect(ay.tone[2].period == 1);
}

test "chip select mask" {
    const ay = AY38910.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .chip_select = 3,
    });
    try expect(ay.cs_mask == (3 << 4));
}

test "read/write registers" {
    var ay = AY38910.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
    });
    // write PERIOD_A_FINE register
    _ = ay.tick(setData(0, PERIOD_A_FINE) | BDIR | BC1);
    try expect(ay.addr == PERIOD_A_FINE);
    _ = ay.tick(setData(0, 0xAA) | BDIR);
    try expect(ay.regs[PERIOD_A_FINE] == 0xAA);
    // write PERIOD_A_COARSE reg
    _ = ay.tick(setData(0, PERIOD_A_COARSE) | BDIR | BC1);
    try expect(ay.addr == PERIOD_A_COARSE);
    _ = ay.tick(setData(0, 0xBB) | BDIR);
    try expect(ay.regs[PERIOD_A_COARSE] == 0x0B);
    try expect(ay.tone[0].period == 0xBAA);
    // read PERIOD_A_FINE register
    _ = ay.tick(setData(0, PERIOD_A_FINE) | BDIR | BC1);
    try expect(ay.addr == PERIOD_A_FINE);
    try expect(getData(ay.tick(BC1)) == 0xAA);
    // read PERIOD_A_COARSE register
    _ = ay.tick(setData(0, PERIOD_A_COARSE) | BDIR | BC1);
    try expect(ay.addr == PERIOD_A_COARSE);
    try expect(getData(ay.tick(BC1)) == 0x0B);
}

test "register masks" {
    var ay = AY38910.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
    });
    const f = struct {
        fn writeRead(chip: *AY38910, reg: u8, val: u8) u8 {
            // latch address
            _ = chip.tick(setData(0, reg) | BDIR | BC1);
            // write register
            _ = chip.tick(setData(0, val) | BDIR);
            // read register
            return getData(chip.tick(BC1));
        }
    };
    try expect(f.writeRead(&ay, PERIOD_A_FINE, 0xFF) == 0xFF);
    try expect(f.writeRead(&ay, PERIOD_A_COARSE, 0xFF) == 0x0F);
    try expect(f.writeRead(&ay, PERIOD_B_FINE, 0xEE) == 0xEE);
    try expect(f.writeRead(&ay, PERIOD_B_COARSE, 0xEE) == 0x0E);
    try expect(f.writeRead(&ay, PERIOD_C_FINE, 0xDD) == 0xDD);
    try expect(f.writeRead(&ay, PERIOD_C_COARSE, 0xDD) == 0x0D);
    try expect(f.writeRead(&ay, PERIOD_NOISE, 0xFF) == 0x1F);
    try expect(f.writeRead(&ay, ENABLE, 0xFF) == 0xFF);
    try expect(f.writeRead(&ay, AMP_A, 0xFA) == 0x1A);
    try expect(f.writeRead(&ay, AMP_B, 0xFB) == 0x1B);
    try expect(f.writeRead(&ay, AMP_C, 0xFC) == 0x1C);
    try expect(f.writeRead(&ay, ENV_PERIOD_FINE, 0xFF) == 0xFF);
    try expect(f.writeRead(&ay, ENV_PERIOD_FINE, 0xEE) == 0xEE);
    try expect(f.writeRead(&ay, ENV_SHAPE_CYCLE, 0xFF) == 0x0F);
    try expect(f.writeRead(&ay, IO_PORT_A, 0xEE) == 0xEE);
    try expect(f.writeRead(&ay, IO_PORT_B, 0xCC) == 0xCC);
}
