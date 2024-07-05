```zig
const px: usize = 272 - self.sprite_coords[sprite_index * 2 + 1];
```

^^^ error: type 'u8' cannot represent integer value '272'
    - why are right hand side values not extended to the result type?

```zig
const shr_hi: u3 = @truncate(7 - xx);
const shr_lo: u3 = @truncate(3 - xx);
const p2_hi: u8 = (self.rom.gfx[tile_base + tile_index] >> shr_hi) & 1;
const p2_lo: u8 = (self.rom.gfx[tile_base + tile_index] >> shr_lo) & 1;
```

^^^ why is the truncate necessary when xx is a loop variable from 0..4 (and thus
   is guaranteed to fit into an u3)

```zig
// interrupt mode (0, 1 or 2)
im: u8 = 0,

// interrupt tracking flags
iff1: u8 = 0,
iff2: u8 = 0,
last_nmi: u8 = 0,
nmi: u8 = 0,
int: u8 = 0,
```

^^^ those were originally 'odd-width' integers u2 and u1 and that had quite
a negative perf impact (z80zex 172s vs 159s)

```zig
const blub: u32 = 0xFFFFFFFF;
const bla: u3 = blub & 7;
```

^^^ this should work without requiring to truncate blub

```zig
const smp_index: u32 = ((voice.waveform << 5) | ((voice.counter >> 15) & 0x1F)) & 0xFF;
```

^^^ error: type 'u2' cannot represent integer value '5'

```zig
const mask: u20 = ~(0x0000F << shl);
```

^^^ unable to perform binary not operation on type 'comptime_int'