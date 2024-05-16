//! the internal Z80 CPU state

// note: register indices are 'little endian' for efficient 8- vs 16-bit access
pub const F = 0;
pub const A = 1;
pub const C = 2;
pub const B = 3;
pub const E = 4;
pub const D = 5;
pub const L = 6;
pub const H = 7;
pub const IXL = 8;
pub const IXH = 9;
pub const IYL = 10;
pub const IYH = 11;
pub const WZL = 12;
pub const WZH = 13;
pub const SPL = 14;
pub const SPH = 15;
pub const NumRegs = 16;

// program counter
pc: u16,

// 8/16-bit register bank
r: [NumRegs]u8,

// merged i and r register
ir: u16,

// shadow register bank
af2: u16,
bc2: u16,
de2: u16,
hl2: u16,

// interrupt mode
im: u8,

// interrupt enable flags
iff1: bool,
iff2: bool,
