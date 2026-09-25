const std = @import("std");
const ig = @import("cimgui");

pub const MAX_SLOTS = 32;
pub const MAX_STRING_LENGTH = 128;

pub const SettingsStr = struct {
    buf: [MAX_STRING_LENGTH]u8,

    pub fn init(str: []const u8) SettingsStr {
        var self = SettingsStr{
            .buf = undefined,
        };
        std.mem.copy(u8, &self.buf, str);
        return self;
    }

    pub fn asSlice(self: *const SettingsStr) []const u8 {
        return std.mem.span(&self.buf);
    }
};

pub const SettingsSlot = struct {
    window_title: SettingsStr,
    open: bool,
};

pub const Settings = struct {
    num_slots: usize,
    slots: [MAX_SLOTS]SettingsSlot,

    pub fn init() Settings {
        return .{
            .num_slots = 0,
            .slots = undefined,
        };
    }

    pub fn add(self: *Settings, window_title: []const u8, open: bool) bool {
        if (self.num_slots >= MAX_SLOTS) {
            return false;
        }
        if (window_title.len >= MAX_STRING_LENGTH) {
            return false;
        }

        self.slots[self.num_slots] = .{
            .window_title = SettingsStr.init(window_title),
            .open = open,
        };
        self.num_slots += 1;
        return true;
    }

    pub fn findSlotIndex(self: *const Settings, window_title: []const u8) ?usize {
        for (0..self.num_slots) |i| {
            const slot = &self.slots[i];
            if (std.mem.eql(u8, slot.window_title.asSlice(), window_title)) {
                return i;
            }
        }
        return null;
    }

    pub fn isOpen(self: *const Settings, window_title: []const u8) bool {
        if (self.findSlotIndex(window_title)) |index| {
            return self.slots[index].open;
        }
        return false;
    }
};
