//! an audio DC adjuster (centers an off-center signal)
//! see: https://github.com/arnaud-carre/StSound/blob/91d2d3c604386c637b038bba747c8da6c976c245/StSoundLibrary/Ym2149Ex.cpp#L67-L93
const std = @import("std");
const assert = std.debug.assert;
const isPowerOfTwo = std.math.isPowerOfTwo;

pub const Config = struct {
    buf_len: comptime_int,
};

pub fn Type(cfg: Config) type {
    assert(isPowerOfTwo(cfg.buf_len));

    return struct {
        const Self = @This();

        sum: f32 = 0,
        pos: u32 = 0,
        buf: [cfg.buf_len]f32 = [_]f32{0.0} ** cfg.buf_len,

        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        pub fn put(self: *Self, s: f32) f32 {
            const pos = self.pos;
            self.sum -= self.buf[pos];
            self.sum += s;
            self.buf[pos] = s;
            self.pos = (pos + 1) & (cfg.buf_len - 1);
            const div: f32 = @floatFromInt(cfg.buf_len);
            return s - (self.sum / div);
        }
    };
}
