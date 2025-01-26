const stm = @import("sokol").time;

const state = struct {
    var start_time: u64 = 0;
    var frame_lap: u64 = 0;
    var emu_start: u64 = 0;
};

pub fn init() void {
    stm.setup();
    state.start_time = stm.now();
    state.frame_lap = state.start_time;
}

// return frame time in microseconds
pub fn frameTime() u32 {
    var frame_time = stm.us(stm.laptime(&state.frame_lap));
    // prevent death spiral on host systems which are too slow to
    // run the emulator in realtime, and also during debugging
    if (frame_time < 1000) {
        frame_time = 1000;
    } else if (frame_time > 24000) {
        frame_time = 24000;
    }
    return @intFromFloat(frame_time);
}

pub fn emuStart() void {
    state.emu_start = stm.now();
}

pub fn emuEnd() u32 {
    return @intFromFloat(stm.us(stm.since(state.emu_start)));
}

// return true if time since start is after provided time
pub fn after(micro_seconds: u64) bool {
    const elapsed_us: u64 = @intFromFloat(stm.us(stm.since(state.start_time)));
    return elapsed_us > micro_seconds;
}

// a helper which triggers an action once after a delay
pub const Once = struct {
    elapsed_us: u64 = 0,
    delay_us: u64,
    triggered: bool,

    pub fn init(delay_us: u64) Once {
        return .{
            .delay_us = delay_us,
            .triggered = false,
        };
    }

    pub fn once(self: *Once, delta_us: u64) bool {
        self.elapsed_us +%= delta_us;
        if (!self.triggered and (self.elapsed_us >= self.delay_us)) {
            self.triggered = true;
            return true;
        } else {
            return false;
        }
    }
};
