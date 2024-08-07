# chipz

[![build](https://github.com/floooh/chipz/actions/workflows/main.yml/badge.svg)](https://github.com/floooh/chipz/actions/workflows/main.yml)

[EXPERIMENTAL] like chips but in zig

## Usage

### Arcace Machines:

```
zig build --release=fast run-pacman
zig build --release=fast run-pengo
zig build --release=fast run-bombjack
```

Key input:

- **1**: insert coin
- **Enter**: start game
- **Arrow keys**: move up/down/left/right
- **Space**: jump/shove/fire button

### KC85/2..4:

```
zig build --release=fast run-kc852
zig build --release=fast run-kc853
zig build --release=fast run-kc854
```

Run KC85/3 with 16 KByte RAM module (this will be automatically mapped to address
0x4000 by the CAOS operating system):

```
zig build --release=fast run-kc853 -- -slot8 m022
```

Start with Forth ROM module in expansion slot `08`:

```
zig build --release=fast run-kc852 -- -slot8 m026 media/kc85/forth.853
zig build --release=fast run-kc853 -- -slot8 m026 media/kc85/forth.853
zig build --release=fast run-kc854 -- -slot8 m026 media/kc85/forth.853
```

To activate and start the Forth module on KC85/2 and KC85/4:

```
% SWITCH 8 C1
% MENU
% FORTH
```

...on KC85/3 you also need to deactivate the BASIC ROM:

```
% SWITCH 8 C1
% SWITCH 2 0
% MENU
% FORTH
```
