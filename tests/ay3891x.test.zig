const expect = @import("std").testing.expect;
const expectApproxEqAbs = @import("std").testing.expectApproxEqAbs;
const ay3891 = @import("chipz").chips.ay3891;

const pins = ay3891.DefaultPins;

test "init AY38910" {
    const AY38910 = ay3891.AY3891(.AY38910, pins, u32);
    const ay = AY38910.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .volume = 0.5,
    });
    try expect(ay.noise.rng == 1);
    try expectApproxEqAbs(ay.sample.volume, 0.5, 0.001);
    try expect(ay.tone[0].period == 1);
    try expect(ay.tone[1].period == 1);
    try expect(ay.tone[2].period == 1);
}

test "init AY38912" {
    const AY38912 = ay3891.AY3891(.AY38912, pins, u32);
    const ay = AY38912.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .volume = 0.5,
    });
    try expect(ay.noise.rng == 1);
    try expectApproxEqAbs(ay.sample.volume, 0.5, 0.001);
    try expect(ay.tone[0].period == 1);
    try expect(ay.tone[1].period == 1);
    try expect(ay.tone[2].period == 1);
}

test "init AY38913" {
    const AY38913 = ay3891.AY3891(.AY38913, pins, u32);
    const ay = AY38913.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .volume = 0.5,
    });
    try expect(ay.noise.rng == 1);
    try expectApproxEqAbs(ay.sample.volume, 0.5, 0.001);
    try expect(ay.tone[0].period == 1);
    try expect(ay.tone[1].period == 1);
    try expect(ay.tone[2].period == 1);
}

test "chip select" {
    const AY38910 = ay3891.AY3891(.AY38910, pins, u32);
    const ay = AY38910.init(.{
        .tick_hz = 3000000,
        .sound_hz = 44100,
        .chip_select = 3,
    });
    try expect(ay.cs_mask == (3 << 4));
}
