```zig
const px: usize = 272 - self.sprite_coords[sprite_index * 2 + 1];
```

=> error: type 'u8' cannot represent integer value '272'
    - why are right hand side values not extended to the result type?

```zig
const shr_hi: u3 = @truncate(7 - xx);
const shr_lo: u3 = @truncate(3 - xx);
const p2_hi: u8 = (self.rom.gfx[tile_base + tile_index] >> shr_hi) & 1;
const p2_lo: u8 = (self.rom.gfx[tile_base + tile_index] >> shr_lo) & 1;
```

=> why is the truncate necessary when xx is a loop variable from 0..4 (and thus
   is guaranteed to fit into an u3)
