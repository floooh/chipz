//! implements a paged memory system for emulators with up to 16 bits address range
//!
//! NOTE: all user-provided slices must reference host memory that outlives the Memory object!
//!
const std = @import("std");
const assert = std.debug.assert;

/// a memory page has separate read and write pointers:
///
/// - for RAM both point to the same host memory area
/// - for ROM, the read pointer points to a host memory area
///   with the ROM data, and the write pointer points to a junk page
/// - for RAM-under-ROM, the read pointer points to a host memory area
///   with the ROM data, and the write pointer points to a separate
///   host memory area
/// - for unmapped memory, the read pointer points to a special
///   'unmapped page' which is filled with a user-provided 'unmapped value'
///   (typically 0xFF), and the write pointer points to the junk page
pub const Page = struct {
    read: [*]const u8,
    write: [*]u8,
};

pub const TypeConfig = struct {
    page_size: comptime_int,
};

pub fn Type(comptime cfg: TypeConfig) type {
    assert(std.math.isPowerOfTwo(cfg.page_size));

    return struct {
        const Self = @This();

        pub const ADDR_RANGE = 0x10000;
        pub const ADDR_MASK = ADDR_RANGE - 1;

        /// Memory init options
        pub const Options = struct {
            /// a user-provided memory area of 'page_size' as junk page
            junk_page: []u8,
            /// a user-provided memory area of 'page_size' for unmapped memory
            /// this is expected to be filled with the value the CPU would read
            /// when accessing unmapped memory (typically 0xFF)
            unmapped_page: []const u8,
        };

        pub const PAGE_SIZE: usize = cfg.page_size;
        pub const PAGE_SHIFT: usize = std.math.log2_int(u16, cfg.page_size);
        pub const NUM_PAGES: usize = ADDR_RANGE / PAGE_SIZE;
        pub const PAGE_MASK: usize = PAGE_SIZE - 1;

        unmapped_page: []const u8,
        junk_page: []u8,
        pages: [NUM_PAGES]Page,

        pub fn init(options: Options) Self {
            assert(options.junk_page.len == PAGE_SIZE);
            assert(options.unmapped_page.len == PAGE_SIZE);
            return .{
                .unmapped_page = options.unmapped_page,
                .junk_page = options.junk_page,
                .pages = [_]Page{.{
                    .read = options.unmapped_page.ptr,
                    .write = options.junk_page.ptr,
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

        // write 16-bit value to memory
        pub inline fn wr16(self: *Self, addr: u16, data: u16) void {
            self.wr(addr, @truncate(data >> 8));
            self.wr(addr +% 1, @truncate(data));
        }

        /// map address range as RAM to host memory
        pub fn mapRAM(self: *Self, addr: u16, size: u17, ram: []u8) void {
            assert(ram.len == size);
            self.map(addr, size, ram, ram);
        }

        /// map address range as ROM to host memory (reads from host, writes to junk page)
        pub fn mapROM(self: *Self, addr: u16, size: u17, rom: []const u8) void {
            assert(rom.len == size);
            self.map(addr, size, rom, null);
        }

        /// map separate read and write address ranges (for RAM-under-ROM)
        pub fn mapRW(self: *Self, addr: u16, size: u17, read: []const u8, write: []u8) void {
            assert(read.len == size);
            assert(write.len == size);
            self.map(addr, size, read, write);
        }

        /// unmap an address range (reads will yield 0xFF, and writes go to junk page)
        pub fn unmap(self: *Self, addr: u16, size: u17) void {
            self.map(addr, size, null, null);
        }

        /// map address range to separate read- and write areas in host memory (for RAM-under-ROM)
        fn map(self: *Self, addr: u16, size: u17, read: ?[]const u8, write: ?[]u8) void {
            assert(size <= ADDR_RANGE);
            assert(size >= PAGE_SIZE);
            assert((size & PAGE_MASK) == 0);

            const num_pages: usize = size >> PAGE_SHIFT;
            for (0..num_pages) |i| {
                const offset = i * PAGE_SIZE;
                const page_index: usize = ((addr + offset) & ADDR_MASK) >> PAGE_SHIFT;
                var page: *Page = &self.pages[page_index];
                if (read) |p| {
                    page.read = @ptrCast(&p[offset]);
                } else {
                    page.read = @ptrCast(self.unmapped_page);
                }
                if (write) |p| {
                    page.write = @ptrCast(&p[offset]);
                } else {
                    page.write = @ptrCast(self.junk_page);
                }
            }
        }
    };
}
