//! support code to bind emulator audio output to the host audio system
const std = @import("std");
const assert = std.debug.assert;

/// comptime type configuration
pub const TypeConfig = struct {
    /// number of generated samples before audio callback is called
    num_samples: u32 = 128,
    /// number of voices in the input sample
    num_voices: u32,
    /// enable/disable DC-adjustment
    dcadjust_enable: bool = true,
    /// enable/disable lowpass filter
    lowpass_filter_enable: bool = true,
    /// dc-adjustment buffer size
    dcadjust_buf_len: u32 = 128,
};

pub fn Type(cfg: TypeConfig) type {
    assert(std.math.isPowerOfTwo(cfg.num_samples));
    assert(std.math.isPowerOfTwo(cfg.dcadjust_buf_len));
    assert(cfg.num_voices > 0);

    return struct {
        const Self = @This();

        const voice_volume: f32 = 1.0 / @as(f32, @floatFromInt(cfg.num_voices));

        /// called when intermediate sample buffer is full
        pub const Callback = ?*const fn (samples: []f32) void;

        /// runtime audio options
        pub const Options = struct {
            /// host audio frequency in Hz
            sample_rate: i32,
            /// output volume modulator (0..1)
            volume: f32 = 0.75,
            /// called when new chunk of audio data is ready
            callback: Callback,
        };

        volume: f32,
        callback: Callback,
        pos: u32 = 0,
        filter: struct {
            lopass: [2]f32 = [_]f32{0} ** 2,
            dcadj: struct {
                sum: f32 = 0,
                pos: u32 = 0,
                buf: [cfg.dcadjust_buf_len]f32 = [_]f32{0} ** cfg.dcadjust_buf_len,
            } = .{},
        } = .{},
        buf: [cfg.num_samples]f32,

        pub fn init(opts: Options) Self {
            return .{
                .volume = opts.volume,
                .callback = opts.callback,
                .buf = std.mem.zeroes([cfg.num_samples]f32),
            };
        }

        pub fn reset(self: *Self) void {
            self.pos = 0;
            self.buf = std.mem.zeroes(@TypeOf(self.buf));
            self.filter = .{};
        }

        pub fn put(self: *Self, sample: f32) void {
            var s = sample * self.volume * voice_volume;
            if (cfg.dcadjust_enable) {
                s = self.dcAdjust(s);
            }
            if (cfg.lowpass_filter_enable) {
                s = self.lowPassFilter(s);
            }
            s = std.math.clamp(s, -1.0, 1.0);
            self.buf[self.pos] = s;
            self.pos += 1;
            if (self.pos == cfg.num_samples) {
                if (self.callback) |cb| {
                    cb(&self.buf);
                }
                self.pos = 0;
            }
        }

        fn dcAdjust(self: *Self, in: f32) f32 {
            const pos = self.filter.dcadj.pos;
            self.filter.dcadj.sum -= self.filter.dcadj.buf[pos];
            self.filter.dcadj.sum += in;
            self.filter.dcadj.buf[pos] = in;
            self.filter.dcadj.pos = (pos + 1) & (cfg.dcadjust_buf_len - 1);
            const div: f32 = @floatFromInt(cfg.dcadjust_buf_len);
            return in - (self.filter.dcadj.sum / div);
        }

        fn lowPassFilter(self: *Self, in: f32) f32 {
            const out = self.filter.lopass[0] * 0.25 + self.filter.lopass[1] * 0.5 + in * 0.25;
            self.filter.lopass[0] = self.filter.lopass[1];
            self.filter.lopass[1] = in;
            return out;
        }
    };
}
