const chips = @import("chips");
const z80pio = chips.z80pio;
const ui_chip = @import("ui_chip.zig");
const ig = @import("cimgui");
const ui_settings = @import("ui_settings.zig");
pub const TypeConfig = struct {
    bus: type,
    pio: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;
        const Z80PIO = cfg.pio;
        const UI_Chip = ui_chip.Type(.{ .bus = cfg.bus });

        pub const Options = struct {
            title: []const u8,
            pio: *Z80PIO,
            origin: ig.ImVec2,
            size: ig.ImVec2 = .{},
            open: bool = false,
            chip: UI_Chip,
        };

        title: []const u8,
        pio: *Z80PIO,
        origin: ig.ImVec2,
        size: ig.ImVec2,
        open: bool,
        last_open: bool,
        valid: bool,
        chip: UI_Chip,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .title = opts.title,
                .pio = opts.pio,
                .origin = opts.origin,
                .size = .{ .x = if (opts.size.x == 0) 360 else opts.size.x, .y = if (opts.size.y == 0) 364 else opts.size.y },
                .open = opts.open,
                .last_open = opts.open,
                .valid = true,
                .chip = opts.chip.init(),
            };
        }

        pub fn discard(self: *Self) void {
            self.valid = false;
        }

        fn modeString(mode: u8) []const u8 {
            switch (mode) {
                0 => return "OUT",
                1 => return "INP",
                2 => return "BDIR",
                3 => return "BITC",
                else => return "INVALID",
            }
        }

        fn drawPorts(self: *Self) void {
            const pio = self.pio;
            if (ig.igBeginTable("##pio_columns", 3, ig.ImGuiTableFlags_None)) {
                ig.igTableSetupColumnEx("", ig.ImGuiTableColumnFlags_WidthFixed, 64, 0);
                ig.igTableSetupColumnEx("PA", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("PB", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableHeadersRow();
                _ = ig.igTableNextColumn();
                ig.igText("Mode");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText(modeString(pio.ports[index].mode).ptr);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("Output");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText("%02X", pio.ports[index].output);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("Input");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText("%02X", pio.ports[index].input);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("IO Select");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText("%02X", pio.ports[index].io_select);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("INT Ctrl");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText("%02X", pio.ports[index].int_control);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  ei/di");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    const int_control = pio.ports[index].int_control;
                    if ((int_control & Z80PIO.INTCTRL.EI) != 0) {
                        ig.igText("EI");
                    } else {
                        ig.igText("DI");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  and/or");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    const int_control = pio.ports[index].int_control;
                    if ((int_control & Z80PIO.INTCTRL.ANDOR) != 0) {
                        ig.igText("AND");
                    } else {
                        ig.igText("OR");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  hi/lo");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    const int_control = pio.ports[index].int_control;
                    if ((int_control & Z80PIO.INTCTRL.HILO) != 0) {
                        ig.igText("HI");
                    } else {
                        ig.igText("LO");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("INT Vec");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText("%02X", pio.ports[index].irq.vector);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("INT Mask");
                _ = ig.igTableNextColumn();
                for (0..2) |index| {
                    ig.igText("%02X", pio.ports[index].int_mask);
                    _ = ig.igTableNextColumn();
                }
                ig.igEndTable();
            }
        }

        pub fn draw(self: *Self, in_bus: Bus) void {
            if (self.open != self.last_open) {
                self.last_open = self.open;
            }
            if (!self.open) return;
            ig.igSetNextWindowPos(self.origin, ig.ImGuiCond_FirstUseEver);
            ig.igSetNextWindowSize(self.size, ig.ImGuiCond_FirstUseEver);
            if (ig.igBegin(self.title.ptr, &self.open, ig.ImGuiWindowFlags_None)) {
                if (ig.igBeginChild("##pio_chip", .{ .x = 176, .y = 0 }, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.chip.draw(in_bus);
                }
                ig.igEndChild();
                ig.igSameLine();
                if (ig.igBeginChild("##pio_vals", .{}, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.drawPorts();
                }
                ig.igEndChild();
            }
            ig.igEnd();
        }

        pub fn saveSettings(self: *Self, settings: *ui_settings.Settings) void {
            _ = settings.add(self.title, self.open);
        }

        pub fn loadSettings(self: *Self, settings: *const ui_settings.Settings) void {
            self.open = settings.isOpen(self.title);
        }
    };
}
