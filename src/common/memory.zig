//! a paged memory implementation
const std = @import("std");
const assert = std.debug.assert;

/// a memory page has seperate read and write pointers:
///
/// - for RAM both point to the same host memory area
/// - for ROM, the read pointer points to a host memory area
///   with the ROM data, and the write pointer points to a junk page
/// - for RAM-under-ROM, the read and write pointer point to
///   separate host memory areas
/// - for unmapped memory, the read pointer points to a special
///   'unmapped page' which is filled with a user-provided 'unmapped value'
///   (typically 0xFF), and the write pointer points to the junk page
const Page = struct {
    read: [*]const u8,
    write: [*]u8,
};

const ADDR_RANGE = 0x10000;

/// Memory init options
const MemoryOptions = struct {
    /// a user-provided memory area of 'page_size' as junk page, will be filled with zeroes
    junk_page: []u8,
    /// a user-provided memory area of 'page_size' for unmapped memory, will be filled 'unmapped_value'
    unmapped_page: []u8,
    /// the value to retun on reads from unmapped memory areas
    unmapped_value: u8 = 0xFF,
};

/// implements a paged memory system for emulators with up to 16 bits address range
pub fn Memory(comptime page_size: comptime_int) type {
    assert(std.math.isPowerOfTwo(page_size));

    return struct {
        const Self = @This();

        const PAGE_SIZE = page_size;
        const PAGE_SHIFT = std.math.log2_int(page_size);
        const NUM_PAGES = ADDR_RANGE / PAGE_SIZE;
        const PAGE_MASK = PAGE_SIZE - 1;

        unmapped_page: []const u8,
        junk_page: []u8,
        pages: [NUM_PAGES]Page,

        pub fn init(options: MemoryOptions) Self {
            assert(options.junk_page.len == PAGE_SIZE);
            assert(options.unmapped_page.len == PAGE_SIZE);
            for (&options.junk_page, &options.unmapped_page) |*junk, *unmapped| {
                junk.* = 0;
                unmapped.* = options.unmapped_value;
            }
            return .{
                .unmapped_page = options.unmapped_page,
                .junk_page = options.junk_page,
                .page = [_]Page{.{
                    .read = options.unmapped_page,
                    .write = options.junk_page,
                }} ** NUM_PAGES,
            };
        }

        /// read byte from memory
        pub inline fn rd(self: *const Self, addr: u16) u8 {
            return self.pages[addr >> PAGE_SHIFT].read[addr & PAGE_MASK];
        }

        /// write byte to memory
        pub inline fn wr(self: *Self, addr: u16, data: u8) void {
            self.pages[addr >> PAGE_SHIFT].write[addr & PAGE_MASK] = data;
        }

        /// map address range as RAM to host memory
        pub fn map_ram(self: *Self, addr: u16, size: u17, ptr: [*]u8) void {
            self.map_rw(addr, size, ptr, ptr);
        }

        /// map address range as ROM to host memory (reads from host, writes to junk page)
        pub fn map_rom(self: *Self, addr: u16, size: u17, ptr: [*]const u8) void {
            self.map_rw(addr, size, ptr, self.junk_page);
        }

        /// unmap an address range (reads will yield 0xFF, and writes go to junk page)
        pub fn unmap(self: *Self, addr: u16, size: u17) void {
            self.map_rw(addr, size, self.unmapped_page, self.junk_page);
        }
        /// map address range to separate read- and write areas in host memory (for RAM-under-ROM)
        pub fn map_rw(self: *Self, addr: u16, size: u17, rd_ptr: [*]const u8, wr_ptr: [*]u8) void {
            assert(size <= ADDR_RANGE);
            assert((size & PAGE_MASK) == 0);

            const num_pages: u16 = size >> PAGE_SHIFT;
            for (0..num_pages) |i| {
                const offset: u16 = i * PAGE_SIZE;
                const page_index: usize = ((addr + offset) & PAGE_MASK) >> PAGE_SHIFT;
                var page: *Page = &self.pages[page_index];
                page.read = rd_ptr + offset;
                page.write = wr_ptr + offset;
            }
        }
    };
}
