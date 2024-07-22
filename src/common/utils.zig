const std = @import("std");
const assert = std.debug.assert;

// shorthand for std.mem.copyForwards
pub fn cp(src: []const u8, dst: []u8) void {
    std.mem.copyForwards(u8, dst, src);
}

// 32-bit xorshifter
pub fn xorshift32(in_x: u32) u32 {
    var x = in_x;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

pub fn fillNoise(slice: []u8, seed: u32) u32 {
    assert((slice.len & 3) == 0);
    var x = seed;
    for (0..(slice.len >> 2)) |i| {
        x = xorshift32(x);
        slice[i * 4] = @truncate(x);
        slice[i * 4 + 1] = @truncate(x >> 8);
        slice[i * 4 + 2] = @truncate(x >> 16);
        slice[i * 4 + 3] = @truncate(x >> 24);
    }
    return x;
}
