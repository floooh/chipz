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

        const OVERSAMPLE = 8; // anti-aliasing oversampling
        const FIXEDPOINT_SCALE = 16; // error-reduction for sample period counter

        state: u1 = 0,
        period: i32 = 0,
        counter: i32 = 0,
        base_volume: f32 = 1.0,
        volume: f32 = 1.0,
        sample: struct {
            ready: bool = false,
            out: f32 = 0.0,
            accum: f32 = 0.0, // oversampling accumulator for anti-aliasing
            div: f32 = 0.0, // oversampling divider
        },
        filter: filter.Type(.{
            .enable_dcadjust = true,
            .enable_lowpass_filter = cfg.enable_lowpass_filter,
            .dcadjust_buf_len = cfg.dcadjust_buf_len,
        }),

        pub fn init(opts: Options) Self {
            _ = opts; // autofix
            // FIXME
        }

        pub fn setVolume(self: *Self, v: f32) void {
            self.volume = v;
        }

        pub fn toggle(self: *Self) void {
            self.state ^= 1;
        }

        pub fn set(self: *Self, state: u1) void {
            self.state = state;
        }

        pub fn tick(self: *Self) bool {
            _ = self; // autofix
            return false;
        }
    };
}
