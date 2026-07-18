//! Minimal VT100 / xterm CSI parser for shell output.
//! Handles printable ASCII, C0 controls, CSI cursor/erase, and SGR colors.

const std = @import("std");
const screen_mod = @import("screen.zig");

const Screen = screen_mod.Screen;
const ColorIdx = screen_mod.ColorIdx;

const State = enum {
    ground,
    esc,
    csi,
    osc,
    /// Skip until ST (ESC \) or BEL after OSC.
    osc_string,
    /// ESC ] ... intermediate; also used for ESC ignored sequences.
    esc_ignore,
};

pub const Parser = struct {
    state: State = .ground,
    /// CSI parameter buffer (numeric params separated by ';').
    params: [16]u32 = .{0} ** 16,
    param_count: u8 = 0,
    param_idx: u8 = 0,
    collecting_param: bool = false,
    /// Intermediate bytes (rarely used in our subset).
    intermediate: u8 = 0,
    /// Private marker '?' after CSI.
    private: bool = false,
    utf8_remain: u8 = 0,

    pub fn init() Parser {
        return .{};
    }

    pub fn feed(self: *Parser, screen: *Screen, bytes: []const u8) void {
        for (bytes) |b| {
            self.byte(screen, b);
        }
    }

    fn byte(self: *Parser, screen: *Screen, b: u8) void {
        // Incomplete UTF-8: drop continuation bytes as '?'.
        if (self.utf8_remain > 0) {
            if (b & 0xC0 == 0x80) {
                self.utf8_remain -= 1;
                if (self.utf8_remain == 0 and self.state == .ground) {
                    screen.putChar('?');
                }
                return;
            }
            self.utf8_remain = 0;
            // Fall through — resync on this byte.
        }

        switch (self.state) {
            .ground => self.groundByte(screen, b),
            .esc => self.escByte(screen, b),
            .csi => self.csiByte(screen, b),
            .osc, .osc_string => self.oscByte(b),
            .esc_ignore => {
                // Consume one final byte or stay until C0/C1.
                if (b >= 0x20 and b <= 0x2F) {
                    // intermediate
                } else {
                    self.state = .ground;
                }
            },
        }
    }

    fn groundByte(self: *Parser, screen: *Screen, b: u8) void {
        switch (b) {
            0x00...0x07, 0x0E...0x1A, 0x1C...0x1F => {}, // ignore most C0
            0x08 => screen.backspace(), // BS
            0x09 => screen.tab(),
            0x0A => screen.lineFeed(), // LF
            0x0B, 0x0C => screen.lineFeed(), // VT/FF
            0x0D => screen.carriageReturn(), // CR
            0x1B => {
                self.state = .esc;
            },
            0x7F => screen.backspace(), // DEL
            else => {
                if (b >= 0x20 and b < 0x7F) {
                    screen.putChar(b);
                } else if (b >= 0xC0) {
                    // Start of multi-byte UTF-8 → one '?'.
                    if (b >= 0xF0) self.utf8_remain = 3 else if (b >= 0xE0) self.utf8_remain = 2 else self.utf8_remain = 1;
                } else if (b >= 0x80) {
                    // Stray continuation or C1 — ignore.
                }
            },
        }
    }

    fn escByte(self: *Parser, screen: *Screen, b: u8) void {
        switch (b) {
            '[' => {
                self.resetCsi();
                self.state = .csi;
            },
            ']' => {
                self.state = .osc_string;
            },
            // 7-bit equivalents / simple ESC sequences we ignore
            'c' => { // RIS — soft reset
                screen.clearAll();
                screen.pen.reset();
                self.state = .ground;
            },
            'D' => { // IND
                screen.lineFeed();
                self.state = .ground;
            },
            'E' => { // NEL
                screen.carriageReturn();
                screen.lineFeed();
                self.state = .ground;
            },
            'M' => { // RI — reverse index (simple: move up or stay)
                if (screen.cursor.row > 0) screen.cursor.row -= 1;
                screen.dirty = true;
                self.state = .ground;
            },
            '7', '8' => { // save/restore cursor — ignore for v1
                self.state = .ground;
            },
            '(', ')', '*', '+' => {
                // Charset designate — ignore next byte
                self.state = .esc_ignore;
            },
            else => {
                self.state = .ground;
            },
        }
    }

    fn oscByte(self: *Parser, b: u8) void {
        // OSC ends with BEL or ST (ESC \). We only track BEL and ESC.
        if (b == 0x07) {
            self.state = .ground;
            return;
        }
        if (b == 0x1B) {
            self.state = .esc_ignore; // next should be '\'
            return;
        }
        // else keep consuming
    }

    fn resetCsi(self: *Parser) void {
        self.params = .{0} ** 16;
        self.param_count = 0;
        self.param_idx = 0;
        self.collecting_param = false;
        self.intermediate = 0;
        self.private = false;
    }

    fn csiByte(self: *Parser, screen: *Screen, b: u8) void {
        if (b == '?' and self.param_idx == 0 and !self.collecting_param and self.param_count == 0) {
            self.private = true;
            return;
        }
        if (b >= '0' and b <= '9') {
            if (!self.collecting_param) {
                self.collecting_param = true;
                if (self.param_count < self.params.len) self.param_count += 1;
            }
            const i = if (self.param_count > 0) self.param_count - 1 else 0;
            if (i < self.params.len) {
                self.params[i] = self.params[i] *| 10 +| (b - '0');
            }
            return;
        }
        if (b == ';') {
            if (!self.collecting_param) {
                // empty param
                if (self.param_count < self.params.len) self.param_count += 1;
            }
            self.collecting_param = false;
            return;
        }
        if (b >= 0x20 and b <= 0x2F) {
            self.intermediate = b;
            return;
        }
        // Final byte
        self.state = .ground;
        if (!self.collecting_param and self.param_count == 0) {
            // no params — treat as default 0/1 depending on command
        } else if (self.collecting_param) {
            // last param finished
        }
        if (self.private) {
            // DEC private modes — ignore (cursor visible etc.)
            return;
        }
        self.execCsi(screen, b);
    }

    fn param(self: *const Parser, idx: usize, default: u32) u32 {
        if (idx >= self.param_count) return default;
        const v = self.params[idx];
        if (v == 0 and default != 0) return default; // many CSI treat 0 as default 1
        return v;
    }

    fn paramRaw(self: *const Parser, idx: usize, default: u32) u32 {
        if (idx >= self.param_count) return default;
        return self.params[idx];
    }

    fn execCsi(self: *Parser, screen: *Screen, final: u8) void {
        switch (final) {
            'A' => screen.moveCursor(-@as(i32, @intCast(self.param(0, 1))), 0), // CUU
            'B' => screen.moveCursor(@intCast(self.param(0, 1)), 0), // CUD
            'C' => screen.moveCursor(0, @intCast(self.param(0, 1))), // CUF
            'D' => screen.moveCursor(0, -@as(i32, @intCast(self.param(0, 1)))), // CUB
            'G' => { // CHA — cursor horizontal absolute (1-based)
                const col = self.param(0, 1);
                screen.setCursor(screen.cursor.row, @intCast(@max(col, 1) - 1));
            },
            'H', 'f' => { // CUP
                const row = self.param(0, 1);
                const col = self.param(1, 1);
                screen.setCursor(
                    @intCast(@max(row, 1) - 1),
                    @intCast(@max(col, 1) - 1),
                );
            },
            'J' => screen.eraseDisplay(self.paramRaw(0, 0)),
            'K' => screen.eraseLine(self.paramRaw(0, 0)),
            'm' => self.applySgr(screen),
            'd' => { // VPA
                const row = self.param(0, 1);
                screen.setCursor(@intCast(@max(row, 1) - 1), screen.cursor.col);
            },
            'n', 'c', 'h', 'l', 'r', 's', 'u', 't', 'S', 'T', 'L', 'M', 'P', 'X', '@' => {
                // Query / mode / scroll / insert — ignore for v1
            },
            else => {},
        }
    }

    fn applySgr(self: *Parser, screen: *Screen) void {
        if (self.param_count == 0) {
            screen.pen.reset();
            return;
        }
        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => screen.pen.reset(),
                1 => screen.pen.attr.bold = true,
                2 => screen.pen.attr.dim = true,
                7 => screen.pen.attr.reverse = true,
                22 => {
                    screen.pen.attr.bold = false;
                    screen.pen.attr.dim = false;
                },
                27 => screen.pen.attr.reverse = false,
                30...37 => screen.pen.fg = @enumFromInt(@as(u8, @intCast(p - 30))),
                39 => screen.pen.fg = .default,
                40...47 => screen.pen.bg = @enumFromInt(@as(u8, @intCast(p - 40))),
                49 => screen.pen.bg = .default,
                90...97 => screen.pen.fg = @enumFromInt(@as(u8, @intCast(p - 90 + 8))),
                100...107 => screen.pen.bg = @enumFromInt(@as(u8, @intCast(p - 100 + 8))),
                38, 48 => {
                    // Extended color: 38;5;n or 38;2;r;g;b — skip args for v1, map 256→16 if 5.
                    const is_fg = p == 38;
                    if (i + 1 < self.param_count) {
                        const mode = self.params[i + 1];
                        if (mode == 5 and i + 2 < self.param_count) {
                            const n = self.params[i + 2];
                            const idx = xterm256To16(n);
                            if (is_fg) screen.pen.fg = idx else screen.pen.bg = idx;
                            i += 2;
                        } else if (mode == 2 and i + 4 < self.param_count) {
                            // truecolor → approximate via luminance bucket
                            const r = self.params[i + 2];
                            const g = self.params[i + 3];
                            const b = self.params[i + 4];
                            const idx = rgbTo16(r, g, b);
                            if (is_fg) screen.pen.fg = idx else screen.pen.bg = idx;
                            i += 4;
                        } else {
                            i += 1;
                        }
                    }
                },
                else => {},
            }
        }
    }
};

fn xterm256To16(n: u32) ColorIdx {
    if (n < 16) return @enumFromInt(@as(u8, @intCast(n)));
    if (n >= 232) {
        // grayscale ramp
        return if (n > 244) .bright_white else if (n > 238) .white else .bright_black;
    }
    // 6x6x6 color cube 16..231
    const c = n - 16;
    const r = c / 36;
    const g = (c / 6) % 6;
    const b = c % 6;
    return rgbTo16(r * 51, g * 51, b * 51);
}

fn rgbTo16(r: u32, g: u32, b: u32) ColorIdx {
    // Pick nearest of 16 ANSI colors (rough).
    const bright = (r + g + b) > 400;
    const maxc = @max(r, @max(g, b));
    if (maxc < 40) return if (bright) .bright_black else .black;
    const r_on = r > maxc * 60 / 100;
    const g_on = g > maxc * 60 / 100;
    const b_on = b > maxc * 60 / 100;
    const code: u8 = (@as(u8, @intFromBool(r_on))) |
        (@as(u8, @intFromBool(g_on)) << 1) |
        (@as(u8, @intFromBool(b_on)) << 2);
    if (code == 0) return if (bright) .bright_black else .black;
    if (code == 7) return if (bright) .bright_white else .white;
    return @enumFromInt(if (bright) code + 8 else code);
}

// ── tests ──────────────────────────────────────────────────────────────────

test "plain text and newline" {
    var s = try screen_mod.Screen.init(std.testing.allocator, 20, 4, 10);
    defer s.deinit();
    var p = Parser.init();
    p.feed(&s, "hi\r\nthere");
    try std.testing.expectEqual(@as(u8, 'h'), s.cellAt(0, 0).ch);
    try std.testing.expectEqual(@as(u8, 't'), s.cellAt(1, 0).ch);
}

test "CSI SGR green" {
    var s = try screen_mod.Screen.init(std.testing.allocator, 20, 2, 4);
    defer s.deinit();
    var p = Parser.init();
    p.feed(&s, "\x1b[32mOK\x1b[0m");
    try std.testing.expectEqual(ColorIdx.green, s.cellAt(0, 0).fg);
    try std.testing.expectEqual(@as(u8, 'O'), s.cellAt(0, 0).ch);
}

test "CSI CUP" {
    var s = try screen_mod.Screen.init(std.testing.allocator, 20, 8, 4);
    defer s.deinit();
    var p = Parser.init();
    p.feed(&s, "\x1b[3;5H*");
    try std.testing.expectEqual(@as(u16, 2), s.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), s.cursor.col); // after put
    try std.testing.expectEqual(@as(u8, '*'), s.cellAt(2, 4).ch);
}

test "erase line" {
    var s = try screen_mod.Screen.init(std.testing.allocator, 10, 2, 4);
    defer s.deinit();
    var p = Parser.init();
    p.feed(&s, "abcdef\x1b[3G\x1b[K");
    try std.testing.expectEqual(@as(u8, 'a'), s.cellAt(0, 0).ch);
    try std.testing.expectEqual(@as(u8, 'b'), s.cellAt(0, 1).ch);
    try std.testing.expectEqual(@as(u8, ' '), s.cellAt(0, 2).ch);
}
