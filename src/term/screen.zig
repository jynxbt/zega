//! Terminal screen buffer: visible grid + scrollback ring.
//! Cells are monospaced; attributes support basic SGR (16-color + bold/dim/reverse).

const std = @import("std");

pub const default_cols: u16 = 60;
pub const default_rows: u16 = 16;
pub const default_scrollback: u32 = 2000;

/// 16-color palette index (0–15) or special defaults.
pub const ColorIdx = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
    /// Use terminal default fg/bg.
    default = 255,
};

pub const Attr = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,
    _pad: u5 = 0,
};

pub const Cell = struct {
    ch: u8 = ' ',
    fg: ColorIdx = .default,
    bg: ColorIdx = .default,
    attr: Attr = .{},

    pub fn blank() Cell {
        return .{};
    }
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    visible: bool = true,
};

/// Pen state applied to newly written cells.
pub const Pen = struct {
    fg: ColorIdx = .default,
    bg: ColorIdx = .default,
    attr: Attr = .{},

    pub fn reset(self: *Pen) void {
        self.* = .{};
    }
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    /// Visible cells: row-major, length cols*rows.
    cells: []Cell,
    /// Scrollback lines (each line is `cols` cells). Older lines at lower indices until ring wraps.
    scrollback: []Cell,
    /// Number of valid lines currently stored in scrollback (≤ capacity).
    sb_len: u32 = 0,
    /// Ring write index: next line slot to fill.
    sb_head: u32 = 0,
    sb_cap: u32,
    cursor: Cursor = .{},
    pen: Pen = .{},
    /// How many scrollback lines above the top are visible (0 = live view).
    view_offset: u32 = 0,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, scrollback_lines: u32) !Screen {
        const n: usize = @as(usize, cols) * @as(usize, rows);
        const cells = try allocator.alloc(Cell, n);
        @memset(cells, Cell.blank());
        const sb_cap = @max(scrollback_lines, 1);
        const scrollback = try allocator.alloc(Cell, @as(usize, sb_cap) * @as(usize, cols));
        @memset(scrollback, Cell.blank());
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .scrollback = scrollback,
            .sb_cap = sb_cap,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.scrollback);
        self.* = undefined;
    }

    pub fn clearAll(self: *Screen) void {
        @memset(self.cells, Cell.blank());
        self.cursor = .{};
        self.dirty = true;
    }

    pub fn index(self: *const Screen, row: u16, col: u16) usize {
        return @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
    }

    pub fn cellAt(self: *const Screen, row: u16, col: u16) Cell {
        if (row >= self.rows or col >= self.cols) return Cell.blank();
        return self.cells[self.index(row, col)];
    }

    pub fn setCell(self: *Screen, row: u16, col: u16, cell: Cell) void {
        if (row >= self.rows or col >= self.cols) return;
        self.cells[self.index(row, col)] = cell;
        self.dirty = true;
    }

    pub fn clampCursor(self: *Screen) void {
        if (self.cursor.row >= self.rows) self.cursor.row = self.rows - 1;
        if (self.cursor.col >= self.cols) self.cursor.col = self.cols - 1;
    }

    fn makeCell(self: *const Screen, ch: u8) Cell {
        return .{
            .ch = ch,
            .fg = self.pen.fg,
            .bg = self.pen.bg,
            .attr = self.pen.attr,
        };
    }

    /// Put a glyph at the cursor and advance (with wrap + scroll).
    pub fn putChar(self: *Screen, ch: u8) void {
        if (self.cursor.col >= self.cols) {
            self.cursor.col = 0;
            self.lineFeed();
        }
        self.setCell(self.cursor.row, self.cursor.col, self.makeCell(ch));
        self.cursor.col += 1;
        // Auto-wrap: next put will LF if col == cols.
        self.dirty = true;
        // Typing/output while scrolled up snaps back to live view.
        self.view_offset = 0;
    }

    pub fn backspace(self: *Screen) void {
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
            self.cursor.col = self.cols - 1;
        }
        self.dirty = true;
    }

    pub fn carriageReturn(self: *Screen) void {
        self.cursor.col = 0;
        self.dirty = true;
    }

    pub fn lineFeed(self: *Screen) void {
        if (self.cursor.row + 1 < self.rows) {
            self.cursor.row += 1;
        } else {
            self.scrollUp();
        }
        self.dirty = true;
        self.view_offset = 0;
    }

    pub fn tab(self: *Screen) void {
        const next = ((self.cursor.col / 8) + 1) * 8;
        if (next >= self.cols) {
            self.cursor.col = self.cols; // wrap on next put
        } else {
            while (self.cursor.col < next) : (self.cursor.col += 1) {
                self.setCell(self.cursor.row, self.cursor.col, self.makeCell(' '));
            }
        }
        self.dirty = true;
    }

    /// Scroll visible area up by one line; top line goes to scrollback.
    pub fn scrollUp(self: *Screen) void {
        // Push top row into scrollback.
        self.pushScrollbackRow(0);
        // Shift rows up.
        const cols = self.cols;
        var r: u16 = 0;
        while (r + 1 < self.rows) : (r += 1) {
            const dst = self.index(r, 0);
            const src = self.index(r + 1, 0);
            @memcpy(self.cells[dst .. dst + cols], self.cells[src .. src + cols]);
        }
        // Clear bottom row.
        const last = self.index(self.rows - 1, 0);
        @memset(self.cells[last .. last + cols], Cell.blank());
        self.dirty = true;
    }

    fn pushScrollbackRow(self: *Screen, row: u16) void {
        const cols = self.cols;
        const src = self.index(row, 0);
        const slot = self.sb_head % self.sb_cap;
        const dst = @as(usize, slot) * @as(usize, cols);
        @memcpy(self.scrollback[dst .. dst + cols], self.cells[src .. src + cols]);
        self.sb_head = (self.sb_head + 1) % self.sb_cap;
        if (self.sb_len < self.sb_cap) self.sb_len += 1;
    }

    pub fn setCursor(self: *Screen, row: u16, col: u16) void {
        self.cursor.row = @min(row, self.rows -| 1);
        self.cursor.col = @min(col, self.cols -| 1);
        self.dirty = true;
    }

    pub fn moveCursor(self: *Screen, drow: i32, dcol: i32) void {
        var r: i32 = @as(i32, self.cursor.row) + drow;
        var c: i32 = @as(i32, self.cursor.col) + dcol;
        if (r < 0) r = 0;
        if (c < 0) c = 0;
        if (r >= self.rows) r = self.rows - 1;
        if (c >= self.cols) c = self.cols - 1;
        self.cursor.row = @intCast(r);
        self.cursor.col = @intCast(c);
        self.dirty = true;
    }

    /// Erase in display: 0=from cursor to end, 1=start to cursor, 2/3=all.
    pub fn eraseDisplay(self: *Screen, mode: u32) void {
        const cols = self.cols;
        switch (mode) {
            0 => {
                // From cursor to end of screen.
                var r = self.cursor.row;
                while (r < self.rows) : (r += 1) {
                    const c0: u16 = if (r == self.cursor.row) self.cursor.col else 0;
                    var c = c0;
                    while (c < cols) : (c += 1) {
                        self.cells[self.index(r, c)] = Cell.blank();
                    }
                }
            },
            1 => {
                var r: u16 = 0;
                while (r <= self.cursor.row) : (r += 1) {
                    const c1: u16 = if (r == self.cursor.row) self.cursor.col +| 1 else cols;
                    var c: u16 = 0;
                    while (c < c1) : (c += 1) {
                        self.cells[self.index(r, c)] = Cell.blank();
                    }
                }
            },
            else => self.clearAll(),
        }
        self.dirty = true;
    }

    /// Erase in line: 0=cursor to end, 1=start to cursor, 2=whole line.
    pub fn eraseLine(self: *Screen, mode: u32) void {
        const r = self.cursor.row;
        const cols = self.cols;
        switch (mode) {
            0 => {
                var c = self.cursor.col;
                while (c < cols) : (c += 1) {
                    self.cells[self.index(r, c)] = Cell.blank();
                }
            },
            1 => {
                var c: u16 = 0;
                while (c <= self.cursor.col) : (c += 1) {
                    self.cells[self.index(r, c)] = Cell.blank();
                }
            },
            else => {
                const start = self.index(r, 0);
                @memset(self.cells[start .. start + cols], Cell.blank());
            },
        }
        self.dirty = true;
    }

    pub fn scrollView(self: *Screen, delta: i32) void {
        if (self.sb_len == 0) {
            self.view_offset = 0;
            return;
        }
        const max_off = self.sb_len;
        var off: i64 = @as(i64, self.view_offset) + delta;
        if (off < 0) off = 0;
        if (off > max_off) off = max_off;
        self.view_offset = @intCast(off);
        self.dirty = true;
    }

    /// Cell at visible view (accounting for scrollback offset).
    /// `view_row` 0 is the top of the terminal viewport.
    pub fn viewCell(self: *const Screen, view_row: u16, col: u16) Cell {
        if (col >= self.cols or view_row >= self.rows) return Cell.blank();
        if (self.view_offset == 0) {
            return self.cellAt(view_row, col);
        }
        // view_offset lines of scrollback above the live screen top.
        // View rows [0 .. view_offset) come from scrollback (newest at bottom of that band).
        // View rows [view_offset ..) come from live cells starting at row 0.
        if (view_row < self.view_offset) {
            // Distance from live top into scrollback history.
            const from_live_top = self.view_offset - 1 - view_row;
            // Scrollback is a ring; newest line is at (sb_head-1).
            if (from_live_top >= self.sb_len) return Cell.blank();
            const newest: i64 = @as(i64, self.sb_head) - 1;
            var idx: i64 = newest - @as(i64, from_live_top);
            while (idx < 0) idx += self.sb_cap;
            const slot: u32 = @intCast(@mod(idx, @as(i64, self.sb_cap)));
            const base = @as(usize, slot) * @as(usize, self.cols) + col;
            return self.scrollback[base];
        }
        const live_row: u16 = view_row - @as(u16, @intCast(self.view_offset));
        if (live_row >= self.rows) return Cell.blank();
        return self.cellAt(live_row, col);
    }

    /// Whether the live cursor falls on this view cell.
    pub fn cursorOnView(self: *const Screen, view_row: u16, col: u16) bool {
        if (!self.cursor.visible or self.view_offset != 0) return false;
        return self.cursor.row == view_row and self.cursor.col == col;
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

test "putChar wrap and scroll" {
    var s = try Screen.init(std.testing.allocator, 4, 2, 10);
    defer s.deinit();
    // Fill first row
    s.putChar('a');
    s.putChar('b');
    s.putChar('c');
    s.putChar('d');
    try std.testing.expectEqual(@as(u16, 0), s.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), s.cursor.col);
    s.putChar('e'); // wrap + LF
    try std.testing.expectEqual(@as(u16, 1), s.cursor.row);
    try std.testing.expectEqual(@as(u8, 'e'), s.cellAt(1, 0).ch);
    // Scroll: fill second row and wrap again
    s.putChar('f');
    s.putChar('g');
    s.putChar('h');
    s.putChar('i'); // should scroll
    try std.testing.expectEqual(@as(u32, 1), s.sb_len);
    try std.testing.expectEqual(@as(u8, 'e'), s.cellAt(0, 0).ch);
}

test "SGR pen applied to cells" {
    var s = try Screen.init(std.testing.allocator, 8, 2, 4);
    defer s.deinit();
    s.pen.fg = .green;
    s.pen.attr.bold = true;
    s.putChar('X');
    const c = s.cellAt(0, 0);
    try std.testing.expectEqual(ColorIdx.green, c.fg);
    try std.testing.expect(c.attr.bold);
}
