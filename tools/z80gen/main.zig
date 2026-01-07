const std = @import("std");
const dec = @import("decode.zig");
const gen = @import("generate.zig");
const string = @import("string.zig");

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    string.init(arena.allocator());
    dec.decode();
    try gen.generate();
    try gen.write(arena.allocator(), init.io, "src/chips/z80.zig");
}
