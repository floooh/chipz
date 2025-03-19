const chips = @import("chips");
const z80 = chips.z80;
const ui_chip = @import("ui_chip.zig");
const ig = @import("cimgui");

pub const TypeConfig = struct {
    bus: type,
    cpu: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;
        const Z80 = cfg.cpu;
        const UI_Chip = ui_chip.Type(.{ .bus = cfg.bus });

        pub const Options = struct {
            title: []const u8,
            cpu: *Z80,
            origin: ig.ImVec2,
            size: ig.ImVec2 = .{},
            open: bool = false,
            chip: UI_Chip,
        };

        title: []const u8,
        cpu: *Z80,
        origin: ig.ImVec2,
        size: ig.ImVec2,
        open: bool,
        last_open: bool,
        valid: bool,
        chip: UI_Chip,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .title = opts.title,
                .cpu = opts.cpu,
                .origin = opts.origin,
                .size = .{ .x = if (opts.size.x == 0) 360 else opts.size.x, .y = if (opts.size.y == 0) 340 else opts.size.y },
                .open = opts.open,
                .last_open = opts.open,
                .valid = true,
                .chip = opts.chip.init(),
            };
        }

        pub fn discard(self: *Self) void {
            self.valid = false;
        }

        fn drawRegisters(self: *Self, in_bus: Bus) void {
            const cpu = self.cpu;
            ig.igText("AF: %04X  AF': %04X", cpu.AF(), cpu.af2);
            ig.igText("BC: %04X  BC': %04X", cpu.BC(), cpu.bc2);
            ig.igText("DE: %04X  DE': %04X", cpu.DE(), cpu.de2);
            ig.igText("HL: %04X  HL': %04X", cpu.HL(), cpu.hl2);
            ig.igSeparator();
            ig.igText("IX: %04X  IY: %04X", cpu.IX(), cpu.IY());
            ig.igText("PC: %04X  SP: %04X", cpu.pc, cpu.SP());
            ig.igText("IR: %04X  WZ: %04X", cpu.ir, cpu.WZ());
            ig.igText("IM: %02X", cpu.im);
            ig.igSeparator();
            const f = cpu.r[Z80.F];
            const flags = [_]u8{
                if ((f & Z80.SF) != 0) 'S' else '-',
                if ((f & Z80.ZF) != 0) 'Z' else '-',
                if ((f & Z80.YF) != 0) 'Y' else '-',
                if ((f & Z80.HF) != 0) 'H' else '-',
                if ((f & Z80.XF) != 0) 'X' else '-',
                if ((f & Z80.VF) != 0) 'V' else '-',
                if ((f & Z80.NF) != 0) 'N' else '-',
                if ((f & Z80.CF) != 0) 'C' else '-',
            };
            ig.igText("Flags: %s", &flags);
            if (cpu.iff1 != 0) {
                ig.igText("IFF1:  ON");
            } else {
                ig.igText("IFF1:  OFF");
            }
            if (cpu.iff2 != 0) {
                ig.igText("IFF2:  ON");
            } else {
                ig.igText("IFF2:  OFF");
            }
            ig.igSeparator();
            ig.igText("Addr:  %04X", Z80.getAddr(in_bus));
            ig.igText("Data:  %02X", Z80.getData(in_bus));
        }

        pub fn draw(self: *Self, in_bus: Bus) void {
            if (self.open != self.last_open) {
                self.last_open = self.open;
            }
            if (!self.open) return;
            ig.igSetNextWindowPos(self.origin, ig.ImGuiCond_FirstUseEver);
            ig.igSetNextWindowSize(self.size, ig.ImGuiCond_FirstUseEver);
            if (ig.igBegin(self.title.ptr, &self.open, ig.ImGuiWindowFlags_None)) {
                if (ig.igBeginChild("##z80_chip", .{ .x = 176, .y = 0 }, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.chip.draw(in_bus);
                }
                ig.igEndChild();
                ig.igSameLine();
                if (ig.igBeginChild("##z80_regs", .{}, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.drawRegisters(in_bus);
                }
                ig.igEndChild();
            }
            ig.igEnd();
        }
    };
}
