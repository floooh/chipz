//! a simple square wave beeper sound device
const filter = @import("filter.zig");

pub const TypeConfig = struct {
    dcadjust_buf_len: u32 = 128,
    enable_lowpass_filter: bool = true,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            tick_hz: u32,
            sound_hz: u32,
            base_volume: f32 = 1.0,
        };

        const OVERSAMPLE_PERIOD = 16; // anti-aliasing oversampling
        const OVERSAMPLE_MUL: f32 = 1.0 / @as(f32, @floatFromInt(OVERSAMPLE_PERIOD));
        const FIXEDPOINT_SCALE = 256; // error-reduction for sample period counter

        state: u1 = 0,
        period: i32 = 0,
        counter: i32 = 0,
        oversample_counter: u8 = OVERSAMPLE_PERIOD,
        oversample_accum: f32 = 0.0, // oversampling accumulator for anti-aliasing
        base_volume: f32 = 1.0,
        volume: f32 = 1.0,
        sample: struct {
            ready: bool = false,
            out: f32 = 0.0,
        } = .{},
        filter: filter.Type(.{
            .enable_dcadjust = true,
            .enable_lowpass_filter = cfg.enable_lowpass_filter,
            .dcadjust_buf_len = cfg.dcadjust_buf_len,
        }) = .{},

        pub fn init(opts: Options) Self {
            const period: i32 = @intCast((opts.tick_hz * FIXEDPOINT_SCALE) / (opts.sound_hz * OVERSAMPLE_PERIOD));
            return .{
                .period = period,
                .counter = period,
                .oversample_counter = OVERSAMPLE_PERIOD,
                .base_volume = opts.base_volume,
            };
        }

        pub fn reset(self: *Self) void {
            self.state = 0;
            self.counter = self.period;
            self.sample = .{};
        }

        pub fn setVolume(self: *Self, v: f32) void {
            self.volume = v;
        }

        pub fn toggle(self: *Self) void {
            self.state ^= 1;
        }

        pub fn set(self: *Self, on: bool) void {
            self.state = if (on) 1 else 0;
        }

        pub fn tick(self: *Self) bool {
            self.counter -= FIXEDPOINT_SCALE;
            if (self.counter <= 0) {
                self.counter += self.period;
                self.oversample_accum += @as(f32, @floatFromInt(self.state)) * self.volume * self.base_volume;
                self.oversample_counter -= 1;
                if (self.oversample_counter == 0) {
                    // new sample ready
                    self.oversample_counter = OVERSAMPLE_PERIOD;
                    const s = self.oversample_accum * OVERSAMPLE_MUL;
                    self.sample.out = self.filter.put(s);
                    self.oversample_accum = 0;
                    return true;
                }
            }
            return false;
        }
    };
}
