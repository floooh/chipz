const std = @import("std");
const math = std.math;
const ig = @import("cimgui");
const ui_util = @import("ui_util.zig");

pub const TypeConfig = struct {
    bus: type,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;

        pub const Pin = struct {
            name: []const u8,
            slot: usize,
            mask: Bus,
        };

        name: []const u8,
        num_slots: usize = 0,
        num_slots_left: usize = 0,
        num_slots_right: usize = 0,
        num_slots_top: usize = 0,
        num_slots_bottom: usize = 0,
        chip_width: f32 = 0,
        chip_height: f32 = 0,
        pin_slot_dist: f32 = 0,
        pin_width: f32 = 0,
        pin_height: f32 = 0,
        are_pin_names_inside: bool = false,
        is_name_outside: bool = false,
        pins: []const Pin,

        pub fn init(chip: Self) Self {
            var self = chip;
            if (self.num_slots == 0) {
                self.num_slots = self.num_slots_left + self.num_slots_right + self.num_slots_top + self.num_slots_bottom;
            } else {
                self.num_slots_right = self.num_slots / 2;
                self.num_slots_left = self.num_slots - self.num_slots_right;
            }
            if (self.pin_slot_dist == 0) {
                self.pin_slot_dist = 16;
            }
            if (self.pin_width == 0) {
                self.pin_width = 12;
            }
            if (self.pin_height == 0) {
                self.pin_height = 12;
            }
            if (self.chip_width == 0) {
                const slots: f32 = @floatFromInt(@max(self.num_slots_top, self.num_slots_bottom));
                self.chip_width = if (slots > 0) slots * self.pin_slot_dist else 64;
            }
            if (self.chip_height == 0) {
                const slots: f32 = @floatFromInt(@max(self.num_slots_left, self.num_slots_right));
                self.chip_height = if (slots > 0) slots * self.pin_slot_dist else 64;
            }
            return self;
        }

        /// Get screen pos of center of pin (by pin index) with chip center at cx, cy
        fn pinPos(self: *Self, pin_index: usize, c: ig.ImVec2) ig.ImVec2 {
            var pos = ig.ImVec2{ .x = 0, .y = 0 };
            if (pin_index < self.num_slots) {
                const w = self.chip_width;
                const h = self.chip_height;
                const zero = ig.ImVec2{ .x = math.floor(c.x - w / 2), .y = math.floor(c.y - h / 2) };
                const slot_dist = self.pin_slot_dist;
                const pwh: f32 = self.pin_width / 2;
                const phh: f32 = self.pin_height / 2;
                const l = self.num_slots_left;
                const r = self.num_slots_right;
                const t = self.num_slots_top;
                const b = self.num_slots_bottom;
                const pin = self.pins[pin_index];
                const pin_slot_f: f32 = @floatFromInt(pin.slot);
                const l_f: f32 = @floatFromInt(l);
                const r_f: f32 = @floatFromInt(r);
                const t_f: f32 = @floatFromInt(t);

                if (pin.slot < l) {
                    // left side
                    pos.x = zero.x - pwh;
                    pos.y = zero.y + slot_dist / 2 + pin_slot_f * slot_dist;
                } else if (pin.slot < (l + r)) {
                    // right side
                    pos.x = zero.x + w + pwh;
                    pos.y = zero.y + slot_dist / 2 + (pin_slot_f - l_f) * slot_dist;
                } else if (pin.slot < (l + r + t)) {
                    // top side
                    pos.x = zero.x + slot_dist / 2 + (pin_slot_f - (l_f + r_f)) * slot_dist;
                    pos.y = zero.y - phh;
                } else if (pin.slot < (l + r + t + b)) {
                    pos.x = zero.x + slot_dist / 2 + (pin_slot_f - (l_f + r_f + t_f)) * slot_dist;
                    pos.y = zero.y + h + phh;
                }
            }
            return pos;
        }

        /// Find pin index by pin bit
        fn pinIndex(self: *Self, mask: Bus) ?usize {
            for (0..self.num_slots) |index| {
                if (self.pins[index].mask == mask) {
                    return index;
                }
            }
            return null;
        }

        /// Get screen pos of center of pin (by pin index) with chip center at cx, cy with pin bit mask
        fn pinMaskPos(self: *Self, pin_mask: Bus, c: ig.ImVec2) ?ig.ImVec2 {
            if (self.pinIndex(pin_mask)) |pin_index| {
                return self.pinPos(pin_index, c);
            } else {
                return null;
            }
        }

        /// Draw chip centered at screen pos
        pub fn drawAt(self: *Self, pins: Bus, c: ig.ImVec2) void {
            const dl = ig.igGetWindowDrawList();
            const w = self.pin_width;
            const h = self.chip_height;
            const p0 = ig.ImVec2{ .x = math.floor(c.x - w / 2), .y = math.floor(c.y - h / 2) };
            const p1 = ig.ImVec2{ .x = p0.x + w, .y = p0.y + h };
            const m = ig.ImVec2{ .x = math.floor((p0.x + p1.x) / 2), .y = math.floor((p0.y + p1.y) / 2) };
            const pw = self.pin_width;
            const ph = self.pin_height;
            const l = self.num_slots_left;
            const r = self.num_slots_right;
            const text_color = ui_util.color(ig.ImGuiCol_Text);
            const line_color = text_color;
            const style = ig.igGetStyle();
            const pin_color_on = ig.igGetColorU32ImVec4(.{ .x = 0, .y = 1, .z = 0, .w = style.*.Alpha });
            const pin_color_off = ig.igGetColorU32ImVec4(.{ .x = 0, .y = 0.25, .z = 0, .w = style.*.Alpha });

            ig.ImDrawList_AddRect(dl, p0, p1, line_color);
            const chip_ts = ig.igCalcTextSize(self.name.ptr);
            if (self.is_name_outside) {
                const tpos = ig.ImVec2{ .x = m.x - chip_ts.x / 2, .y = p0.y - chip_ts.y };
                ig.ImDrawList_AddText(dl, tpos, text_color, self.name.ptr);
            } else {
                const tpos = ig.ImVec2{ .x = m.x - chip_ts.x / 2, .y = m.y - chip_ts.y / 2 };
                ig.ImDrawList_AddText(dl, tpos, text_color, self.name.ptr);
            }
            var p = ig.ImVec2{};
            var t = ig.ImVec2{};
            for (0..self.num_slots) |index| {
                const pin = self.pins[index];
                if (pin.name.len == 0) break;
                const pin_pos = self.pinPos(index, c);
                p.x = pin_pos.x - pw / 2;
                p.y = pin_pos.y - ph / 2;
                const ts = ig.igCalcTextSize(pin.name.ptr);
                if (pin.slot < l) {
                    // left side
                    if (self.are_pin_names_inside) {
                        t.x = p.x + pw + 4;
                    } else {
                        t.x = p.x - ts.x - 4;
                    }
                    t.y = p.y + ph / 2 - ts.y / 2;
                } else if (pin.slot < (l + r)) {
                    // right side
                    if (self.are_pin_names_inside) {
                        t.x = p.x - ts.x - 4;
                    } else {
                        t.x = p.x + pw + 4;
                    }
                    t.y = p.y + ph / 2 - ts.y / 2;
                } else {
                    // FIXME: top/bottom text (must be rendered vertical)
                    t = p;
                }
                const pin_color = if ((pins & pin.mask) != 0) pin_color_on else pin_color_off;
                const pp = ig.ImVec2{ .x = p.x + pw, .y = p.y + ph };
                ig.ImDrawList_AddRectFilled(dl, p, pp, pin_color);
                ig.ImDrawList_AddRect(dl, p, pp, line_color);
                ig.ImDrawList_AddText(dl, t, text_color, pin.name.ptr);
            }
        }

        /// Draw chip centered at current ImGui cursor pos
        pub fn draw(self: *Self, pins: Bus) void {
            const canvas_pos = ig.igGetCursorScreenPos();
            const canvas_area = ig.igGetContentRegionAvail();
            const c = ig.ImVec2{ .x = canvas_pos.x + canvas_area.x / 2, .y = canvas_pos.y + canvas_area.y / 2 };
            self.drawAt(pins, c);
        }
    };
}
