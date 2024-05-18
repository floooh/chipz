const std = @import("std");
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const decode = @import("decode.zig").decode;

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    decode(gpa.allocator());
}
