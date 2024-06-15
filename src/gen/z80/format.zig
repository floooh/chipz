//! low-level helper function to create formatted string on the heap
const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;

var initialized = false;
var alloc: Allocator = undefined;

pub fn init(allocator: Allocator) void {
    alloc = allocator;
    initialized = true;
}

pub fn f(comptime fmt_str: []const u8, args: anytype) []const u8 {
    return allocPrint(alloc, fmt_str, args) catch @panic("allocation failed");
}

pub fn replace(input: []const u8, needle: []const u8, replacement: []const u8) []const u8 {
    return mem.replaceOwned(u8, alloc, input, needle, replacement) catch @panic("allocation failed");
}

pub fn dup(str: []const u8) []const u8 {
    return alloc.dupe(u8, str) catch @panic("allocation failed");
}
