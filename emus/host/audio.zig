const sokol = @import("sokol");
const saudio = sokol.audio;
const slog = sokol.log;

pub fn init() void {
    saudio.setup(.{ .logger = .{ .func = slog.func } });
}

pub fn shutdown() void {
    saudio.shutdown();
}

pub fn sampleRate() u32 {
    return @intCast(saudio.sampleRate());
}

pub fn push(samples: []const f32) void {
    _ = saudio.push(&samples[0], @intCast(samples.len));
}
