//! Bubble model: lightweight, fully editable code fragments on the canvas.
//! Matches the Code Bubbles metaphor (Bragdon et al., ICSE 2010 / CHI 2010).
//! Fragments are views into a shared Document (flow Buffer.Manager pattern).

const std = @import("std");
const geom = @import("geom.zig");
const doc_mod = @import("doc.zig");

pub const BubbleId = u32;
pub const GroupId = u32;
pub const ConnectionId = u32;
pub const DocId = doc_mod.DocId;

pub const INVALID_BUBBLE: BubbleId = std.math.maxInt(BubbleId);
pub const INVALID_GROUP: GroupId = std.math.maxInt(GroupId);
pub const INVALID_DOC = doc_mod.INVALID_DOC;

/// Kind of content hosted by a bubble (paper §5–6).
pub const BubbleKind = enum {
    code,
    note,
    docs,
    stack,
    data,
    flag,
    /// Module imports / use statements (compact dependency bubble).
    imports,
};

/// Document-backed fragment range (half-open lines).
pub const FragmentView = struct {
    doc: DocId,
    start_line: u32,
    end_line: u32,

    pub fn lineCount(self: FragmentView) u32 {
        if (self.end_line <= self.start_line) return 0;
        return self.end_line - self.start_line;
    }

    /// Adjust range when `line_delta` lines are inserted (positive) or removed
    /// (negative) starting at `edit_line` in the document.
    pub fn shift(self: *FragmentView, edit_line: u32, line_delta: i32) void {
        if (line_delta == 0) return;
        const d = line_delta;
        // Entirely before edit: unchanged.
        if (self.end_line <= edit_line) return;
        // Entirely after edit start: shift both ends.
        if (self.start_line >= edit_line) {
            self.start_line = addDelta(self.start_line, d);
            self.end_line = addDelta(self.end_line, d);
            return;
        }
        // Spans the edit: grow/shrink end only.
        self.end_line = addDelta(self.end_line, d);
        if (self.end_line < self.start_line) self.end_line = self.start_line;
    }
};

fn addDelta(v: u32, d: i32) u32 {
    const n = @as(i64, v) + d;
    if (n < 0) return 0;
    return @intCast(n);
}

pub const Content = union(enum) {
    /// Owned note text (not a file fragment).
    note,
    /// View into a Document.
    fragment: FragmentView,
};

pub const Caret = struct {
    /// Line relative to fragment start (0 = first line of bubble).
    line: u32 = 0,
    col: u32 = 0,
};

/// Text selection within a bubble (fragment-relative lines/cols).
pub const Selection = struct {
    active: bool = false,
    a_line: u32 = 0,
    a_col: u32 = 0,
    b_line: u32 = 0,
    b_col: u32 = 0,

    pub fn clear(self: *Selection) void {
        self.* = .{};
    }

    /// Ordered so start ≤ end in document order.
    pub fn normalized(self: Selection) struct { sl: u32, sc: u32, el: u32, ec: u32 } {
        const a_first = self.a_line < self.b_line or (self.a_line == self.b_line and self.a_col <= self.b_col);
        if (a_first) return .{ .sl = self.a_line, .sc = self.a_col, .el = self.b_line, .ec = self.b_col };
        return .{ .sl = self.b_line, .sc = self.b_col, .el = self.a_line, .ec = self.a_col };
    }

    pub fn isEmpty(self: Selection) bool {
        return !self.active or (self.a_line == self.b_line and self.a_col == self.b_col);
    }
};

pub const ElisionRange = struct {
    start_line: u32,
    end_line: u32,
    collapsed: bool = true,
};

pub const ConnectionAnchor = struct {
    bubble: BubbleId,
    line: ?u32 = null,
};

pub const Connection = struct {
    id: ConnectionId,
    from: ConnectionAnchor,
    to: ConnectionAnchor,
    /// Column range [start, end) of the call name on `from.line` (document line).
    call_col_start: ?u32 = null,
    call_col_end: ?u32 = null,
};

pub const WorkingSet = struct {
    id: GroupId,
    name: []const u8 = "",
    color_index: u8 = 0,
    members: std.ArrayListUnmanaged(BubbleId) = .empty,

    pub fn deinit(self: *WorkingSet, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
        self.* = undefined;
    }
};

pub const Bubble = struct {
    id: BubbleId,
    kind: BubbleKind = .code,
    bounds: geom.BoundingBox,

    /// Display title (symbol name). Not owned unless `title_owned`.
    title: []const u8 = "",
    title_owned: bool = false,

    fragment_key: []const u8 = "",
    fragment_key_owned: bool = false,

    content: Content = .note,

    /// Owned note/ephemeral body when content == .note.
    text: []u8 = &.{},

    /// Independent edit buffer for a fragment bubble. When set, this bubble no longer
    /// writes into the shared Document until save (so Cmd+S on A does not persist B).
    local_text: ?[]u8 = null,
    /// Absolute document line range [start, end) that `local_text` replaces on save.
    local_base_start: u32 = 0,
    local_base_end: u32 = 0,

    caret: Caret = .{},
    selection: Selection = .{},
    focused: bool = false,
    /// Unsaved edits made through this bubble.
    dirty: bool = false,

    elisions: std.ArrayListUnmanaged(ElisionRange) = .empty,

    min_content_width: f32 = 120,
    line_height: f32 = 16,
    pad_x: f32 = 8,
    pad_y: f32 = 22,

    group_id: GroupId = INVALID_GROUP,
    pinned: bool = false,
    z: u32 = 0,

    pub fn deinit(self: *Bubble, allocator: std.mem.Allocator) void {
        if (self.text.len != 0) allocator.free(self.text);
        if (self.local_text) |lt| allocator.free(lt);
        if (self.title_owned and self.title.len != 0) allocator.free(self.title);
        if (self.fragment_key_owned and self.fragment_key.len != 0) allocator.free(self.fragment_key);
        self.elisions.deinit(allocator);
        self.* = undefined;
    }

    pub fn clearLocal(self: *Bubble, allocator: std.mem.Allocator) void {
        if (self.local_text) |lt| {
            allocator.free(lt);
            self.local_text = null;
        }
        self.local_base_start = 0;
        self.local_base_end = 0;
    }

    pub fn isDetached(self: *const Bubble) bool {
        return self.local_text != null;
    }

    pub fn setNoteText(self: *Bubble, allocator: std.mem.Allocator, bytes: []const u8) !void {
        const copy = try allocator.dupe(u8, bytes);
        if (self.text.len != 0) allocator.free(self.text);
        self.text = copy;
        self.content = .note;
        self.kind = .note;
    }

    /// Back-compat alias for notes.
    pub fn setText(self: *Bubble, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.setNoteText(allocator, bytes);
    }

    pub fn setFragment(self: *Bubble, doc: DocId, start_line: u32, end_line: u32) void {
        self.content = .{ .fragment = .{
            .doc = doc,
            .start_line = start_line,
            .end_line = end_line,
        } };
        self.kind = .code;
    }

    pub fn setTitleOwned(self: *Bubble, allocator: std.mem.Allocator, title: []const u8) !void {
        const copy = try allocator.dupe(u8, title);
        if (self.title_owned and self.title.len != 0) allocator.free(self.title);
        self.title = copy;
        self.title_owned = true;
    }

    pub fn setFragmentKeyOwned(self: *Bubble, allocator: std.mem.Allocator, key: []const u8) !void {
        const copy = try allocator.dupe(u8, key);
        if (self.fragment_key_owned and self.fragment_key.len != 0) allocator.free(self.fragment_key);
        self.fragment_key = copy;
        self.fragment_key_owned = true;
    }

    /// Display bytes for rendering. Lifetime tied to bubble local buffer or store.
    pub fn displayText(self: *const Bubble, store: *const doc_mod.DocumentStore) []const u8 {
        if (self.local_text) |lt| return lt;
        return switch (self.content) {
            .note => self.text,
            .fragment => |f| blk: {
                const d = store.getConst(f.doc) orelse break :blk self.text;
                break :blk d.rangeSlice(f.start_line, f.end_line);
            },
        };
    }

    /// Line count of the editable body (local buffer or fragment).
    pub fn bodyLineCount(self: *const Bubble, store: *const doc_mod.DocumentStore) u32 {
        _ = store;
        if (self.local_text) |lt| return lineCountOf(lt);
        if (self.fragment()) |f| return f.lineCount();
        return lineCountOf(self.text);
    }

    pub fn fragment(self: *const Bubble) ?FragmentView {
        return switch (self.content) {
            .fragment => |f| f,
            .note => null,
        };
    }

    pub fn fragmentMut(self: *Bubble) ?*FragmentView {
        return switch (self.content) {
            .fragment => |*f| f,
            .note => null,
        };
    }

    /// Absolute document line for caret.
    pub fn caretDocLine(self: *const Bubble) ?u32 {
        const f = self.fragment() orelse return null;
        return f.start_line + self.caret.line;
    }

    pub fn pos(self: Bubble) geom.Vec2 {
        return self.bounds.pos();
    }

    pub fn setPos(self: *Bubble, p: geom.Vec2) void {
        self.bounds.x = p.x;
        self.bounds.y = p.y;
    }

    pub fn translate(self: *Bubble, d: geom.Vec2) void {
        self.bounds = self.bounds.translated(d);
    }

    pub fn contentBounds(self: Bubble) geom.BoundingBox {
        return .{
            .x = self.bounds.x + self.pad_x,
            .y = self.bounds.y + self.pad_y,
            .w = @max(0, self.bounds.w - self.pad_x * 2),
            .h = @max(0, self.bounds.h - self.pad_y - self.pad_x),
        };
    }

    /// Title / drag bar height (matches renderer breadcrumb strip).
    pub fn titleBarHeight(self: Bubble) f32 {
        return @min(self.pad_y, self.bounds.h * 0.35);
    }

    /// Top strip used for dragging the bubble (not the code body).
    pub fn titleBarBounds(self: Bubble) geom.BoundingBox {
        return .{
            .x = self.bounds.x,
            .y = self.bounds.y,
            .w = self.bounds.w,
            .h = self.titleBarHeight(),
        };
    }

    pub fn hitTitleBar(self: Bubble, world: geom.Vec2) bool {
        return self.titleBarBounds().containsPoint(world);
    }

    /// Size of the × remove control in the title bar (world units).
    pub const close_btn_size: f32 = 14;
    pub const close_btn_pad: f32 = 4;

    /// Top-right close button rect inside the title bar.
    pub fn closeButtonBounds(self: Bubble) geom.BoundingBox {
        const tb = self.titleBarBounds();
        const s = close_btn_size;
        const p = close_btn_pad;
        return .{
            .x = tb.x + tb.w - s - p,
            .y = tb.y + @max(0, (tb.h - s) * 0.5),
            .w = s,
            .h = s,
        };
    }

    pub fn hitCloseButton(self: Bubble, world: geom.Vec2) bool {
        return self.closeButtonBounds().containsPoint(world);
    }

    pub fn heightForLines(self: Bubble, visible_line_count: u32) f32 {
        return self.pad_y + self.pad_x + @as(f32, @floatFromInt(visible_line_count)) * self.line_height;
    }

    /// Resize height to fit fragment line count (before reflow).
    pub fn fitHeightToLines(self: *Bubble, lines: u32, min_h: f32) void {
        self.bounds.h = @max(min_h, self.heightForLines(lines));
    }
};

/// Number of lines in a text buffer (document-compatible: trailing `\n` counts an extra line).
pub fn lineCountOf(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var n: u32 = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

pub fn lineSliceOf(text: []const u8, line: u32) []const u8 {
    var cur: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const at_nl = !at_end and text[i] == '\n';
        if (!at_end and !at_nl) continue;
        if (cur == line) {
            var s = text[start..i];
            if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
            return s;
        }
        if (at_end) break;
        start = i + 1;
        cur += 1;
    }
    return &.{};
}

pub fn offsetAtOf(text: []const u8, line: u32, col: u32) u32 {
    var cur: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const at_nl = !at_end and text[i] == '\n';
        if (!at_end and !at_nl) continue;
        if (cur == line) {
            const line_bytes = text[start..i];
            const c = @min(col, @as(u32, @intCast(line_bytes.len)));
            return @intCast(start + c);
        }
        if (at_end) return @intCast(text.len);
        start = i + 1;
        cur += 1;
    }
    return @intCast(text.len);
}

/// Shift all fragment bubbles after a document line edit.
/// Also shifts detached local_base ranges (except `except_id` if provided as maxInt to shift all).
pub fn shiftAllFragments(
    bubbles: []Bubble,
    doc: DocId,
    edit_line: u32,
    line_delta: i32,
) void {
    shiftAllFragmentsExcept(bubbles, doc, edit_line, line_delta, std.math.maxInt(BubbleId));
}

pub fn shiftAllFragmentsExcept(
    bubbles: []Bubble,
    doc: DocId,
    edit_line: u32,
    line_delta: i32,
    except_id: BubbleId,
) void {
    for (bubbles) |*b| {
        if (b.id == except_id) continue;
        if (b.local_text != null and b.fragment() != null) {
            if (b.fragment().?.doc == doc) {
                // Shift local base range if it starts at/after edit_line.
                if (b.local_base_end <= edit_line) {
                    // entirely before
                } else if (b.local_base_start >= edit_line) {
                    b.local_base_start = addDelta(b.local_base_start, line_delta);
                    b.local_base_end = addDelta(b.local_base_end, line_delta);
                } else {
                    // spans edit: only grow/shrink end
                    b.local_base_end = addDelta(b.local_base_end, line_delta);
                    if (b.local_base_end < b.local_base_start) b.local_base_end = b.local_base_start;
                }
            }
        }
    }
    for (bubbles) |*b| {
        if (b.id == except_id) continue;
        if (b.fragmentMut()) |f| {
            if (f.doc == doc) f.shift(edit_line, line_delta);
        }
    }
}

test "content bounds respects padding" {
    var b = Bubble{
        .id = 1,
        .bounds = .{ .x = 10, .y = 20, .w = 200, .h = 100 },
    };
    const c = b.contentBounds();
    try std.testing.expectApproxEqAbs(@as(f32, 18), c.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 42), c.y, 1e-5);
}

test "fragment range shift" {
    var f = FragmentView{ .doc = 1, .start_line = 10, .end_line = 20 };
    f.shift(5, 2);
    try std.testing.expectEqual(@as(u32, 12), f.start_line);
    try std.testing.expectEqual(@as(u32, 22), f.end_line);
    f.shift(15, -1);
    try std.testing.expectEqual(@as(u32, 12), f.start_line);
    try std.testing.expectEqual(@as(u32, 21), f.end_line);
}
