const std = @import("std");
const dec = @import("decode.zig");
const acc = @import("accumulate.zig");
const gen = @import("generate.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    dec.decode(arena.allocator());
    //acc.dump();
    gen.generate();
    try gen.write(arena.allocator(), "src/chips/z80.zig");
}
