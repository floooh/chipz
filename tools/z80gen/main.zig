const std = @import("std");
const dec = @import("decode.zig");
const gen = @import("generate.zig");
const string = @import("string.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var ioThreaded = std.Io.Threaded.init_single_threaded;
    const io = ioThreaded.io();
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    string.init(arena.allocator());
    dec.decode();
    try gen.generate();
    try gen.write(arena.allocator(), io, "src/chips/z80.zig");
}
