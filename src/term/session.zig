//! Terminal session: PTY + VT screen + selection helpers.
//! TermStore owns many sessions keyed by TermId.

const std = @import("std");
const screen_mod = @import("screen.zig");
const vt_mod = @import("vt.zig");
const pty_mod = @import("pty.zig");

pub const Screen = screen_mod.Screen;
pub const Cell = screen_mod.Cell;
pub const ColorIdx = screen_mod.ColorIdx;
pub const Parser = vt_mod.Parser;
pub const Pty = pty_mod.Pty;

pub const TermId = u32;
pub const INVALID_TERM: TermId = std.math.maxInt(TermId);

pub const default_cols = screen_mod.default_cols;
pub const default_rows = screen_mod.default_rows;

pub const Selection = struct {
    active: bool = false,
    a_row: u16 = 0,
    a_col: u16 = 0,
    b_row: u16 = 0,
    b_col: u16 = 0,

    pub fn clear(self: *Selection) void {
        self.* = .{};
    }

    pub fn normalized(self: Selection) struct { r0: u16, c0: u16, r1: u16, c1: u16 } {
        const a_first = self.a_row < self.b_row or (self.a_row == self.b_row and self.a_col <= self.b_col);
        if (a_first) return .{ .r0 = self.a_row, .c0 = self.a_col, .r1 = self.b_row, .c1 = self.b_col };
        return .{ .r0 = self.b_row, .c0 = self.b_col, .r1 = self.a_row, .c1 = self.a_col };
    }

    pub fn contains(self: Selection, row: u16, col: u16) bool {
        if (!self.active) return false;
        const n = self.normalized();
        if (row < n.r0 or row > n.r1) return false;
        if (row == n.r0 and row == n.r1) return col >= n.c0 and col <= n.c1;
        if (row == n.r0) return col >= n.c0;
        if (row == n.r1) return col <= n.c1;
        return true;
    }
};

pub const Session = struct {
    id: TermId,
    pty: Pty,
    screen: Screen,
    parser: Parser = .{},
    selection: Selection = .{},
    /// Display title (not owned unless title_owned).
    title: []const u8 = "zsh",
    title_owned: bool = false,
    /// Serial number for UI ("zsh · 3").
    serial: u32 = 1,
    /// True after we've renamed the title on child exit (avoid realloc each frame).
    exited_announced: bool = false,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        self.pty.deinit();
        self.screen.deinit();
        if (self.title_owned and self.title.len != 0) allocator.free(self.title);
        self.* = undefined;
    }

    pub fn isAlive(self: *const Session) bool {
        return self.pty.alive;
    }

    pub fn write(self: *Session, bytes: []const u8) void {
        if (!self.pty.alive) return;
        self.pty.writeAll(bytes);
        // New input: drop selection.
        self.selection.clear();
    }

    pub fn scroll(self: *Session, delta_lines: i32) void {
        self.screen.scrollView(delta_lines);
    }

    /// Copy selected view cells into `out` (rows separated by `\n`). Returns slice of out.
    pub fn copySelection(self: *const Session, out: []u8) []const u8 {
        if (!self.selection.active) return out[0..0];
        const n = self.selection.normalized();
        var len: usize = 0;
        var r = n.r0;
        while (r <= n.r1) : (r += 1) {
            const c_start: u16 = if (r == n.r0) n.c0 else 0;
            const c_end: u16 = if (r == n.r1) n.c1 else self.screen.cols - 1;
            // Trim trailing spaces on the line segment.
            var last_non_space: ?u16 = null;
            var c = c_start;
            while (c <= c_end) : (c += 1) {
                const cell = self.screen.viewCell(r, c);
                if (cell.ch != ' ') last_non_space = c;
            }
            if (last_non_space) |ln| {
                c = c_start;
                while (c <= ln) : (c += 1) {
                    if (len >= out.len) return out[0..len];
                    out[len] = self.screen.viewCell(r, c).ch;
                    len += 1;
                }
            }
            if (r < n.r1) {
                if (len >= out.len) return out[0..len];
                out[len] = '\n';
                len += 1;
            }
        }
        return out[0..len];
    }
};

/// Cap bytes drained from all PTYs per frame so floods don't stall the UI.
pub const max_read_per_frame: usize = 64 * 1024;
const read_chunk: usize = 4096;

pub const TermStore = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayListUnmanaged(Session) = .empty,
    next_id: TermId = 1,
    next_serial: u32 = 1,
    /// Launch CWD for new terminals (owned).
    launch_cwd: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) TermStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TermStore) void {
        for (self.sessions.items) |*s| s.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        if (self.launch_cwd.len != 0) self.allocator.free(self.launch_cwd);
        self.* = undefined;
    }

    pub fn setLaunchCwd(self: *TermStore, cwd: []const u8) !void {
        const copy = try self.allocator.dupe(u8, cwd);
        if (self.launch_cwd.len != 0) self.allocator.free(self.launch_cwd);
        self.launch_cwd = copy;
    }

    pub fn find(self: *TermStore, id: TermId) ?*Session {
        for (self.sessions.items) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    pub fn findConst(self: *const TermStore, id: TermId) ?*const Session {
        for (self.sessions.items) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    pub fn create(self: *TermStore) !TermId {
        const cols = default_cols;
        const rows = default_rows;
        const cwd = if (self.launch_cwd.len != 0) self.launch_cwd else ".";
        var pty = try Pty.spawn(cols, rows, cwd);
        errdefer pty.deinit();

        var screen = try Screen.init(self.allocator, cols, rows, screen_mod.default_scrollback);
        errdefer screen.deinit();

        const id = self.next_id;
        self.next_id += 1;
        const serial = self.next_serial;
        self.next_serial += 1;

        var title_buf: [32]u8 = undefined;
        const title_tmp = try std.fmt.bufPrint(&title_buf, "zsh · {d}", .{serial});
        const title = try self.allocator.dupe(u8, title_tmp);

        try self.sessions.append(self.allocator, .{
            .id = id,
            .pty = pty,
            .screen = screen,
            .title = title,
            .title_owned = true,
            .serial = serial,
        });
        return id;
    }

    pub fn destroy(self: *TermStore, id: TermId) void {
        for (self.sessions.items, 0..) |*s, i| {
            if (s.id == id) {
                s.deinit(self.allocator);
                _ = self.sessions.orderedRemove(i);
                return;
            }
        }
    }

    /// Drain all PTY masters into their screens. Call once per frame.
    pub fn pollAll(self: *TermStore) void {
        var budget: usize = max_read_per_frame;
        var buf: [read_chunk]u8 = undefined;
        for (self.sessions.items) |*s| {
            s.pty.pollChild();
            if (!s.pty.alive and s.pty.master_fd < 0) continue;
            while (budget > 0) {
                const n = s.pty.read(buf[0..@min(buf.len, budget)]) orelse break;
                if (n == 0) break;
                s.parser.feed(&s.screen, buf[0..n]);
                budget -|= n;
            }
            // If child died, update title once.
            if (!s.pty.alive and !s.exited_announced) {
                s.exited_announced = true;
                var tbuf: [40]u8 = undefined;
                const t = std.fmt.bufPrint(&tbuf, "zsh · {d} (exited)", .{s.serial}) catch continue;
                if (self.allocator.dupe(u8, t)) |owned| {
                    if (s.title_owned and s.title.len != 0) self.allocator.free(s.title);
                    s.title = owned;
                    s.title_owned = true;
                } else |_| {}
            }
        }
    }
};
