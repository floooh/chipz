const std = @import("std");
const ig = @import("cimgui");
const ui_util = @import("ui_util.zig");
const ui_settings = @import("ui_settings.zig");

pub const MAX_LAYERS = 16;
pub const MAX_REGIONS = 16;

pub const Region = struct {
    name: []const u8,
    addr: u16,
    len: u16,
    on: bool,
};

pub const Layer = struct {
    name: []const u8,
    num_regions: usize,
    regions: [MAX_REGIONS]Region,
};

pub const MemMap = struct {
    const Self = @This();

    pub const Options = struct {
        title: []const u8,
        origin: ig.ImVec2,
        size: ig.ImVec2 = .{},
        open: bool = false,
    };

    title: []const u8,
    origin: ig.ImVec2,
    size: ig.ImVec2,
    layer_height: f32,
    left_padding: f32,
    open: bool,
    last_open: bool,
    valid: bool,
    num_layers: usize,
    layers: [MAX_LAYERS]Layer,

    pub fn initInPlace(self: *Self, opts: Options) void {
        self.* = .{
            .title = opts.title,
            .origin = opts.origin,
            .size = .{
                .x = if (opts.size.x == 0) 400 else opts.size.x,
                .y = if (opts.size.y == 0) 40 else opts.size.y,
            },
            .open = opts.open,
            .last_open = opts.open,
            .left_padding = 80.0,
            .layer_height = 20.0,
            .valid = true,
            .num_layers = 0,
            .layers = undefined,
        };
    }

    pub fn discard(self: *Self) void {
        self.valid = false;
    }

    fn drawGrid(self: *Self, canvas_pos: ig.ImVec2, canvas_area: ig.ImVec2) void {
        const dl = ig.igGetWindowDrawList();
        const grid_color = ui_util.color(ig.ImGuiCol_Text);
        const y = canvas_pos.y + canvas_area.y - self.layer_height;

        // Line rulers
        if (canvas_area.x > self.left_padding) {
            const addr = [_][]const u8{ "0000", "4000", "8000", "C000", "FFFF" };
            const glyph_width = ig.igCalcTextSize("X").x;
            const x0 = canvas_pos.x + self.left_padding;
            const dx = (canvas_area.x - self.left_padding) / 4.0;
            const y0 = canvas_pos.y;
            const y1 = canvas_pos.y + canvas_area.y + 4.0 - self.layer_height;

            var x = x0;
            for (addr, 0..) |addr_str, index| {
                const pos = ig.ImVec2{ .x = x, .y = y0 };
                const pos2 = ig.ImVec2{ .x = x, .y = y1 };
                ig.ImDrawList_AddLine(dl, pos, pos2, grid_color);

                const addr_x = if (index == 4) x - 4.0 * glyph_width else x;
                const text_pos = ig.ImVec2{ .x = addr_x, .y = y1 };
                ig.ImDrawList_AddText(dl, text_pos, grid_color, addr_str.ptr);
                x += dx;
            }

            const p0 = ig.ImVec2{ .x = canvas_pos.x + self.left_padding, .y = y1 };
            const p1 = ig.ImVec2{ .x = x0 + 4 * dx, .y = p0.y };
            ig.ImDrawList_AddLine(dl, p0, p1, grid_color);
        }

        // Layer names to the left
        var text_pos = ig.ImVec2{ .x = canvas_pos.x, .y = y - self.layer_height + 6 };
        var i: usize = 0;
        while (i < self.num_layers) : (i += 1) {
            ig.ImDrawList_AddText(dl, text_pos, grid_color, self.layers[i].name.ptr);
            text_pos.y -= self.layer_height;
        }
    }

    fn drawRegion(self: *Self, pos: ig.ImVec2, width: f32, reg: Region) void {
        const dl = ig.igGetWindowDrawList();
        const style = ig.igGetStyle();
        const alpha = style.*.Alpha;
        const on_color = ig.igGetColorU32ImVec4(.{ .x = 0.0, .y = 0.75, .z = 0.0, .w = alpha });
        const off_color = ig.igGetColorU32ImVec4(.{ .x = 0.0, .y = 0.25, .z = 0.0, .w = alpha });
        const color = if (reg.on) on_color else off_color;

        const addr = reg.addr;
        const end_addr = reg.addr + reg.len;
        if (end_addr > 0x10000) {
            // Wraparound
            const a = pos;
            const b = ig.ImVec2{
                .x = pos.x + (((end_addr & 0xFFFF) * width) / 0x10000) - 2,
                .y = pos.y + self.layer_height - 2,
            };
            ig.ImDrawList_AddRectFilled(dl, a, b, color);
            if (ig.igIsMouseHoveringRect(a, b)) {
                var tooltip: [100]u8 = undefined;
                if (std.fmt.bufPrint(&tooltip, "{s} (0000..{X:0>4})", .{ reg.name, (end_addr & 0xFFFF) - 1 })) |tooltip_slice| {
                    ig.igSetTooltip(tooltip_slice.ptr);
                } else |_| {}
            }
            end_addr = 0x10000;
        }
        const a = ig.ImVec2{
            .x = pos.x + ((@as(f32, @floatFromInt(addr)) * width) / 0x10000),
            .y = pos.y,
        };
        const b = ig.ImVec2{
            .x = pos.x + ((@as(f32, @floatFromInt(end_addr)) * width) / 0x10000) - 2,
            .y = pos.y + self.layer_height - 2,
        };
        ig.ImDrawList_AddRectFilled(dl, a, b, color);
        if (ig.igIsMouseHoveringRect(a, b)) {
            var tooltip: [100]u8 = undefined;
            if (std.fmt.bufPrint(&tooltip, "{s} ({X:0>4}..{X:0>4})", .{ reg.name, addr, end_addr - 1 })) |tooltip_slice| {
                ig.igSetTooltip(tooltip_slice.ptr);
            } else |_| {}
        }
    }

    fn drawRegions(self: *Self, canvas_pos: ig.ImVec2, canvas_area: ig.ImVec2) void {
        var pos = ig.ImVec2{
            .x = canvas_pos.x + self.left_padding,
            .y = canvas_pos.y + canvas_area.y + 4 - 2 * self.layer_height,
        };

        for (0..self.num_layers) |li| {
            for (0..self.layers[li].num_regions) |ri| {
                const reg = self.layers[li].regions[ri];
                if (reg.name.len > 0) {
                    self.drawRegion(pos, canvas_area.x - self.left_padding, reg);
                }
            }
            pos.y -= self.layer_height;
        }
    }

    pub fn draw(self: *Self) void {
        if (self.open != self.last_open) {
            self.last_open = self.open;
        }
        if (!self.open) return;

        const min_height = 40.0 + ((@as(f32, @floatFromInt(self.num_layers)) + 1.0) * self.layer_height);
        ig.igSetNextWindowPos(self.origin, ig.ImGuiCond_FirstUseEver);
        ig.igSetNextWindowSize(self.size, ig.ImGuiCond_FirstUseEver);
        ig.igSetNextWindowSizeConstraints(
            ig.ImVec2{ .x = 120.0, .y = min_height },
            ig.ImVec2{ .x = std.math.inf(f32), .y = std.math.inf(f32) },
            null,
            null,
        );

        if (ig.igBegin(self.title.ptr, &self.open, ig.ImGuiWindowFlags_None)) {
            const canvas_pos = ig.igGetCursorScreenPos();
            const canvas_area = ig.igGetContentRegionAvail();
            self.drawRegions(canvas_pos, canvas_area);
            self.drawGrid(canvas_pos, canvas_area);
        }
        ig.igEnd();
    }

    pub fn reset(self: *Self) void {
        self.num_layers = 0;
        @memset(&self.layers, undefined);
    }

    pub fn addLayer(self: *Self, name: []const u8) void {
        if (self.num_layers >= MAX_LAYERS) return;
        self.layers[self.num_layers] = .{
            .name = name,
            .num_regions = 0,
            .regions = undefined,
        };
        self.num_layers += 1;
    }

    pub fn addRegion(self: *Self, name: []const u8, addr: u16, len: u16, on: bool) void {
        if (self.num_layers == 0) return;
        if (len > 0x10000) return;

        const layer = &self.layers[self.num_layers - 1];
        if (layer.num_regions >= MAX_REGIONS) return;

        layer.regions[layer.num_regions] = .{
            .name = name,
            .addr = addr,
            .len = len,
            .on = on,
        };
        layer.num_regions += 1;
    }

    pub fn saveSettings(self: *Self, settings: *ui_settings.Settings) void {
        _ = settings.add(self.title, self.open);
    }

    pub fn loadSettings(self: *Self, settings: *const ui_settings.Settings) void {
        self.open = settings.isOpen(self.title);
    }
};
