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
