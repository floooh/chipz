//! audio filter (dc adjustment and lowpass filter)
//! taken from: https://github.com/arnaud-carre/StSound
const std = @import("std");
const assert = std.debug.assert;
const isPowerOfTwo = std.math.isPowerOfTwo;

pub const Config = struct {
    enable_dcadjust: bool,
    enable_lowpass_filter: bool,
    dcadjust_buf_len: u32,
};

pub fn Type(cfg: Config) type {
    assert(isPowerOfTwo(cfg.dcadjust_buf_len));
    return struct {
        const Self = @This();

        lopass: [2]f32 = [_]f32{0} ** 2,
        dcadj: struct {
            sum: f32 = 0,
            pos: u32 = 0,
            buf: [cfg.dcadjust_buf_len]f32 = [_]f32{0} ** cfg.dcadjust_buf_len,
        } = .{},

        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        pub fn put(self: *Self, in: f32) f32 {
            var s = in;
            if (cfg.enable_dcadjust) {
                s = self.dcAdjust(s);
            }
            if (cfg.enable_lowpass_filter) {
                s = self.lowPassFilter(s);
            }
            return s;
        }

        fn dcAdjust(self: *Self, in: f32) f32 {
            const pos = self.dcadj.pos;
            self.dcadj.sum -= self.dcadj.buf[pos];
            self.dcadj.sum += in;
            self.dcadj.buf[pos] = in;
            self.dcadj.pos = (pos + 1) & (cfg.dcadjust_buf_len - 1);
            const div: f32 = @floatFromInt(cfg.dcadjust_buf_len);
            return in - (self.dcadj.sum / div);
        }

        fn lowPassFilter(self: *Self, in: f32) f32 {
            const out = self.lopass[0] * 0.25 + self.lopass[1] * 0.5 + in * 0.25;
            self.lopass[0] = self.lopass[1];
            self.lopass[1] = in;
            return out;
        }
    };
}
