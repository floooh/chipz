const sokol = @import("sokol");
const saudio = sokol.audio;
const slog = sokol.log;

pub const Options = struct {
    disable_audio: bool = false,
};

const state = struct {
    var disable_audio: bool = false;
};

pub fn init(opts: Options) void {
    state.disable_audio = opts.disable_audio;
    if (!state.disable_audio) {
        saudio.setup(.{ .logger = .{ .func = slog.func } });
    }
}

pub fn shutdown() void {
    if (!state.disable_audio) {
        saudio.shutdown();
    }
}

pub fn sampleRate() u32 {
    if (state.disable_audio) {
        return 44100;
    } else {
        return @intCast(saudio.sampleRate());
    }
}

pub fn push(samples: []const f32) void {
    if (!state.disable_audio) {
        _ = saudio.push(&samples[0], @intCast(samples.len));
    }
}
