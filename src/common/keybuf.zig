///! a 'sticky' key buffer to store key presses for a guaranteed amount of time
const assert = @import("std").debug.assert;

// comptime config options
const Config = struct {
    num_slots: comptime_int = 8, // number of max simultanously pressed keys
};

pub fn Type(comptime cfg: Config) type {
    assert(cfg.num_slots > 0);
    return struct {
        const Self = @This();

        // runtime options
        pub const Options = struct {
            sticky_time: u64 = 32, // number of time units a pressed key should 'stick'
        };

        // state of a single currently pressed key
        pub const Slot = struct {
            // key code of the pressed key (zero if slot is not populated)
            key: u32 = 0,
            // optional keyboard matrix bit mask
            mask: u32 = 0,
            // timestamp of when the key was pressed down
            pressed_time: u64 = 0,
            // set to true when the key has been released
            released: bool = false,
        };

        slots: [cfg.num_slots]Slot = [_]Slot{.{}} ** cfg.num_slots,
        cur_time: u64 = 0,
        sticky_time: u64 = 0,

        pub fn init(options: Options) Self {
            return .{
                .sticky_time = options.sticky_time,
            };
        }

        // call once per frame with frame duration in your chosen time unit
        pub fn update(self: *Self, frame_time: u64) void {
            self.cur_time +%= frame_time;
            for (&self.slots) |*slot| {
                if (slot.released) {
                    // properly handle time wraparound
                    if ((self.cur_time < slot.pressed_time) or
                        (self.cur_time >= (slot.pressed_time +% self.sticky_time)))
                    {
                        slot.* = .{};
                    }
                }
            }
        }

        // call when a key is pressed down
        pub fn keyDown(self: *Self, key: u32, mask: u32) void {
            // first check if the key is already buffered, if yes only update timestamp
            for (&self.slots) |*slot| {
                if (key == slot.key) {
                    assert(slot.mask == mask);
                    slot.pressed_time = self.cur_time;
                    return;
                }
            }
            // otherwise find a populate a free slot
            for (&self.slots) |*slot| {
                if (0 == slot.key) {
                    slot.key = key;
                    slot.mask = mask;
                    slot.pressed_time = self.cur_time;
                    slot.released = false;
                    return;
                }
            }
        }

        // call when a pressed key is released
        pub fn keyUp(self: *Self, key: u32) void {
            for (&self.slots) |*slot| {
                if (key == slot.key) {
                    slot.released = true;
                    return;
                }
            }
        }

        // 'unpress' all keys, call this when the emulator window looses focus
        pub fn flush(self: *Self) void {
            for (&self.slots) |*slot| {
                slot.* = .{};
            }
        }
    };
}
