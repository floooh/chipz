const chips = @import("chips");
const z80ctc = chips.z80ctc;
const ui_chip = @import("ui_chip.zig");
const ig = @import("cimgui");

pub const TypeConfig = struct {
    bus: type,
    ctc: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;
        const Z80CTC = cfg.ctc;
        const UI_Chip = ui_chip.Type(.{ .bus = cfg.bus });

        pub const Options = struct {
            title: []const u8,
            ctc: *Z80CTC,
            origin: ig.ImVec2,
            size: ig.ImVec2 = .{},
            open: bool = false,
            chip: UI_Chip,
        };

        title: []const u8,
        ctc: *Z80CTC,
        origin: ig.ImVec2,
        size: ig.ImVec2,
        open: bool,
        last_open: bool,
        valid: bool,
        chip: UI_Chip,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .title = opts.title,
                .ctc = opts.ctc,
                .origin = opts.origin,
                .size = .{ .x = if (opts.size.x == 0) 460 else opts.size.x, .y = if (opts.size.y == 0) 300 else opts.size.y },
                .open = opts.open,
                .last_open = opts.open,
                .valid = true,
                .chip = opts.chip.init(),
            };
        }

        pub fn discard(self: *Self) void {
            self.valid = false;
        }

        fn drawChannels(self: *Self) void {
            const ctc = self.ctc;
            if (ig.igBeginTable("##ctc_columns", 5, ig.ImGuiTableFlags_None)) {
                ig.igTableSetupColumnEx("", ig.ImGuiTableColumnFlags_WidthFixed, 72, 0);
                ig.igTableSetupColumnEx("Chn1", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("Chn2", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("Chn3", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("Chn4", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableHeadersRow();
                _ = ig.igTableNextColumn();
                ig.igText("Constant");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    ig.igText("%02X", ctc.chn[index].constant);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("Counter");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    ig.igText("%02X", ctc.chn[index].down_counter);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("INT Vec");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    ig.igText("%02X", ctc.chn[index].irq.vector);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("Control");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    ig.igText("%02X", ctc.chn[index].control);
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  INT");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.EI) != 0) {
                        ig.igText("EI");
                    } else {
                        ig.igText("DI");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  MODE");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.MODE) != 0) {
                        ig.igText("CTR");
                    } else {
                        ig.igText("TMR");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  PRESCALE");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.PRESCALER) != 0) {
                        ig.igText("256");
                    } else {
                        ig.igText("16");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  EDGE");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.EDGE) != 0) {
                        ig.igText("RISE");
                    } else {
                        ig.igText("FALL");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  TRIGGER");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.TRIGGER) != 0) {
                        ig.igText("WAIT");
                    } else {
                        ig.igText("AUTO");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  CONSTANT");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.CONST_FOLLOWS) != 0) {
                        ig.igText("FLWS");
                    } else {
                        ig.igText("NONE");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  RESET");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.RESET) != 0) {
                        ig.igText("ON");
                    } else {
                        ig.igText("OFF");
                    }
                    _ = ig.igTableNextColumn();
                }
                ig.igText("  CONTROL");
                _ = ig.igTableNextColumn();
                for (0..4) |index| {
                    const control = ctc.chn[index].control;
                    if ((control & Z80CTC.CTRL.CONTROL) != 0) {
                        ig.igText("WRD");
                    } else {
                        ig.igText("VEC");
                    }
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
                if (ig.igBeginChild("##ctc_chip", .{ .x = 176, .y = 0 }, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.chip.draw(in_bus);
                }
                ig.igEndChild();
                ig.igSameLine();
                if (ig.igBeginChild("##ctc_vals", .{}, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.drawChannels();
                }
                ig.igEndChild();
            }
            ig.igEnd();
        }
    };
}
