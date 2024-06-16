//! helper function for heap-backed string data
const std = @import("std");

var alloc: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    alloc = allocator;
}

pub fn f(comptime fmt_str: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt_str, args) catch @panic("allocation failed");
}

pub fn replace(input: []const u8, needle: []const u8, replacement: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, alloc, input, needle, replacement) catch @panic("allocation failed");
}

pub fn dup(str: []const u8) []const u8 {
    return alloc.dupe(u8, str) catch @panic("allocation failed");
}
