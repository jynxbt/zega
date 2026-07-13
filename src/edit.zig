//! Document editing through fragment bubbles — caret insert/delete + undo/redo + navigation.

const std = @import("std");
const doc_mod = @import("doc.zig");
const bubble_mod = @import("bubble.zig");
const canvas_mod = @import("canvas.zig");
const geom = @import("geom.zig");
const font_mod = @import("font.zig");
const text_mod = @import("text.zig");

pub const DocumentStore = doc_mod.DocumentStore;
pub const Canvas = canvas_mod.Canvas;
pub const Bubble = bubble_mod.Bubble;
pub const BubbleId = bubble_mod.BubbleId;
pub const Document = doc_mod.Document;

const UndoEntry = struct {
    doc: doc_mod.DocId,
    /// When not INVALID and the bubble is detached, undo applies to `local_text`.
    bubble: BubbleId = bubble_mod.INVALID_BUBBLE,
    offset: u32,
    /// Text that was removed (for undo of delete / redo of insert inverse).
    removed: []u8,
    /// Text that was inserted.
    inserted: []u8,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayListUnmanaged(UndoEntry) = .empty,
    redo_stack: std.ArrayListUnmanaged(UndoEntry) = .empty,
    max_undo: usize = 256,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        clearStack(&self.undo_stack, self.allocator);
        clearStack(&self.redo_stack, self.allocator);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    fn clearStack(stack: *std.ArrayListUnmanaged(UndoEntry), allocator: std.mem.Allocator) void {
        for (stack.items) |*e| {
            if (e.removed.len != 0) allocator.free(e.removed);
            if (e.inserted.len != 0) allocator.free(e.inserted);
        }
        stack.clearRetainingCapacity();
    }

    fn pushUndo(self: *Editor, entry: UndoEntry) !void {
        clearStack(&self.redo_stack, self.allocator);
        try self.undo_stack.append(self.allocator, entry);
        while (self.undo_stack.items.len > self.max_undo) {
            const old = self.undo_stack.orderedRemove(0);
            if (old.removed.len != 0) self.allocator.free(old.removed);
            if (old.inserted.len != 0) self.allocator.free(old.inserted);
        }
    }

    /// Copy fragment into a private buffer so further edits never touch siblings' saves.
    fn ensureDetached(self: *Editor, store: *DocumentStore, b: *Bubble) !void {
        if (b.local_text != null) return;
        const f = b.fragment() orelse return;
        const doc = store.getConst(f.doc) orelse return;
        const slice = doc.rangeSlice(f.start_line, f.end_line);
        b.local_text = try self.allocator.dupe(u8, slice);
        b.local_base_start = f.start_line;
        b.local_base_end = f.end_line;
    }

    /// Apply insert at caret of focused bubble (replaces selection if any).
    /// Fragment bubbles edit a detached local buffer so save is per-bubble.
    pub fn insertText(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
        text: []const u8,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        if (b.selection.active and !b.selection.isEmpty()) {
            try self.deleteSelection(store, canvas, bubble_id);
        }
        b.selection.clear();

        if (b.fragment() == null) {
            try insertIntoNote(self.allocator, b, text);
            b.dirty = true;
            return;
        }

        try self.ensureDetached(store, b);
        const local = b.local_text orelse return;
        b.dirty = true;

        const line = b.caret.line;
        const line_bytes = bubble_mod.lineSliceOf(local, line);
        const col = @min(b.caret.col, @as(u32, @intCast(line_bytes.len)));
        const offset = bubble_mod.offsetAtOf(local, line, col);

        // Grow local buffer.
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, local[0..offset]);
        try list.appendSlice(self.allocator, text);
        try list.appendSlice(self.allocator, local[offset..]);
        self.allocator.free(local);
        b.local_text = try list.toOwnedSlice(self.allocator);

        var nl: u32 = 0;
        var last_nl: ?usize = null;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                nl += 1;
                last_nl = i;
            }
        }
        if (nl > 0) {
            b.caret.line += nl;
            const after_last = if (last_nl) |p| text[p + 1 ..] else text;
            b.caret.col = @intCast(after_last.len);
        } else {
            b.caret.col += @intCast(text.len);
        }
        clampCaret(store, b);

        const ins_copy = try self.allocator.dupe(u8, text);
        try self.pushUndo(.{
            .doc = b.fragment().?.doc,
            .bubble = bubble_id,
            .offset = offset,
            .removed = &.{},
            .inserted = ins_copy,
        });
    }

    pub fn backspace(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        if (b.selection.active and !b.selection.isEmpty()) {
            try self.deleteSelection(store, canvas, bubble_id);
            return;
        }
        b.selection.clear();

        if (b.fragment() == null) {
            try backspaceNote(self.allocator, b);
            b.dirty = true;
            return;
        }
        if (b.caret.line == 0 and b.caret.col == 0) return;

        try self.ensureDetached(store, b);
        const local = b.local_text orelse return;
        const offset = bubble_mod.offsetAtOf(local, b.caret.line, b.caret.col);
        if (offset == 0) return;

        const del_off = offset - 1;
        const removed = try self.allocator.dupe(u8, local[del_off .. del_off + 1]);

        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, local[0..del_off]);
        try list.appendSlice(self.allocator, local[del_off + 1 ..]);
        self.allocator.free(local);
        b.local_text = try list.toOwnedSlice(self.allocator);
        b.dirty = true;

        if (b.caret.col > 0) {
            b.caret.col -= 1;
        } else if (b.caret.line > 0) {
            b.caret.line -= 1;
            const row = bubble_mod.lineSliceOf(b.local_text.?, b.caret.line);
            b.caret.col = @intCast(row.len);
        }
        clampCaret(store, b);

        try self.pushUndo(.{
            .doc = b.fragment().?.doc,
            .bubble = bubble_id,
            .offset = del_off,
            .removed = removed,
            .inserted = &.{},
        });
    }

    /// Place caret from a world-space click inside the bubble content area.
    pub fn placeCaretAtWorld(
        self: *Editor,
        store: *DocumentStore,
        b: *Bubble,
        world: geom.Vec2,
    ) void {
        b.selection.clear();
        const content = b.contentBounds();
        if (content.w < 1 or content.h < 1) return;

        const cw = font_mod.Font.charW();
        const ch = font_mod.Font.charH();
        const rel_x = world.x - content.x;
        const rel_y = world.y - content.y;
        if (rel_y < 0) return;

        const source = b.displayText(store);
        const max_cols = text_mod.maxColsForWidth(content.w);
        var lines: std.ArrayListUnmanaged(text_mod.DisplayLine) = .empty;
        defer lines.deinit(self.allocator);
        _ = text_mod.reflow(self.allocator, source, max_cols, &lines) catch {
            const line_f = rel_y / ch;
            const line: u32 = if (line_f < 0) 0 else @intFromFloat(@floor(line_f));
            const col_f = rel_x / cw;
            const col: u32 = if (col_f < 0) 0 else @intFromFloat(@floor(col_f));
            b.caret = .{ .line = line, .col = col };
            clampCaret(store, b);
            return;
        };

        if (lines.items.len == 0) {
            b.caret = .{};
            return;
        }
        const row_f = rel_y / ch;
        const row_i: i32 = if (row_f < 0) 0 else @intFromFloat(@floor(row_f));
        const row: usize = @min(@as(usize, @intCast(@max(row_i, 0))), lines.items.len - 1);
        const dl = lines.items[row];
        const col_f = rel_x / cw;
        var col_in_row: u32 = if (col_f < 0) 0 else @intFromFloat(@floor(col_f));
        if (col_in_row > dl.bytes.len) col_in_row = @intCast(dl.bytes.len);
        b.caret = .{
            .line = dl.logical_line,
            .col = dl.col_offset + col_in_row,
        };
        clampCaret(store, b);
    }

    /// Merge this bubble's local buffer into the shared document and write the file.
    /// Other bubbles' unsaved local buffers are left alone (not written).
    pub fn saveBubble(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return error.UnknownBubble;
        const f = b.fragment() orelse return error.NotAFragment;
        const doc = store.get(f.doc) orelse return error.UnknownDocument;

        // Nothing detached and not dirty: still write current document (flush).
        if (b.local_text == null) {
            try doc.save(store.io);
            b.dirty = false;
            return;
        }

        const local = b.local_text.?;
        const base_start = b.local_base_start;
        const base_end = b.local_base_end;

        const start_off: u32 = if (base_start < doc.lineCount())
            doc.lineStartOffset(base_start)
        else
            @intCast(doc.bytes.items.len);
        const end_off: u32 = if (base_end < doc.lineCount())
            doc.lineStartOffset(base_end)
        else
            @intCast(doc.bytes.items.len);

        const old_len = end_off -% start_off;
        try doc.bytes.replaceRange(self.allocator, start_off, old_len, local);
        try doc.rebuildLineIndex(self.allocator);
        doc.dirty = true;

        // Compute the new half-open end line from the byte just after the splice.
        // Do NOT use lineCountOf(local): a mid-file rangeSlice always ends with `\n`,
        // so lineCountOf over-counts by one empty line and every save expands the
        // bubble into the next fragment (neighbors shift, content bleeds together).
        const new_end_off: u32 = start_off + @as(u32, @intCast(local.len));
        const new_end_line: u32 = if (new_end_off >= doc.bytes.items.len)
            doc.lineCount()
        else
            doc.lineColAt(new_end_off).line;

        const line_delta: i32 = @as(i32, @intCast(new_end_line)) - @as(i32, @intCast(base_end));
        // Update this bubble's fragment range to match merged text.
        if (b.fragmentMut()) |fm| {
            fm.start_line = base_start;
            fm.end_line = new_end_line;
        }
        b.local_base_start = base_start;
        b.local_base_end = new_end_line;

        if (line_delta != 0) {
            // Shift other bubbles after the end of the old range.
            bubble_mod.shiftAllFragmentsExcept(
                canvas.bubbles.items,
                f.doc,
                base_end,
                line_delta,
                b.id,
            );
        }

        // Saving a whole-file buffer overwrites every line on disk. Drop other
        // fragment locals for this doc — they would fight the file on next save.
        const saved_whole_file = base_start == 0 and new_end_line >= doc.lineCount();
        if (saved_whole_file) {
            discardSiblingLocals(self.allocator, canvas.bubbles.items, b.id, f.doc);
        } else {
            // Method save: drop dirty [full] locals so the whole-file bubble
            // re-reads the document (includes this save, excludes other unsaved
            // methods' locals). Prevents a later [full] Cmd+S from undoing this save.
            dropFullLocals(self.allocator, canvas.bubbles.items, b.id, f.doc, doc.lineCount());
        }

        // Drop detach state — body now matches document fragment.
        b.clearLocal(self.allocator);
        try doc.save(store.io);
        b.dirty = false;
    }

    /// Clear detached state on sibling bubbles of the same document.
    fn discardSiblingLocals(
        allocator: std.mem.Allocator,
        bubbles: []Bubble,
        saved_id: BubbleId,
        doc_id: doc_mod.DocId,
    ) void {
        for (bubbles) |*other| {
            if (other.id == saved_id) continue;
            if (other.local_text == null) continue;
            const of = other.fragment() orelse continue;
            if (of.doc != doc_id) continue;
            other.clearLocal(allocator);
            other.dirty = false;
        }
    }

    /// Clear only whole-file / [full] detached buffers after a partial save.
    fn dropFullLocals(
        allocator: std.mem.Allocator,
        bubbles: []Bubble,
        saved_id: BubbleId,
        doc_id: doc_mod.DocId,
        doc_line_count: u32,
    ) void {
        for (bubbles) |*other| {
            if (other.id == saved_id) continue;
            if (other.local_text == null) continue;
            const of = other.fragment() orelse continue;
            if (of.doc != doc_id) continue;
            const covers_file = other.local_base_start == 0 and other.local_base_end >= doc_line_count;
            const titled_full = std.mem.startsWith(u8, other.title, "[full]");
            if (!covers_file and !titled_full) continue;
            other.clearLocal(allocator);
            other.dirty = false;
        }
    }

    /// Delete the active selection range (fragment-relative / local buffer).
    pub fn deleteSelection(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        if (!b.selection.active or b.selection.isEmpty()) return;
        if (b.fragment() == null) {
            b.selection.clear();
            return;
        }
        try self.ensureDetached(store, b);
        const local = b.local_text orelse return;
        const n = b.selection.normalized();
        const start_off = bubble_mod.offsetAtOf(local, n.sl, n.sc);
        const end_off = bubble_mod.offsetAtOf(local, n.el, n.ec);
        if (end_off <= start_off) {
            b.selection.clear();
            return;
        }
        const removed = try self.allocator.dupe(u8, local[start_off..end_off]);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, local[0..start_off]);
        try list.appendSlice(self.allocator, local[end_off..]);
        self.allocator.free(local);
        b.local_text = try list.toOwnedSlice(self.allocator);
        b.dirty = true;
        b.caret = .{ .line = n.sl, .col = n.sc };
        b.selection.clear();
        try self.pushUndo(.{
            .doc = b.fragment().?.doc,
            .bubble = bubble_id,
            .offset = start_off,
            .removed = removed,
            .inserted = &.{},
        });
    }

    // --- Navigation ---

    pub fn moveLeft(canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        if (b.caret.col > 0) {
            b.caret.col -= 1;
        } else if (b.caret.line > 0) {
            b.caret.line -= 1;
            b.caret.col = std.math.maxInt(u32);
        }
    }

    fn bodyLine(store: *DocumentStore, b: *const Bubble, line: u32) []const u8 {
        if (b.local_text) |lt| return bubble_mod.lineSliceOf(lt, line);
        const f = b.fragment() orelse return &.{};
        const doc = store.getConst(f.doc) orelse return &.{};
        const abs = f.start_line + line;
        if (abs >= doc.lineCount()) return &.{};
        return doc.lineSlice(abs);
    }

    fn bodyLines(store: *DocumentStore, b: *const Bubble) u32 {
        return b.bodyLineCount(store);
    }

    pub fn moveRight(store: *DocumentStore, canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        clampCaret(store, b);
        const row = bodyLine(store, b, b.caret.line);
        const len: u32 = @intCast(row.len);
        const col = @min(b.caret.col, len);
        if (col < len) {
            b.caret.col = col + 1;
        } else if (b.caret.line + 1 < bodyLines(store, b)) {
            b.caret.line += 1;
            b.caret.col = 0;
        }
    }

    pub fn moveUp(canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        if (b.caret.line > 0) b.caret.line -= 1;
    }

    pub fn moveDown(canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        // bodyLines needs store — use fragment/local only
        const n = if (b.local_text) |lt|
            bubble_mod.lineCountOf(lt)
        else if (b.fragment()) |f|
            f.lineCount()
        else
            @as(u32, 1);
        if (b.caret.line + 1 < n) b.caret.line += 1;
    }

    pub fn moveWordLeft(store: *DocumentStore, canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        clampCaret(store, b);
        var line = b.caret.line;
        var col = b.caret.col;
        if (col == 0) {
            if (line == 0) return;
            line -= 1;
            col = @intCast(bodyLine(store, b, line).len);
        } else {
            const row = bodyLine(store, b, line);
            col = wordLeftCol(row, col);
        }
        b.caret.line = line;
        b.caret.col = col;
    }

    pub fn moveWordRight(store: *DocumentStore, canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        clampCaret(store, b);
        const row = bodyLine(store, b, b.caret.line);
        const len: u32 = @intCast(row.len);
        var col = @min(b.caret.col, len);
        if (col >= len) {
            if (b.caret.line + 1 < bodyLines(store, b)) {
                b.caret.line += 1;
                b.caret.col = 0;
            }
            return;
        }
        col = wordRightCol(row, col);
        b.caret.col = col;
    }

    pub fn moveLineStart(canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        b.caret.col = 0;
    }

    pub fn moveLineEnd(store: *DocumentStore, canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        clampCaret(store, b);
        b.caret.col = @intCast(bodyLine(store, b, b.caret.line).len);
    }

    pub fn moveBubbleStart(canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        b.caret = .{ .line = 0, .col = 0 };
    }

    pub fn moveBubbleEnd(store: *DocumentStore, canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        const n = bodyLines(store, b);
        if (n == 0) {
            b.caret = .{};
            return;
        }
        b.caret.line = n - 1;
        b.caret.col = @intCast(bodyLine(store, b, b.caret.line).len);
    }

    pub fn selectAll(store: *DocumentStore, canvas: *Canvas, bubble_id: BubbleId) void {
        const b = canvas.findBubble(bubble_id) orelse return;
        const f = b.fragment() orelse {
            // Note: select entire buffer as single line.
            b.selection = .{
                .active = true,
                .a_line = 0,
                .a_col = 0,
                .b_line = 0,
                .b_col = @intCast(b.text.len),
            };
            b.caret = .{ .line = 0, .col = @intCast(b.text.len) };
            return;
        };
        if (f.lineCount() == 0) {
            b.selection = .{ .active = true };
            b.caret = .{};
            return;
        }
        const doc = store.getConst(f.doc) orelse return;
        const last_rel = f.lineCount() - 1;
        const last_abs = f.start_line + last_rel;
        const end_col: u32 = if (last_abs < doc.lineCount())
            @intCast(doc.lineSlice(last_abs).len)
        else
            0;
        b.selection = .{
            .active = true,
            .a_line = 0,
            .a_col = 0,
            .b_line = last_rel,
            .b_col = end_col,
        };
        b.caret = .{ .line = last_rel, .col = end_col };
    }

    // --- Word / line deletes ---

    pub fn deleteWordBackward(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        if (b.selection.active and !b.selection.isEmpty()) {
            try self.deleteSelection(store, canvas, bubble_id);
            return;
        }
        const f = b.fragment() orelse return;
        _ = store.get(f.doc) orelse return;
        clampCaret(store, b);
        const start_line = b.caret.line;
        const start_col = b.caret.col;
        moveWordLeft(store, canvas, bubble_id);
        clampCaret(store, b);
        if (b.caret.line == start_line and b.caret.col == start_col) return;
        try self.deleteRangeRel(store, canvas, b, f.doc, f.start_line, b.caret.line, b.caret.col, start_line, start_col);
    }

    pub fn deleteWordForward(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        if (b.selection.active and !b.selection.isEmpty()) {
            try self.deleteSelection(store, canvas, bubble_id);
            return;
        }
        const f = b.fragment() orelse return;
        _ = store.get(f.doc) orelse return;
        clampCaret(store, b);
        const start_line = b.caret.line;
        const start_col = b.caret.col;
        // peek right without clearing — moveWordRight clears selection only
        moveWordRight(store, canvas, bubble_id);
        clampCaret(store, b);
        if (b.caret.line == start_line and b.caret.col == start_col) return;
        const end_line = b.caret.line;
        const end_col = b.caret.col;
        b.caret = .{ .line = start_line, .col = start_col };
        try self.deleteRangeRel(store, canvas, b, f.doc, f.start_line, start_line, start_col, end_line, end_col);
    }

    /// Delete from column 0 to caret on current line (⌘+Backspace).
    pub fn deleteToLineStart(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        const f = b.fragment() orelse return;
        clampCaret(store, b);
        if (b.caret.col == 0) return;
        try self.deleteRangeRel(store, canvas, b, f.doc, f.start_line, b.caret.line, 0, b.caret.line, b.caret.col);
        b.caret.col = 0;
    }

    /// Delete entire current line in the bubble body (⌘+Shift+K).
    pub fn deleteLine(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        if (b.fragment() == null) return;
        try self.ensureDetached(store, b);
        clampCaret(store, b);
        const local = b.local_text orelse return;
        const lc = bubble_mod.lineCountOf(local);
        if (lc == 0) return;
        const line = b.caret.line;
        const start_off = bubble_mod.offsetAtOf(local, line, 0);
        const end_off: u32 = if (line + 1 < lc)
            bubble_mod.offsetAtOf(local, line + 1, 0)
        else
            @intCast(local.len);
        if (end_off <= start_off) return;
        b.dirty = true;
        const removed = try self.allocator.dupe(u8, local[start_off..end_off]);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, local[0..start_off]);
        try list.appendSlice(self.allocator, local[end_off..]);
        self.allocator.free(local);
        b.local_text = try list.toOwnedSlice(self.allocator);
        const new_lc = bubble_mod.lineCountOf(b.local_text.?);
        if (new_lc == 0) {
            b.caret = .{};
        } else if (b.caret.line >= new_lc) {
            b.caret.line = new_lc - 1;
            b.caret.col = 0;
        } else {
            b.caret.col = 0;
        }
        try self.pushUndo(.{
            .doc = b.fragment().?.doc,
            .bubble = bubble_id,
            .offset = start_off,
            .removed = removed,
            .inserted = &.{},
        });
    }

    pub fn duplicateLine(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        if (b.fragment() == null) return;
        try self.ensureDetached(store, b);
        clampCaret(store, b);
        const local = b.local_text orelse return;
        const row = bubble_mod.lineSliceOf(local, b.caret.line);
        const insert_at = bubble_mod.offsetAtOf(local, b.caret.line, @intCast(row.len));
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.append(self.allocator, '\n');
        try buf.appendSlice(self.allocator, row);

        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, local[0..insert_at]);
        try list.appendSlice(self.allocator, buf.items);
        try list.appendSlice(self.allocator, local[insert_at..]);
        self.allocator.free(local);
        b.local_text = try list.toOwnedSlice(self.allocator);
        b.dirty = true;
        b.caret.line += 1;
        const ins_copy = try self.allocator.dupe(u8, buf.items);
        try self.pushUndo(.{
            .doc = b.fragment().?.doc,
            .bubble = bubble_id,
            .offset = insert_at,
            .removed = &.{},
            .inserted = ins_copy,
        });
    }

    pub fn moveLineUp(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        if (b.caret.line == 0) return;
        if (b.fragment() == null) return;
        try self.ensureDetached(store, b);
        try self.swapLocalLines(b, b.caret.line - 1, b.caret.line);
        b.caret.line -= 1;
        b.dirty = true;
    }

    pub fn moveLineDown(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        bubble_id: BubbleId,
    ) !void {
        const b = canvas.findBubble(bubble_id) orelse return;
        b.selection.clear();
        if (b.fragment() == null) return;
        try self.ensureDetached(store, b);
        const n = bubble_mod.lineCountOf(b.local_text orelse return);
        if (b.caret.line + 1 >= n) return;
        try self.swapLocalLines(b, b.caret.line, b.caret.line + 1);
        b.caret.line += 1;
        b.dirty = true;
    }

    fn swapLocalLines(self: *Editor, b: *Bubble, line_a: u32, line_b: u32) !void {
        const local = b.local_text orelse return;
        if (line_b != line_a + 1) return;
        const a = bubble_mod.lineSliceOf(local, line_a);
        const c = bubble_mod.lineSliceOf(local, line_b);
        const start = bubble_mod.offsetAtOf(local, line_a, 0);
        const end: u32 = if (line_b + 1 < bubble_mod.lineCountOf(local))
            bubble_mod.offsetAtOf(local, line_b + 1, 0)
        else
            @intCast(local.len);

        var new_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer new_buf.deinit(self.allocator);
        try new_buf.appendSlice(self.allocator, local[0..start]);
        try new_buf.appendSlice(self.allocator, c);
        try new_buf.append(self.allocator, '\n');
        try new_buf.appendSlice(self.allocator, a);
        if (end < local.len or (end > 0 and local[end - 1] == '\n')) {
            if (new_buf.items.len == 0 or new_buf.items[new_buf.items.len - 1] != '\n')
                try new_buf.append(self.allocator, '\n');
        }
        try new_buf.appendSlice(self.allocator, local[end..]);
        self.allocator.free(local);
        b.local_text = try new_buf.toOwnedSlice(self.allocator);
    }

    fn deleteRangeRel(
        self: *Editor,
        store: *DocumentStore,
        canvas: *Canvas,
        b: *Bubble,
        doc_id: doc_mod.DocId,
        frag_start: u32,
        sl: u32,
        sc: u32,
        el: u32,
        ec: u32,
    ) !void {
        _ = canvas;
        _ = frag_start;
        try self.ensureDetached(store, b);
        const local = b.local_text orelse return;
        const start_off = bubble_mod.offsetAtOf(local, sl, sc);
        const end_off = bubble_mod.offsetAtOf(local, el, ec);
        if (end_off <= start_off) return;
        b.dirty = true;
        const removed = try self.allocator.dupe(u8, local[start_off..end_off]);
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, local[0..start_off]);
        try list.appendSlice(self.allocator, local[end_off..]);
        self.allocator.free(local);
        b.local_text = try list.toOwnedSlice(self.allocator);
        b.caret = .{ .line = sl, .col = sc };
        b.selection.clear();
        try self.pushUndo(.{
            .doc = doc_id,
            .bubble = b.id,
            .offset = start_off,
            .removed = removed,
            .inserted = &.{},
        });
    }

    pub fn clampCaret(store: *DocumentStore, b: *Bubble) void {
        if (b.local_text) |lt| {
            const lc = bubble_mod.lineCountOf(lt);
            if (lc == 0) {
                b.caret = .{};
                return;
            }
            if (b.caret.line >= lc) b.caret.line = lc - 1;
            const row = bubble_mod.lineSliceOf(lt, b.caret.line);
            if (b.caret.col > row.len) b.caret.col = @intCast(row.len);
            return;
        }
        const f = b.fragment() orelse return;
        const doc = store.getConst(f.doc) orelse return;
        if (f.lineCount() == 0) {
            b.caret = .{};
            return;
        }
        if (b.caret.line >= f.lineCount()) b.caret.line = f.lineCount() - 1;
        const abs = f.start_line + b.caret.line;
        if (abs >= doc.lineCount()) {
            b.caret.line = 0;
            b.caret.col = 0;
            return;
        }
        const len: u32 = @intCast(doc.lineSlice(abs).len);
        if (b.caret.col > len) b.caret.col = len;
    }

    pub fn undo(self: *Editor, store: *DocumentStore, canvas: *Canvas) !void {
        const entry = self.undo_stack.pop() orelse return;
        defer {
            if (entry.removed.len != 0) self.allocator.free(entry.removed);
            if (entry.inserted.len != 0) self.allocator.free(entry.inserted);
        }
        try applyInverse(self.allocator, store, canvas, entry);
        const inv = UndoEntry{
            .doc = entry.doc,
            .offset = entry.offset,
            .removed = try self.allocator.dupe(u8, entry.inserted),
            .inserted = try self.allocator.dupe(u8, entry.removed),
        };
        try self.redo_stack.append(self.allocator, inv);
    }

    pub fn redo(self: *Editor, store: *DocumentStore, canvas: *Canvas) !void {
        const entry = self.redo_stack.pop() orelse return;
        defer {
            if (entry.removed.len != 0) self.allocator.free(entry.removed);
            if (entry.inserted.len != 0) self.allocator.free(entry.inserted);
        }
        // entry is already the inverse of what undo produced — applying it like undo restores.
        try applyInverse(self.allocator, store, canvas, entry);
        const inv = UndoEntry{
            .doc = entry.doc,
            .offset = entry.offset,
            .removed = try self.allocator.dupe(u8, entry.inserted),
            .inserted = try self.allocator.dupe(u8, entry.removed),
        };
        // Push back onto undo without clearing redo.
        try self.undo_stack.append(self.allocator, inv);
        while (self.undo_stack.items.len > self.max_undo) {
            const old = self.undo_stack.orderedRemove(0);
            if (old.removed.len != 0) self.allocator.free(old.removed);
            if (old.inserted.len != 0) self.allocator.free(old.inserted);
        }
    }
};

fn applyInverse(
    allocator: std.mem.Allocator,
    store: *DocumentStore,
    canvas: *Canvas,
    entry: UndoEntry,
) !void {
    // Detached bubble undo — mutate local_text only (never the shared document).
    if (entry.bubble != bubble_mod.INVALID_BUBBLE) {
        if (canvas.findBubble(entry.bubble)) |b| {
            if (b.local_text) |local| {
                const off = @min(entry.offset, @as(u32, @intCast(local.len)));
                var list: std.ArrayListUnmanaged(u8) = .empty;
                defer list.deinit(allocator);
                try list.appendSlice(allocator, local[0..off]);
                // Inverse: remove what was inserted, re-insert what was removed.
                const after_ins = off + @as(u32, @intCast(entry.inserted.len));
                const tail_start = @min(after_ins, @as(u32, @intCast(local.len)));
                if (entry.removed.len > 0) try list.appendSlice(allocator, entry.removed);
                try list.appendSlice(allocator, local[tail_start..]);
                allocator.free(local);
                b.local_text = try list.toOwnedSlice(allocator);
                b.dirty = true;
                return;
            }
        }
    }

    const doc = store.get(entry.doc) orelse return;
    const before = doc.lineCount();
    if (entry.inserted.len > 0) {
        try doc.delete(allocator, entry.offset, @intCast(entry.inserted.len));
    }
    if (entry.removed.len > 0) {
        try doc.insert(allocator, entry.offset, entry.removed);
    }
    const after = doc.lineCount();
    const line_delta: i32 = @as(i32, @intCast(after)) - @as(i32, @intCast(before));
    if (line_delta != 0) {
        const lc = doc.lineColAt(entry.offset);
        bubble_mod.shiftAllFragments(canvas.bubbles.items, entry.doc, lc.line, line_delta);
    }
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Caret is before `col`; move to start of previous word on this line.
pub fn wordLeftCol(line: []const u8, col: u32) u32 {
    var c: usize = @min(@as(usize, col), line.len);
    if (c == 0) return 0;
    c -= 1;
    while (c > 0 and !isWordChar(line[c])) : (c -= 1) {}
    if (!isWordChar(line[c])) return @intCast(c);
    while (c > 0 and isWordChar(line[c - 1])) : (c -= 1) {}
    return @intCast(c);
}

/// Caret is before `col`; move to end of next word on this line.
pub fn wordRightCol(line: []const u8, col: u32) u32 {
    var c: usize = @min(@as(usize, col), line.len);
    const len = line.len;
    if (c >= len) return @intCast(len);
    if (isWordChar(line[c])) {
        while (c < len and isWordChar(line[c])) : (c += 1) {}
    } else {
        while (c < len and !isWordChar(line[c])) : (c += 1) {}
        while (c < len and isWordChar(line[c])) : (c += 1) {}
    }
    return @intCast(c);
}

fn insertIntoNote(allocator: std.mem.Allocator, b: *Bubble, text: []const u8) !void {
    const col = @min(b.caret.col, @as(u32, @intCast(b.text.len)));
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, b.text[0..col]);
    try list.appendSlice(allocator, text);
    try list.appendSlice(allocator, b.text[col..]);
    if (b.text.len != 0) allocator.free(b.text);
    b.text = try list.toOwnedSlice(allocator);
    b.caret.col = col + @as(u32, @intCast(text.len));
}

fn backspaceNote(allocator: std.mem.Allocator, b: *Bubble) !void {
    if (b.caret.col == 0 or b.text.len == 0) return;
    const col = @min(b.caret.col, @as(u32, @intCast(b.text.len)));
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, b.text[0 .. col - 1]);
    try list.appendSlice(allocator, b.text[col..]);
    if (b.text.len != 0) allocator.free(b.text);
    b.text = try list.toOwnedSlice(allocator);
    b.caret.col = col - 1;
}

// --- tests ---

test "placeCaretAtWorld accounts for soft-wrapped first line" {
    // First logical line wraps → visual row 2 is logical line 1, not line 2.
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    // Long first line + short second line.
    var long_buf: [120]u8 = undefined;
    @memset(long_buf[0..80], 'x');
    const src = try std.fmt.bufPrint(&long_buf, "{s}\ntarget_here\n", .{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"});
    // simpler fixed source:
    _ = src;
    const text =
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        \\TARGET
        \\
    ;
    const id = try store.openScratch("wrap.zig", text, .zig);
    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    const bid = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    const b = canvas.findBubble(bid).?;
    b.setFragment(id, 0, 3);
    b.pad_x = 8;
    b.pad_y = 22;

    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();

    const content = b.contentBounds();
    const ch = font_mod.Font.charH();
    const cw = font_mod.Font.charW();
    const max_cols = text_mod.maxColsForWidth(content.w);
    // With narrow bubble, first line must wrap at least once.
    try std.testing.expect(max_cols < 50);

    var lines: std.ArrayListUnmanaged(text_mod.DisplayLine) = .empty;
    defer lines.deinit(std.testing.allocator);
    _ = try text_mod.reflow(std.testing.allocator, text, max_cols, &lines);
    try std.testing.expect(lines.items.len >= 3);

    // Find display row of "TARGET" (logical line 1).
    var target_row: ?usize = null;
    for (lines.items, 0..) |dl, i| {
        if (dl.logical_line == 1 and !dl.wrap_continuation) {
            target_row = i;
            break;
        }
    }
    const row = target_row orelse return error.TestUnexpectedResult;
    // Click middle of "TARGET" on that visual row.
    const world = geom.Vec2{
        .x = content.x + cw * 3.0,
        .y = content.y + ch * (@as(f32, @floatFromInt(row)) + 0.5),
    };
    ed.placeCaretAtWorld(&store, b, world);
    try std.testing.expectEqual(@as(u32, 1), b.caret.line);
    // col should be near 3 on TARGET
    try std.testing.expect(b.caret.col >= 2 and b.caret.col <= 4);
}

test "wordLeftCol and wordRightCol" {
    const line = "foo_bar  baz";
    // caret after bar → jump to start of foo_bar
    try std.testing.expectEqual(@as(u32, 0), wordLeftCol(line, 7));
    // caret at start of spaces after bar
    try std.testing.expectEqual(@as(u32, 0), wordLeftCol(line, 8));
    // caret at baz end
    try std.testing.expectEqual(@as(u32, 9), wordLeftCol(line, 12));
    // word right from 0
    try std.testing.expectEqual(@as(u32, 7), wordRightCol(line, 0));
    // from after bar
    try std.testing.expectEqual(@as(u32, 12), wordRightCol(line, 7));
}

test "insert detaches from shared document" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const id = try store.openScratch("t.zig", "ab\ncd\n", .zig);
    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    const bid = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const b = canvas.findBubble(bid).?;
    b.setFragment(id, 0, 1); // only first line "ab\n" or "ab"
    b.caret = .{ .line = 0, .col = 2 };

    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText(&store, &canvas, bid, "X");
    // Shared document stays unchanged until save.
    try std.testing.expectEqualStrings("ab", store.get(id).?.lineSlice(0));
    // Bubble body shows the edit.
    try std.testing.expect(std.mem.indexOf(u8, b.displayText(&store), "abX") != null);
    try std.testing.expect(b.dirty);
    try std.testing.expect(b.local_text != null);
}

test "saveBubble merges only this bubble" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const id = try store.openScratch("pair.zig", "aaa\nbbb\n", .zig);
    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    const a_id = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const b_id = try canvas.addBubble(.code, .{ .x = 120, .y = 0, .w = 100, .h = 40 });
    const ba = canvas.findBubble(a_id).?;
    const bb = canvas.findBubble(b_id).?;
    ba.setFragment(id, 0, 1);
    bb.setFragment(id, 1, 2);
    ba.caret = .{ .line = 0, .col = 3 };
    bb.caret = .{ .line = 0, .col = 3 };

    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText(&store, &canvas, a_id, "A");
    try ed.insertText(&store, &canvas, b_id, "B");
    try std.testing.expectEqualStrings("aaa", store.get(id).?.lineSlice(0));
    try std.testing.expectEqualStrings("bbb", store.get(id).?.lineSlice(1));

    const probe = "src/testdata/_pair_save.zig";
    const d = store.get(id).?;
    store.allocator.free(d.path);
    d.path = try store.allocator.dupe(u8, probe);

    try ed.saveBubble(&store, &canvas, a_id);
    try std.testing.expect(!ba.dirty);
    try std.testing.expect(bb.dirty); // B still unsaved
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.bytes.items, "aaaA") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.bytes.items, "bbbB") == null);
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.bytes.items, "bbb") != null);
    // Ranges must stay line-accurate (no +1 bleed into neighbor from trailing `\n`).
    try std.testing.expectEqual(@as(u32, 0), ba.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 1), ba.fragment().?.end_line);
    try std.testing.expectEqual(@as(u32, 1), bb.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 2), bb.fragment().?.end_line);
    try std.testing.expectEqualStrings("aaaA", store.get(id).?.lineSlice(0));
    try std.testing.expectEqualStrings("bbb", store.get(id).?.lineSlice(1));

    std.Io.Dir.cwd().deleteFile(std.testing.io, probe) catch {};
}

test "save mid-file bubble without newline insert keeps range" {
    // Regression: rangeSlice for mid-file fragments ends with `\n`; lineCountOf
    // overcounts by 1 and used to expand the bubble into the next function on save.
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const original =
        \\fn a() void {
        \\    const x = 1;
        \\}
        \\fn b() void {
        \\    const y = 2;
        \\}
        \\fn c() void {
        \\    const z = 3;
        \\}
        \\
    ;
    const path = "src/testdata/_range_save.zig";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const id = try store.openOrCreate(path, original);
    {
        const d = store.get(id).?;
        d.bytes.clearRetainingCapacity();
        try d.bytes.appendSlice(std.testing.allocator, original);
        try d.rebuildLineIndex(std.testing.allocator);
        d.dirty = false;
    }

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    // a:0-3, b:3-6, c:6-9 (half-open)
    const a_id = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const b_id = try canvas.addBubble(.code, .{ .x = 120, .y = 0, .w = 100, .h = 40 });
    const c_id = try canvas.addBubble(.code, .{ .x = 240, .y = 0, .w = 100, .h = 40 });
    const ba = canvas.findBubble(a_id).?;
    const bb = canvas.findBubble(b_id).?;
    const bc = canvas.findBubble(c_id).?;
    ba.setFragment(id, 0, 3);
    bb.setFragment(id, 3, 6);
    bc.setFragment(id, 6, 9);
    // Same-line edit (no new lines) in the middle bubble.
    bb.caret = .{ .line = 1, .col = 4 };
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText(&store, &canvas, b_id, "EDIT_");
    try ed.saveBubble(&store, &canvas, b_id);

    // B must still be exactly 3 lines; neighbors unshifted.
    try std.testing.expectEqual(@as(u32, 0), ba.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 3), ba.fragment().?.end_line);
    try std.testing.expectEqual(@as(u32, 3), bb.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 6), bb.fragment().?.end_line);
    try std.testing.expectEqual(@as(u32, 6), bc.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 9), bc.fragment().?.end_line);

    const body_b = store.get(id).?.rangeSlice(3, 6);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "EDIT_") != null);
    try std.testing.expect(std.mem.indexOf(u8, body_b, "fn c") == null);
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.rangeSlice(0, 3), "fn a") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.rangeSlice(6, 9), "fn c") != null);
    // B display after save must not swallow c.
    try std.testing.expect(std.mem.indexOf(u8, bb.displayText(&store), "fn c") == null);
    try std.testing.expect(std.mem.indexOf(u8, bb.displayText(&store), "EDIT_") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "save with inserted newline shifts only following bubbles" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const original =
        \\fn a() void {
        \\    x
        \\}
        \\fn b() void {
        \\    y
        \\}
        \\
    ;
    const path = "src/testdata/_nl_save.zig";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const id = try store.openOrCreate(path, original);
    {
        const d = store.get(id).?;
        d.bytes.clearRetainingCapacity();
        try d.bytes.appendSlice(std.testing.allocator, original);
        try d.rebuildLineIndex(std.testing.allocator);
        d.dirty = false;
    }
    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    const a_id = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const b_id = try canvas.addBubble(.code, .{ .x = 120, .y = 0, .w = 100, .h = 40 });
    const ba = canvas.findBubble(a_id).?;
    const bb = canvas.findBubble(b_id).?;
    ba.setFragment(id, 0, 3);
    bb.setFragment(id, 3, 6);
    ba.caret = .{ .line = 1, .col = 5 };
    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText(&store, &canvas, a_id, "\n    z");
    try ed.saveBubble(&store, &canvas, a_id);

    try std.testing.expectEqual(@as(u32, 0), ba.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 4), ba.fragment().?.end_line);
    try std.testing.expectEqual(@as(u32, 4), bb.fragment().?.start_line);
    try std.testing.expectEqual(@as(u32, 7), bb.fragment().?.end_line);
    try std.testing.expect(std.mem.indexOf(u8, ba.displayText(&store), "fn b") == null);
    try std.testing.expect(std.mem.indexOf(u8, bb.displayText(&store), "fn b") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "save method does not write sibling; drops conflicting full local" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const original =
        \\fn a() void {
        \\    const x = 1;
        \\}
        \\fn b() void {
        \\    const y = 2;
        \\}
        \\
    ;
    const path = "testdata/_indep_ab.zig";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const id = try store.openOrCreate(path, original);
    {
        const d = store.get(id).?;
        d.bytes.clearRetainingCapacity();
        try d.bytes.appendSlice(std.testing.allocator, original);
        try d.rebuildLineIndex(std.testing.allocator);
        d.dirty = false;
    }

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    const full_id = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const a_id = try canvas.addBubble(.code, .{ .x = 120, .y = 0, .w = 100, .h = 40 });
    const b_id = try canvas.addBubble(.code, .{ .x = 240, .y = 0, .w = 100, .h = 40 });
    const full = canvas.findBubble(full_id).?;
    const ba = canvas.findBubble(a_id).?;
    const bb = canvas.findBubble(b_id).?;
    full.setFragment(id, 0, store.get(id).?.lineCount());
    try full.setTitleOwned(std.testing.allocator, "[full] t.zig");
    ba.setFragment(id, 0, 3);
    bb.setFragment(id, 3, 6);

    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    full.caret = .{ .line = 0, .col = 0 };
    try ed.insertText(&store, &canvas, full_id, "//FULL\n");
    ba.caret = .{ .line = 1, .col = 4 };
    try ed.insertText(&store, &canvas, a_id, "A_");
    bb.caret = .{ .line = 1, .col = 4 };
    try ed.insertText(&store, &canvas, b_id, "B_");

    try ed.saveBubble(&store, &canvas, a_id);
    try std.testing.expect(!ba.dirty);
    try std.testing.expect(bb.dirty);
    // [full] local dropped so it re-reads doc (has A_, not B_).
    try std.testing.expect(!full.dirty);
    try std.testing.expect(full.local_text == null);
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.bytes.items, "A_") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.get(id).?.bytes.items, "B_") == null);
    try std.testing.expect(std.mem.indexOf(u8, full.displayText(&store), "A_") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.displayText(&store), "B_") == null);
    // B still has its own unsaved buffer.
    try std.testing.expect(std.mem.indexOf(u8, bb.displayText(&store), "B_") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "middle fragment save keeps neighbors on disk" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const original =
        \\line0
        \\line1
        \\fn middle() void {
        \\    const y = 2;
        \\}
        \\line_after
        \\
    ;
    const path = "src/testdata/_middle_save.zig";
    // Fresh file every run.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const id = try store.openOrCreate(path, original);
    {
        const d = store.get(id).?;
        d.bytes.clearRetainingCapacity();
        try d.bytes.appendSlice(std.testing.allocator, original);
        try d.rebuildLineIndex(std.testing.allocator);
        d.dirty = false;
    }

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    // lines: 0 line0, 1 line1, 2 fn middle, 3 const, 4 }, 5 line_after
    const mid_id = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 40 });
    const mid = canvas.findBubble(mid_id).?;
    mid.setFragment(id, 2, 5);
    mid.caret = .{ .line = 1, .col = 4 };

    var ed = Editor.init(std.testing.allocator);
    defer ed.deinit();
    try ed.insertText(&store, &canvas, mid_id, "EDIT_");
    try ed.saveBubble(&store, &canvas, mid_id);

    const after = store.get(id).?.bytes.items;
    try std.testing.expect(std.mem.indexOf(u8, after, "line0") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "EDIT_") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "line_after") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "fn middle") != null);

    // Read back from disk without relying on readFileAlloc signature.
    const re = try store.openFile(path);
    // openFile returns existing id if same abs path — re-get bytes
    _ = re;
    const disk_doc = store.get(id).?;
    try std.testing.expect(std.mem.indexOf(u8, disk_doc.bytes.items, "EDIT_") != null);
    try std.testing.expect(std.mem.indexOf(u8, disk_doc.bytes.items, "line0") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}
