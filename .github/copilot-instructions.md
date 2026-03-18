## Quick orientation for AI coding agents

This repository implements several 8-bit emulator experiments written in Zig. The codebase is organized into emulated "systems" (platforms/arcade machines), reusable "chips" (CPU, sound, IO), a small host layer, and UI helpers.

Key directories and files to inspect first:
- `src/chipz.zig` — top-level module imports and entry points for the emulator.
- `src/systems/` — each system (eg. `namco.zig`, `bombjack.zig`, `kc85.zig`) defines machine composition and wiring of chips and memory.
- `src/chips/` — chip implementations, notably `z80.zig` (cycle-stepped Z80), `ay3891.zig` (audio), Intel 8255, CTC, PIO, etc.
- `src/common/` — shared utilities: `memory.zig` (paged memory model), `audio.zig`, `clock.zig`, and small helpers used broadly.
- `src/host/` — host abstraction (gfx, audio, timing, profiling) that separates platform I/O from machine logic.
- `src/ui/` — realtime debugging and UI panels (Z80 state, memory map, chip helpers).
- `emus/` and `media/` — ROMs and media assets used by systems.
- `tests/` — unit tests for many chips (use these as canonical examples of expected behavior).

Important architecture & conventions
- Systems are composed by wiring together chips and mapping memory explicitly. See `src/systems/*.zig` for examples of how ROMs, RAM and IO are mapped.
- The Z80 implementation is a cycle-stepped emulator that exposes a Type(comptime cfg) API (see `src/chips/z80.zig`). Many chips in this codebase use Zig `comptime`-driven types; prefer adding specialized types via the existing Type(...) patterns rather than duplicating logic.
- Memory uses a paged model (`src/common/memory.zig`) with separate read/write pointers per page. Mapping functions include `mapRAM`, `mapROM`, `mapRW`, and `unmap`. All slices passed to Memory must outlive the Memory object — keep host lifetime in mind when writing tests or wiring memory.
- Host vs machine separation: device logic (chips, memory, systems) is pure emulation code; `src/host` contains platform glue for graphics/audio/timing. Avoid placing platform-specific code into `src/chips` or `src/systems`.

Build / run / test workflows (concrete):
- Run arcade or system targets (examples from `README.md`):
  - `zig build --release=fast run-pacman`
  - `zig build --release=fast run-pengo`
  - `zig build --release=fast run-kc853 -- -slot8 m022` (KC85 example with a slot)
- Unit tests are provided under `tests/`. Run a test file directly with Zig or use the repository build targets:
  - `zig test tests/memory.test.zig`
  - or `zig build <test-target>` when available in `build.zig` (inspect `build.zig` for provided tasks).
- Build artifacts are placed in `zig-out/bin/` (executables like `pacman`, `z80test`, etc.).

Project-specific patterns to follow
- Prefer small, well-scoped files: chips implement a single device; systems assemble devices.
- Use the provided Memory Type for mapping. Example mapping pattern from systems:
  - `mem.mapROM(0x0000, rom.len, rom_slice)`
  - `mem.mapRAM(0x4000, ram_size, ram_slice)`
- Chips expose low-level, cycle-accurate interfaces: for the Z80, code inspects and manipulates pin masks and steps the CPU by cycles — avoid attempts at high-level shortcuts that skip pins or the step model.
- Use comptime Type stamps already present (e.g., `Z80.Type(TypeConfig{...})`) when creating specialized chip instances.

Integration & extension notes
- Adding a new system: implement `src/systems/<your>.zig`, wire chips and memory using existing APIs, add a `run-<your>` target to `build.zig` mirroring existing runs.
- Adding a new chip: follow shape in `src/chips/*` — provide a Type(comptime cfg) when relevant, keep device logic free of host I/O, and add focused unit tests under `tests/`.
- ROM and media files live under `emus/` and `media/` — systems load these directly; keep naming and offsets consistent with existing systems.

Examples to reference while coding
- See `src/systems/namco.zig` and `emus/namco/roms/pacman` for an arcade wiring example.
- See `src/chips/z80.zig` for cycle-stepped CPU semantics and `src/common/memory.zig` for mapping behavior.
- See tests like `tests/memory.test.zig` and `tests/intel8255.test.zig` for small, focused test patterns.

When you need clarification from a human
- If a requested change touches host APIs (`src/host/*`) or build targets (`build.zig`), ask for which platforms to target (macOS / Linux) and whether CI needs updating.
- If you must change memory ownership/lifetimes, request guidance — many memory APIs rely on host-owned slices that must outlive the Memory object.

If this snapshot is missing something you expect, tell me what to add (target, device, or workflow) and I'll update this file.
