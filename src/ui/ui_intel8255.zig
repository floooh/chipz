const chips = @import("chips");
const intel8255 = chips.intel8255;
const ui_chip = @import("ui_chip.zig");
const ig = @import("cimgui");

pub const TypeConfig = struct {
    bus: type,
    ppi: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;
        const INTEL8255 = cfg.ppi;
        const UI_Chip = ui_chip.Type(.{ .bus = cfg.bus });

        pub const Options = struct {
            title: []const u8,
            ppi: *INTEL8255,
            origin: ig.ImVec2,
            size: ig.ImVec2 = .{},
            open: bool = false,
            chip: UI_Chip,
        };

        title: []const u8,
        ppi: *INTEL8255,
        origin: ig.ImVec2,
        size: ig.ImVec2,
        open: bool,
        last_open: bool,
        valid: bool,
        chip: UI_Chip,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .title = opts.title,
                .ppi = opts.ppi,
                .origin = opts.origin,
                .size = .{ .x = if (opts.size.x == 0) 440 else opts.size.x, .y = if (opts.size.y == 0) 370 else opts.size.y },
                .open = opts.open,
                .last_open = opts.open,
                .valid = true,
                .chip = opts.chip.init(),
            };
        }

        pub fn discard(self: *Self) void {
            self.valid = false;
        }

        fn drawState(self: *Self) void {
            const ppi = self.ppi;
            if (ig.igBeginTable("##ppi_ports", 5, ig.ImGuiTableFlags_None)) {
                ig.igTableSetupColumnEx("", ig.ImGuiTableColumnFlags_WidthFixed, 56, 0);
                ig.igTableSetupColumnEx("A", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("B", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("CHI", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableSetupColumnEx("CLO", ig.ImGuiTableColumnFlags_WidthFixed, 32, 0);
                ig.igTableHeadersRow();
                _ = ig.igTableNextColumn();
                ig.igText("Mode");
                _ = ig.igTableNextColumn();
                ig.igText("%d", (ppi.control & INTEL8255.CTRL.A_CHI_MODE) >> 5);
                _ = ig.igTableNextColumn();
                ig.igText("%d", (ppi.control & INTEL8255.CTRL.B_CLO_MODE) >> 2);
                _ = ig.igTableNextColumn();
                ig.igText("%d", (ppi.control & INTEL8255.CTRL.A_CHI_MODE) >> 5);
                _ = ig.igTableNextColumn();
                ig.igText("%d", (ppi.control & INTEL8255.CTRL.B_CLO_MODE) >> 2);
                _ = ig.igTableNextColumn();
                ig.igText("In/Out");
                _ = ig.igTableNextColumn();
                if ((ppi.control & INTEL8255.CTRL.A) == INTEL8255.CTRL.A_INPUT) {
                    ig.igText("IN");
                } else {
                    ig.igText("OUT");
                }
                _ = ig.igTableNextColumn();
                if ((ppi.control & INTEL8255.CTRL.B) == INTEL8255.CTRL.B_INPUT) {
                    ig.igText("IN");
                } else {
                    ig.igText("OUT");
                }
                _ = ig.igTableNextColumn();
                if ((ppi.control & INTEL8255.CTRL.CHI) == INTEL8255.CTRL.CHI_INPUT) {
                    ig.igText("IN");
                } else {
                    ig.igText("OUT");
                }
                _ = ig.igTableNextColumn();
                if ((ppi.control & INTEL8255.CTRL.CLO) == INTEL8255.CTRL.CLO_INPUT) {
                    ig.igText("IN");
                } else {
                    ig.igText("OUT");
                }
                _ = ig.igTableNextColumn();
                ig.igText("Output");
                _ = ig.igTableNextColumn();
                ig.igText("%02X", ppi.ports[INTEL8255.PORT.A].output);
                _ = ig.igTableNextColumn();
                ig.igText("%02X", ppi.ports[INTEL8255.PORT.B].output);
                _ = ig.igTableNextColumn();
                ig.igText("%X", ppi.ports[INTEL8255.PORT.C].output >> 4);
                _ = ig.igTableNextColumn();
                ig.igText("%X", ppi.ports[INTEL8255.PORT.C].output & 0x0f);
                _ = ig.igTableNextColumn();
                ig.igEndTable();
            }
            ig.igSeparator();
            ig.igText("Control %02X", ppi.control);
        }

        pub fn draw(self: *Self, in_bus: Bus) void {
            if (self.open != self.last_open) {
                self.last_open = self.open;
            }
            if (!self.open) return;
            ig.igSetNextWindowPos(self.origin, ig.ImGuiCond_FirstUseEver);
            ig.igSetNextWindowSize(self.size, ig.ImGuiCond_FirstUseEver);
            if (ig.igBegin(self.title.ptr, &self.open, ig.ImGuiWindowFlags_None)) {
                if (ig.igBeginChild("##ppi_chip", .{ .x = 176, .y = 0 }, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.chip.draw(in_bus);
                }
                ig.igEndChild();
                ig.igSameLine();
                if (ig.igBeginChild("##ppi_vals", .{}, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None)) {
                    self.drawState();
                }
                ig.igEndChild();
            }
            ig.igEnd();
        }
    };
}
