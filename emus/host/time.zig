const stm = @import("sokol").time;

const state = struct {
    var cur_frame_time: f64 = 0;
    var last_time_stamp: u64 = 0;
    var start_time: u64 = 0;
};

pub fn init() void {
    stm.setup();
    state.start_time = stm.now();
    state.last_time_stamp = state.start_time;
}

// return frame time in microseconds
pub fn frameTime() u32 {
    state.cur_frame_time = stm.us(stm.laptime(&state.last_time_stamp));
    // prevent death spiral on host systems which are too slow to
    // run the emulator in realtime, and also during debugging
    if (state.cur_frame_time < 1000) {
        state.cur_frame_time = 1000;
    } else if (state.cur_frame_time > 24000) {
        state.cur_frame_time = 24000;
    }
    return @intFromFloat(state.cur_frame_time);
}

// return true if time since start is after provided time
pub fn after(micro_seconds: u64) bool {
    const elapsed_us: u64 = @intFromFloat(stm.us(stm.since(state.start_time)));
    return elapsed_us > micro_seconds;
}
