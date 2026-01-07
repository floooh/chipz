const std = @import("std");
const dec = @import("decode.zig");
const gen = @import("generate.zig");
const string = @import("string.zig");

pub fn main(init: std.process.Init) !void {
    string.init(init.arena.allocator());
    dec.decode();
    try gen.generate();
    try gen.write(init.arena.allocator(), init.io, "src/chips/z80.zig");
}
