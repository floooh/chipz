//! Z80 disassembler UI window.
const std = @import("std");
const z80dasm = @import("chips").z80dasm;
const ig = @import("cimgui");
const ui_settings = @import("ui_settings.zig");

pub const NUM_LINES = 512;
pub const STACK_MAX = 128;

pub const Dasm = struct {
    const Self = @This();

    pub const Options = struct {
        title: []const u8,
        read_cb: *const fn (addr: u16, userdata: ?*anyopaque) u8,
        userdata: ?*anyopaque,
        origin: ig.ImVec2,
        size: ig.ImVec2 = .{},
        open: bool = false,
    };

    title: []const u8,
    read_cb: *const fn (addr: u16, userdata: ?*anyopaque) u8,
    userdata: ?*anyopaque,
    origin: ig.ImVec2,
    size: ig.ImVec2,
    open: bool,
    last_open: bool,
    valid: bool,
    start_addr: u16,
    highlight_addr: u16,
    highlight_valid: bool,
    stack: [STACK_MAX]u16,
    stack_num: u8,
    stack_pos: u8,

    pub fn initInPlace(self: *Self, opts: Options) void {
        self.* = .{
            .title = opts.title,
            .read_cb = opts.read_cb,
            .userdata = opts.userdata,
            .origin = opts.origin,
            .size = .{
                .x = if (opts.size.x == 0) 400 else opts.size.x,
                .y = if (opts.size.y == 0) 256 else opts.size.y,
            },
            .open = opts.open,
            .last_open = opts.open,
            .valid = true,
            .start_addr = 0,
            .highlight_addr = 0,
            .highlight_valid = false,
            .stack = [_]u16{0} ** STACK_MAX,
            .stack_num = 0,
            .stack_pos = 0,
        };
    }

    pub fn discard(self: *Self) void {
        self.valid = false;
    }

    fn goto(self: *Self, addr: u16) void {
        self.start_addr = addr;
    }

    fn stackPush(self: *Self, addr: u16) void {
        if (self.stack_num < STACK_MAX) {
            if (self.stack_num > 0 and addr == self.stack[self.stack_num - 1]) return;
            self.stack_pos = self.stack_num;
            self.stack[self.stack_num] = addr;
            self.stack_num += 1;
        }
    }

    fn stackBack(self: *Self) ?u16 {
        if (self.stack_num == 0) return null;
        const addr = self.stack[self.stack_pos];
        if (self.stack_pos > 0) self.stack_pos -= 1;
        return addr;
    }

    fn jumpTarget(next_addr: u16, bytes: []const u8) ?u16 {
        if (bytes.len == 3) {
            switch (bytes[0]) {
                0xCD, 0xDC, 0xFC, 0xD4, 0xC4, 0xF4, 0xEC, 0xE4, 0xCC,
                0xC3, 0xDA, 0xFA, 0xD2, 0xC2, 0xF2, 0xEA, 0xE2, 0xCA,
                => return (@as(u16, bytes[2]) << 8) | bytes[1],
                else => {},
            }
        }
        if (bytes.len == 2) {
            switch (bytes[0]) {
                0x10, 0x18, 0x38, 0x30, 0x20, 0x28 => {
                    const off: i16 = @as(i8, @bitCast(bytes[1]));
                    return next_addr +% @as(u16, @bitCast(off));
                },
                else => {},
            }
        }
        if (bytes.len == 1) {
            return switch (bytes[0]) {
                0xC7 => 0x00,
                0xCF => 0x08,
                0xD7 => 0x10,
                0xDF => 0x18,
                0xE7 => 0x20,
                0xEF => 0x28,
                0xF7 => 0x30,
                0xFF => 0x38,
                else => null,
            };
        }
        return null;
    }

    fn drawStack(self: *Self) void {
        _ = ig.igBeginChild("##dasm_stack", .{ .x = 72, .y = 0 }, ig.ImGuiChildFlags_Borders, ig.ImGuiWindowFlags_None);
        if (ig.igButton("Clear")) {
            self.stack_num = 0;
        }
        if (ig.igBeginListBox("##stack", .{ .x = -1, .y = -1 })) {
            var i: usize = 0;
            while (i < self.stack_num) : (i += 1) {
                var buf: [6]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{X:0>4}", .{self.stack[i]}) catch unreachable;
                buf[s.len] = 0;
                ig.igPushIDInt(@intCast(i));
                if (ig.igSelectableEx(&buf, i == self.stack_pos, ig.ImGuiSelectableFlags_None, .{})) {
                    self.stack_pos = @intCast(i);
                    self.goto(self.stack[i]);
                }
                if (ig.igIsItemHovered(ig.ImGuiHoveredFlags_None)) {
                    var tip: [16]u8 = undefined;
                    const ts = std.fmt.bufPrint(&tip, "Goto {X:0>4}\x00", .{self.stack[i]}) catch unreachable;
                    _ = ts;
                    ig.igSetTooltip(&tip);
                    self.highlight_addr = self.stack[i];
                    self.highlight_valid = true;
                }
                ig.igPopID();
            }
            ig.igEndListBox();
        }
        ig.igEndChild();
    }

    fn drawDisasm(self: *Self) void {
        _ = ig.igBeginChild("##dasm_box", .{ .x = 0, .y = 0 }, ig.ImGuiChildFlags_Borders, ig.ImGuiWindowFlags_None);

        // Address input
        var addr_val: u16 = self.start_addr;
        ig.igSetNextItemWidth(60);
        if (ig.igInputScalarEx("##addr", ig.ImGuiDataType_U16, &addr_val, null, null, "%04X", ig.ImGuiInputTextFlags_CharsHexadecimal)) {
            self.start_addr = addr_val;
        }
        ig.igSameLine();
        if (ig.igArrowButton("##back", ig.ImGuiDir_Left)) {
            if (self.stackBack()) |a| self.goto(a);
        }
        if (ig.igIsItemHovered(ig.ImGuiHoveredFlags_None) and self.stack_num > 0) {
            var tip: [16]u8 = undefined;
            const ts = std.fmt.bufPrint(&tip, "Goto {X:0>4}\x00", .{self.stack[self.stack_pos]}) catch unreachable;
            _ = ts;
            ig.igSetTooltip(&tip);
        }

        _ = ig.igBeginChild("##dasm_inner", .{ .x = 0, .y = 0 }, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None);
        ig.igPushStyleVarImVec2(ig.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
        ig.igPushStyleVarImVec2(ig.ImGuiStyleVar_ItemSpacing, .{ .x = 0, .y = 0 });

        const line_height = ig.igGetTextLineHeight();
        const glyph_width = ig.igCalcTextSize("F").x;
        const cell_width = 3 * glyph_width;

        var clipper: ig.ImGuiListClipper = .{};
        ig.ImGuiListClipper_Begin(&clipper, NUM_LINES, line_height);
        _ = ig.ImGuiListClipper_Step(&clipper);

        // Advance to DisplayStart
        var cur_addr: u16 = self.start_addr;
        var line_i: i32 = 0;
        while (line_i < clipper.DisplayStart) : (line_i += 1) {
            const res = z80dasm.op(cur_addr, self.read_cb, self.userdata);
            cur_addr = res.next_pc;
        }

        // Draw visible lines
        while (line_i < clipper.DisplayEnd) : (line_i += 1) {
            const op_addr = cur_addr;
            const res = z80dasm.op(cur_addr, self.read_cb, self.userdata);
            cur_addr = res.next_pc;

            var highlight = false;
            if (self.highlight_valid and self.highlight_addr == op_addr) {
                ig.igPushStyleColor(ig.ImGuiCol_Text, 0xFF30FF30);
                highlight = true;
            }

            // Address
            var addr_buf: [8]u8 = undefined;
            const addr_s = std.fmt.bufPrint(&addr_buf, "{X:0>4}: \x00", .{op_addr}) catch unreachable;
            _ = addr_s;
            ig.igTextUnformatted(&addr_buf);
            ig.igSameLine();

            // Instruction bytes
            const line_start_x = ig.igGetCursorPosX();
            for (0..res.num_bytes) |bi| {
                ig.igSameLineEx(line_start_x + cell_width * @as(f32, @floatFromInt(bi)), 0);
                var byte_buf: [4]u8 = undefined;
                const b = self.read_cb(op_addr +% @as(u16, @intCast(bi)), self.userdata);
                const bs = std.fmt.bufPrint(&byte_buf, "{X:0>2} \x00", .{b}) catch unreachable;
                _ = bs;
                ig.igTextUnformatted(&byte_buf);
            }

            // Mnemonic
            ig.igSameLineEx(line_start_x + cell_width * 4 + glyph_width * 2, 0);
            var mn_buf: [z80dasm.MAX_MNEMONIC_LEN + 1]u8 = undefined;
            @memcpy(mn_buf[0..res.mnemonic_len], res.mnemonic[0..res.mnemonic_len]);
            mn_buf[res.mnemonic_len] = 0;
            ig.igTextUnformatted(&mn_buf);

            if (highlight) ig.igPopStyleColor();

            // Collect bytes for jump-target detection
            var bytes_buf: [z80dasm.MAX_BYTES]u8 = undefined;
            for (0..res.num_bytes) |bi| {
                bytes_buf[bi] = self.read_cb(op_addr +% @as(u16, @intCast(bi)), self.userdata);
            }
            if (jumpTarget(cur_addr, bytes_buf[0..res.num_bytes])) |jt| {
                ig.igSameLineEx(line_start_x + cell_width * 4 + glyph_width * 2 + glyph_width * 20, 0);
                ig.igPushIDInt(line_i);
                if (ig.igArrowButton("##jmp", ig.ImGuiDir_Right)) {
                    ig.igSetScrollY(0);
                    self.stackPush(op_addr);
                    self.goto(jt);
                }
                if (ig.igIsItemHovered(ig.ImGuiHoveredFlags_None)) {
                    var tip: [16]u8 = undefined;
                    const ts = std.fmt.bufPrint(&tip, "Goto {X:0>4}\x00", .{jt}) catch unreachable;
                    _ = ts;
                    ig.igSetTooltip(&tip);
                    self.highlight_addr = jt;
                    self.highlight_valid = true;
                }
                ig.igPopID();
            }
        }
        ig.ImGuiListClipper_End(&clipper);
        ig.igPopStyleVarEx(2);
        ig.igEndChild(); // ##dasm_inner
        ig.igEndChild(); // ##dasm_box
    }

    pub fn draw(self: *Self) void {
        if (self.open != self.last_open) self.last_open = self.open;
        if (!self.open) return;

        self.highlight_valid = false;

        ig.igSetNextWindowPos(self.origin, ig.ImGuiCond_FirstUseEver);
        ig.igSetNextWindowSize(self.size, ig.ImGuiCond_FirstUseEver);
        if (ig.igBegin(self.title.ptr, &self.open, ig.ImGuiWindowFlags_None)) {
            self.drawStack();
            ig.igSameLine();
            self.drawDisasm();
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
