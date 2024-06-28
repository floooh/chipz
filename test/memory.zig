const expect = @import("std").testing.expect;
const memory = @import("chipz").common.memory;

const PAGE_SIZE = 4096;
const Memory = memory.Memory(PAGE_SIZE);
const options = memory.MemoryOptions{
    .junk_page = &junk_page,
    .unmapped_page = &unmapped_page,
};

var junk_page = [_]u8{0} ** PAGE_SIZE;
const unmapped_page = [_]u8{0xFF} ** PAGE_SIZE;
var mem = [_]u8{0} ** memory.ADDR_RANGE;

test "memory config" {
    try expect(Memory.PAGE_SIZE == 4096);
    try expect(Memory.PAGE_SHIFT == 12);
    try expect(Memory.NUM_PAGES == 16);
    try expect(Memory.PAGE_MASK == 4095);
}

test "read/write unmapped" {
    var m = Memory.init(options);
    try expect(m.rd(0x0000) == 0xFF);
    try expect(m.rd(0xFFFF) == 0xFF);
    m.wr(0x4000, 0x23);
    try expect(m.rd(0x4000) == 0xFF);
    try expect(junk_page[0] == 0x23);
}

test "map ram page sized" {
    var m = Memory.init(options);
    m.mapRAM(0x0000, 0x1000, mem[0..0x1000]);
    m.mapRAM(0x2000, 0x1000, mem[0x1000..0x2000]);
    m.wr(0x0000, 0x11);
    m.wr(0x0FFF, 0x22);
    m.wr(0x1000, 0x33); // unmapped
    m.wr(0x1FFF, 0x44); // unmapped
    m.wr(0x2000, 0x55);
    m.wr(0x2FFF, 0x66);
    m.wr(0x3000, 0x77); // unmapped
    try expect(m.rd(0x0000) == 0x11);
    try expect(m.rd(0x0FFF) == 0x22);
    try expect(m.rd(0x1000) == 0xFF);
    try expect(m.rd(0x1FFF) == 0xFF);
    try expect(m.rd(0x2000) == 0x55);
    try expect(m.rd(0x2FFF) == 0x66);
    try expect(m.rd(0x3000) == 0xFF);
    try expect(mem[0x0000] == 0x11);
    try expect(mem[0x0FFF] == 0x22);
    try expect(mem[0x1000] == 0x55);
    try expect(mem[0x1FFF] == 0x66);
}
