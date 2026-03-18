//! Z80 CPU debugger UI.
//!
//! Shows a disassembly view centered on the current PC, with step/continue
//! controls, breakpoints, and execution history.
const std = @import("std");
const z80dasm = @import("chips").z80dasm;
const ig = @import("cimgui");
const ui_settings = @import("ui_settings.zig");

pub const MAX_BREAKPOINTS = 32;
pub const NUM_HISTORY = 256;
pub const NUM_DBG_LINES = 48;

pub const TypeConfig = struct {
    bus: type,
    cpu: type,
};

pub const StepMode = enum { none, into, over };

pub const Breakpoint = struct {
    addr: u16,
    enabled: bool,
};

pub fn Type(comptime cfg: TypeConfig) type {
    return struct {
        const Self = @This();
        const Bus = cfg.bus;
        const Z80 = cfg.cpu;

        const M1_MASK = Z80.M1 | Z80.MREQ | Z80.RD;

        pub const Options = struct {
            title: []const u8,
            cpu: *Z80,
            read_cb: *const fn (addr: u16, userdata: ?*anyopaque) u8,
            userdata: ?*anyopaque,
            origin: ig.ImVec2,
            size: ig.ImVec2 = .{},
            open: bool = false,
        };

        const DasmLine = struct {
            addr: u16,
            num_bytes: u8,
            bytes: [4]u8,
            mnemonic: [z80dasm.MAX_MNEMONIC_LEN]u8,
            mnemonic_len: u8,
        };

        title: []const u8,
        cpu: *Z80,
        read_cb: *const fn (addr: u16, userdata: ?*anyopaque) u8,
        userdata: ?*anyopaque,
        origin: ig.ImVec2,
        size: ig.ImVec2,
        open: bool,
        last_open: bool,
        valid: bool,

        stopped: bool,
        step_mode: StepMode,
        cur_op_pc: u16,
        stepover_pc: u16,

        num_breakpoints: u8,
        breakpoints: [MAX_BREAKPOINTS]Breakpoint,

        history: [NUM_HISTORY]u16,
        history_pos: u8,
        show_history: bool,

        dasm_lines: [NUM_DBG_LINES]DasmLine,
        dasm_num_lines: u8,

        pub fn initInPlace(self: *Self, opts: Options) void {
            self.* = .{
                .title = opts.title,
                .cpu = opts.cpu,
                .read_cb = opts.read_cb,
                .userdata = opts.userdata,
                .origin = opts.origin,
                .size = .{
                    .x = if (opts.size.x == 0) 460 else opts.size.x,
                    .y = if (opts.size.y == 0) 420 else opts.size.y,
                },
                .open = opts.open,
                .last_open = opts.open,
                .valid = true,
                .stopped = false,
                .step_mode = .none,
                .cur_op_pc = 0,
                .stepover_pc = 0,
                .num_breakpoints = 0,
                .breakpoints = [_]Breakpoint{.{ .addr = 0, .enabled = false }} ** MAX_BREAKPOINTS,
                .history = [_]u16{0} ** NUM_HISTORY,
                .history_pos = 0,
                .show_history = false,
                .dasm_lines = undefined,
                .dasm_num_lines = 0,
            };
        }

        pub fn discard(self: *Self) void {
            self.valid = false;
        }

        pub fn isStopped(self: *const Self) bool {
            return self.stopped;
        }

        /// Returns true if tick-by-tick execution is needed
        /// (step mode active or breakpoints enabled).
        pub fn needsTickDebug(self: *const Self) bool {
            if (self.step_mode != .none) return true;
            for (self.breakpoints[0..self.num_breakpoints]) |bp| {
                if (bp.enabled) return true;
            }
            return false;
        }

        /// Call after each individual CPU tick.
        /// Returns true if execution should stop.
        pub fn tick(self: *Self, pins: Bus) bool {
            if (pins & M1_MASK == M1_MASK) {
                const pc = Z80.getAddr(pins);
                self.cur_op_pc = pc;
                self.history[self.history_pos] = pc;
                self.history_pos +%= 1;
                for (self.breakpoints[0..self.num_breakpoints]) |bp| {
                    if (bp.enabled and bp.addr == pc) {
                        self.stopped = true;
                        self.step_mode = .none;
                        return true;
                    }
                }
                if (self.step_mode == .into) {
                    self.stopped = true;
                    self.step_mode = .none;
                    return true;
                }
                if (self.step_mode == .over and pc == self.stepover_pc) {
                    self.stopped = true;
                    self.step_mode = .none;
                    return true;
                }
            }
            return false;
        }

        pub fn breakExec(self: *Self) void {
            self.stopped = true;
            self.step_mode = .none;
        }

        pub fn continueExec(self: *Self) void {
            self.stopped = false;
            self.step_mode = .none;
        }

        pub fn stepInto(self: *Self) void {
            self.stopped = false;
            self.step_mode = .into;
        }

        pub fn stepOver(self: *Self) void {
            const opcode = self.read_cb(self.cur_op_pc, self.userdata);
            const is_stepover_op = switch (opcode) {
                0xCD, 0xDC, 0xFC, 0xD4, 0xC4, 0xF4, 0xEC, 0xE4, 0xCC, 0x10 => true,
                else => false,
            };
            if (is_stepover_op) {
                const res = z80dasm.op(self.cur_op_pc, self.read_cb, self.userdata);
                self.stepover_pc = res.next_pc;
                self.stopped = false;
                self.step_mode = .over;
            } else {
                self.stepInto();
            }
        }

        fn hasBreakpointAt(self: *const Self, addr: u16) bool {
            for (self.breakpoints[0..self.num_breakpoints]) |bp| {
                if (bp.addr == addr) return true;
            }
            return false;
        }

        fn isBreakpointEnabled(self: *const Self, addr: u16) bool {
            for (self.breakpoints[0..self.num_breakpoints]) |bp| {
                if (bp.addr == addr and bp.enabled) return true;
            }
            return false;
        }

        pub fn addBreakpoint(self: *Self, addr: u16) void {
            if (self.num_breakpoints >= MAX_BREAKPOINTS) return;
            for (self.breakpoints[0..self.num_breakpoints]) |*bp| {
                if (bp.addr == addr) {
                    bp.enabled = true;
                    return;
                }
            }
            self.breakpoints[self.num_breakpoints] = .{ .addr = addr, .enabled = true };
            self.num_breakpoints += 1;
        }

        pub fn removeBreakpoint(self: *Self, addr: u16) void {
            for (self.breakpoints[0..self.num_breakpoints], 0..) |bp, i| {
                if (bp.addr == addr) {
                    var j = i;
                    while (j + 1 < self.num_breakpoints) : (j += 1) {
                        self.breakpoints[j] = self.breakpoints[j + 1];
                    }
                    self.num_breakpoints -= 1;
                    return;
                }
            }
        }

        pub fn toggleBreakpoint(self: *Self, addr: u16) void {
            if (self.hasBreakpointAt(addr)) {
                self.removeBreakpoint(addr);
            } else {
                self.addBreakpoint(addr);
            }
        }

        fn rebuildDasm(self: *Self) void {
            const look_back: u16 = 5 * 4;
            const start = self.cur_op_pc -% look_back;
            var pc: u16 = start;
            var n: u8 = 0;
            while (n < NUM_DBG_LINES) {
                const op_addr = pc;
                const res = z80dasm.op(pc, self.read_cb, self.userdata);
                var line = DasmLine{
                    .addr = op_addr,
                    .num_bytes = res.num_bytes,
                    .bytes = undefined,
                    .mnemonic = res.mnemonic,
                    .mnemonic_len = res.mnemonic_len,
                };
                for (0..res.num_bytes) |bi| {
                    line.bytes[bi] = self.read_cb(op_addr +% @as(u16, @intCast(bi)), self.userdata);
                }
                self.dasm_lines[n] = line;
                n += 1;
                pc = res.next_pc;
            }
            self.dasm_num_lines = n;
        }

        fn drawButtons(self: *Self) void {
            const stopped = self.stopped;
            if (stopped) {
                if (ig.igButton("Continue [F5]")) self.continueExec();
            } else {
                if (ig.igButton("Break [F5]")) self.breakExec();
            }
            ig.igSameLine();
            if (!stopped) ig.igBeginDisabled(true);
            if (ig.igButton("Step Over [F6]")) self.stepOver();
            ig.igSameLine();
            if (ig.igButton("Step Into [F7]")) self.stepInto();
            if (!stopped) ig.igEndDisabled();
        }

        fn drawDisasm(self: *Self) void {
            self.rebuildDasm();

            const glyph_width = ig.igCalcTextSize("F").x;
            const cell_width = 3.0 * glyph_width;

            ig.igPushStyleVarImVec2(ig.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
            ig.igPushStyleVarImVec2(ig.ImGuiStyleVar_ItemSpacing, .{ .x = 0, .y = 0 });

            const avail = ig.igGetContentRegionAvail();
            _ = ig.igBeginChild("##dbg_dasm", .{ .x = avail.x, .y = avail.y - 40 }, ig.ImGuiChildFlags_None, ig.ImGuiWindowFlags_None);

            for (self.dasm_lines[0..self.dasm_num_lines]) |line| {
                const is_cur = line.addr == self.cur_op_pc;
                const has_bp = self.isBreakpointEnabled(line.addr);

                if (is_cur) {
                    ig.igPushStyleColor(ig.ImGuiCol_Text, 0xFF00FFFF);
                } else if (has_bp) {
                    ig.igPushStyleColor(ig.ImGuiCol_Text, 0xFF4040FF);
                }

                ig.igPushIDInt(@as(c_int, @intCast(line.addr)));

                // Clickable indicator + address column
                const indicator: []const u8 = if (has_bp) (if (is_cur) ">*" else " *") else (if (is_cur) "> " else "  ");
                var row_buf: [16]u8 = undefined;
                const row_s = std.fmt.bufPrint(&row_buf, "{s}{X:0>4}: \x00", .{ indicator, line.addr }) catch unreachable;
                _ = row_s;
                if (ig.igSelectable(&row_buf)) {
                    self.toggleBreakpoint(line.addr);
                }
                ig.igSameLine();

                // Bytes
                const line_start_x = ig.igGetCursorPosX();
                for (0..line.num_bytes) |bi| {
                    ig.igSameLineEx(line_start_x + cell_width * @as(f32, @floatFromInt(bi)), 0);
                    var byte_buf: [4]u8 = undefined;
                    const bs = std.fmt.bufPrint(&byte_buf, "{X:0>2} \x00", .{line.bytes[bi]}) catch unreachable;
                    _ = bs;
                    ig.igTextUnformatted(&byte_buf);
                }

                // Mnemonic
                ig.igSameLineEx(line_start_x + cell_width * 4 + glyph_width, 0);
                var mn_buf: [z80dasm.MAX_MNEMONIC_LEN + 1]u8 = undefined;
                @memcpy(mn_buf[0..line.mnemonic_len], line.mnemonic[0..line.mnemonic_len]);
                mn_buf[line.mnemonic_len] = 0;
                ig.igTextUnformatted(&mn_buf);

                ig.igPopID();

                if (is_cur or has_bp) ig.igPopStyleColor();

                if (is_cur) ig.igSetScrollHereY(0.3);
            }

            ig.igEndChild();
            ig.igPopStyleVarEx(2);
        }

        fn drawHistory(self: *Self) void {
            if (!ig.igBegin("Execution History", &self.show_history, ig.ImGuiWindowFlags_None)) {
                ig.igEnd();
                return;
            }
            if (ig.igBeginListBox("##history", .{ .x = -1, .y = -1 })) {
                const show: u8 = @min(64, self.history_pos);
                var i: usize = @as(usize, self.history_pos);
                var cnt: u8 = show;
                while (cnt > 0) {
                    cnt -= 1;
                    if (i == 0) i = NUM_HISTORY;
                    i -= 1;
                    var buf: [8]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{X:0>4}\x00", .{self.history[i]}) catch unreachable;
                    _ = s;
                    ig.igTextUnformatted(&buf);
                }
                ig.igEndListBox();
            }
            ig.igEnd();
        }

        fn handleKeys(self: *Self) void {
            if (ig.igIsKeyPressedEx(ig.ImGuiKey_F5, false)) {
                if (self.stopped) self.continueExec() else self.breakExec();
            }
            if (self.stopped) {
                if (ig.igIsKeyPressedEx(ig.ImGuiKey_F6, false)) self.stepOver();
                if (ig.igIsKeyPressedEx(ig.ImGuiKey_F7, false)) self.stepInto();
                if (ig.igIsKeyPressedEx(ig.ImGuiKey_F9, false)) self.toggleBreakpoint(self.cur_op_pc);
            }
        }

        pub fn draw(self: *Self, bus: Bus) void {
            _ = bus;
            if (self.open != self.last_open) self.last_open = self.open;
            if (!self.open) return;

            self.handleKeys();
            if (self.show_history) self.drawHistory();

            ig.igSetNextWindowPos(self.origin, ig.ImGuiCond_FirstUseEver);
            ig.igSetNextWindowSize(self.size, ig.ImGuiCond_FirstUseEver);
            if (ig.igBegin(self.title.ptr, &self.open, ig.ImGuiWindowFlags_None)) {
                self.drawButtons();
                ig.igSeparator();
                self.drawDisasm();
                ig.igSeparator();
                var status_buf: [64]u8 = undefined;
                const ss = std.fmt.bufPrint(&status_buf, "PC:{X:0>4}  {s}  BPs:{}\x00", .{
                    self.cur_op_pc,
                    if (self.stopped) @as([]const u8, "STOPPED") else @as([]const u8, "RUNNING"),
                    self.num_breakpoints,
                }) catch unreachable;
                _ = ss;
                ig.igTextUnformatted(&status_buf);
                ig.igSameLine();
                if (ig.igButton("History")) self.show_history = !self.show_history;
                ig.igSameLine();
                if (ig.igButton("Clear BPs")) self.num_breakpoints = 0;
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
