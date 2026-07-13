//! Nested bracket pair colorization (Bracket Pair Colorizer 2 style).
//! Matching (), [], {} share a depth color; strings/comments are ignored.

const std = @import("std");

pub const palette_len: u8 = 3;

pub const Rgb = struct { r: f32, g: f32, b: f32 };

/// BPC2-style default colors (linear 0–1 RGB).
pub const palette = [_]Rgb{
    .{ .r = 1.00, .g = 0.843, .b = 0.00 }, // Gold #FFD700
    .{ .r = 0.855, .g = 0.439, .b = 0.839 }, // Orchid #DA70D6
    .{ .r = 0.529, .g = 0.808, .b = 0.980 }, // LightSkyBlue #87CEFA
};

pub const unmatched_color = Rgb{ .r = 0.95, .g = 0.40, .b = 0.40 };

pub const BracketKind = enum { paren, bracket, brace };

pub const BracketEntry = struct {
    /// Byte offset of this glyph in the scanned text.
    offset: u32,
    /// Matching partner offset, or maxInt if unmatched.
    pair_off: u32 = std.math.maxInt(u32),
    /// Nesting depth (0 = outermost).
    depth: u8 = 0,
    kind: BracketKind = .paren,
    is_open: bool = true,
    unmatched: bool = false,

    pub fn colorIndex(self: BracketEntry) u8 {
        return self.depth % palette_len;
    }
};

pub const PairRef = struct {
    open: u32,
    close: u32,
    depth: u8,
};

/// Compact index of all bracket glyphs in a document.
pub const BracketIndex = struct {
    allocator: std.mem.Allocator,
    /// Sorted by offset for binary search.
    entries: []BracketEntry = &.{},

    pub fn deinit(self: *BracketIndex) void {
        if (self.entries.len != 0) self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn entryAt(self: *const BracketIndex, offset: u32) ?BracketEntry {
        const i = binarySearch(self.entries, offset) orelse return null;
        return self.entries[i];
    }

    pub fn colorIndexAt(self: *const BracketIndex, offset: u32) ?u8 {
        const e = self.entryAt(offset) orelse return null;
        if (e.unmatched and !e.is_open) return null; // use unmatched paint in renderer
        return e.colorIndex();
    }

    /// If `offset` is on a bracket (or the partner), return both ends.
    pub fn pairAt(self: *const BracketIndex, offset: u32) ?PairRef {
        const e = self.entryAt(offset) orelse return null;
        if (e.pair_off == std.math.maxInt(u32)) {
            if (e.is_open) return .{ .open = e.offset, .close = std.math.maxInt(u32), .depth = e.depth };
            return .{ .open = std.math.maxInt(u32), .close = e.offset, .depth = e.depth };
        }
        if (e.is_open) return .{ .open = e.offset, .close = e.pair_off, .depth = e.depth };
        return .{ .open = e.pair_off, .close = e.offset, .depth = e.depth };
    }

    /// Prefer exact offset; else nearest bracket within ±1 byte
    /// (caret often sits after the glyph).
    pub fn pairNear(self: *const BracketIndex, offset: u32) ?PairRef {
        if (self.pairAt(offset)) |p| return p;
        if (offset > 0) {
            if (self.pairAt(offset - 1)) |p| return p;
        }
        return self.pairAt(offset +% 1);
    }
};

fn binarySearch(entries: []const BracketEntry, offset: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].offset < offset) lo = mid + 1 else hi = mid;
    }
    if (lo < entries.len and entries[lo].offset == offset) return lo;
    return null;
}

fn kindOf(ch: u8) ?BracketKind {
    return switch (ch) {
        '(', ')' => .paren,
        '[', ']' => .bracket,
        '{', '}' => .brace,
        else => null,
    };
}

fn isOpen(ch: u8) bool {
    return ch == '(' or ch == '[' or ch == '{';
}

fn matches(open_ch: u8, close_ch: u8) bool {
    return switch (open_ch) {
        '(' => close_ch == ')',
        '[' => close_ch == ']',
        '{' => close_ch == '}',
        else => false,
    };
}

/// Build a bracket index for `text` (full document bytes recommended).
pub fn build(allocator: std.mem.Allocator, text: []const u8) !BracketIndex {
    var list: std.ArrayListUnmanaged(BracketEntry) = .empty;
    errdefer list.deinit(allocator);

    // Stack of openers: entry index into `list` + opener char
    var stack: std.ArrayListUnmanaged(struct { list_idx: u32, ch: u8 }) = .empty;
    defer stack.deinit(allocator);

    var i: usize = 0;
    var in_str = false;
    var in_char = false;
    var in_line_comment = false;
    var in_block_comment = false;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        const n = if (i + 1 < text.len) text[i + 1] else 0;

        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and n == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_str) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (in_char) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == '\'') in_char = false;
            continue;
        }

        if (c == '/' and n == '/') {
            in_line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and n == '*') {
            in_block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == '\'') {
            in_char = true;
            continue;
        }

        if (kindOf(c) == null) continue;

        if (isOpen(c)) {
            const depth: u8 = @intCast(@min(stack.items.len, 255));
            const idx: u32 = @intCast(list.items.len);
            try list.append(allocator, .{
                .offset = @intCast(i),
                .depth = depth,
                .kind = kindOf(c).?,
                .is_open = true,
                .unmatched = true, // until closed
            });
            try stack.append(allocator, .{ .list_idx = idx, .ch = c });
            continue;
        }

        // Closer
        if (stack.items.len == 0) {
            try list.append(allocator, .{
                .offset = @intCast(i),
                .depth = 0,
                .kind = kindOf(c).?,
                .is_open = false,
                .unmatched = true,
            });
            continue;
        }

        // Pop until matching kind or empty (mismatched still close top for coloring)
        const top = stack.items[stack.items.len - 1];
        if (!matches(top.ch, c)) {
            // Mismatched closer — mark unmatched, don't pop wrong opener
            try list.append(allocator, .{
                .offset = @intCast(i),
                .depth = @intCast(@min(stack.items.len, 255)),
                .kind = kindOf(c).?,
                .is_open = false,
                .unmatched = true,
            });
            continue;
        }
        _ = stack.pop();
        const open_e = &list.items[top.list_idx];
        open_e.pair_off = @intCast(i);
        open_e.unmatched = false;
        try list.append(allocator, .{
            .offset = @intCast(i),
            .pair_off = open_e.offset,
            .depth = open_e.depth,
            .kind = open_e.kind,
            .is_open = false,
            .unmatched = false,
        });
    }

    // Remaining openers stay unmatched (already flagged).
    const owned = try list.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .entries = owned,
    };
}

/// Per-document cache.
pub const BracketStore = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u32, BracketIndex) = .empty,

    pub fn init(allocator: std.mem.Allocator) BracketStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BracketStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *const BracketStore, doc_id: u32) ?*const BracketIndex {
        return self.map.getPtr(doc_id);
    }

    pub fn refresh(self: *BracketStore, doc_id: u32, text: []const u8) !void {
        var idx = try build(self.allocator, text);
        errdefer idx.deinit();
        const gop = try self.map.getOrPut(self.allocator, doc_id);
        if (gop.found_existing) {
            gop.value_ptr.deinit();
        }
        gop.value_ptr.* = idx;
    }

    pub fn clearDoc(self: *BracketStore, doc_id: u32) void {
        if (self.map.fetchRemove(doc_id)) |kv| {
            var idx = kv.value;
            idx.deinit();
        }
    }
};

pub fn rgbForDepth(depth: u8) Rgb {
    return palette[depth % palette_len];
}

pub fn brighten(r: f32, g: f32, b: f32) Rgb {
    return .{
        .r = @min(1.0, r * 0.35 + 0.65),
        .g = @min(1.0, g * 0.35 + 0.65),
        .b = @min(1.0, b * 0.35 + 0.65),
    };
}

test "nested pairs share depth colors" {
    //           012345678901234567890123456789
    const src = "fn f() { if (a[0]) { } }";
    // paren at 4-5 depth0, brace 7-22 depth0, paren 12-16 depth1, bracket 14-16? a[0] = 14 open 16 close depth2, brace 19-21 depth1
    var idx = try build(std.testing.allocator, src);
    defer idx.deinit();

    const p_open = idx.entryAt(4).?; // (
    const p_close = idx.entryAt(5).?; // )
    try std.testing.expect(p_open.is_open);
    try std.testing.expect(!p_close.is_open);
    try std.testing.expectEqual(p_open.offset, p_close.pair_off);
    try std.testing.expectEqual(@as(u8, 0), p_open.depth);

    const b0 = idx.entryAt(7).?; // {
    try std.testing.expectEqual(@as(u8, 0), b0.depth);
    try std.testing.expectEqual(@as(u32, 23), b0.pair_off); // final '}'

    const p1 = idx.entryAt(12).?; // (
    try std.testing.expectEqual(@as(u8, 1), p1.depth);

    const br = idx.entryAt(14).?; // [
    try std.testing.expectEqual(@as(u8, 2), br.depth);
    try std.testing.expectEqual(@as(u32, 16), br.pair_off);

    const inner_brace = idx.entryAt(19).?;
    try std.testing.expectEqual(@as(u8, 1), inner_brace.depth);
}

test "brackets in string and comment ignored" {
    const src = "x = \"(\"; // {\n y = 1;";
    var idx = try build(std.testing.allocator, src);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
}

test "unmatched opener still colored" {
    const src = "fn main() {\n  const x = 1;\n";
    var idx = try build(std.testing.allocator, src);
    defer idx.deinit();
    // ( ) matched, { unmatched
    var found_unmatched = false;
    for (idx.entries) |e| {
        if (e.is_open and e.unmatched and e.kind == .brace) found_unmatched = true;
    }
    try std.testing.expect(found_unmatched);
}

test "color cycle wraps" {
    const src = "((((a))))";
    var idx = try build(std.testing.allocator, src);
    defer idx.deinit();
    try std.testing.expectEqual(@as(u8, 0), idx.entryAt(0).?.colorIndex());
    try std.testing.expectEqual(@as(u8, 1), idx.entryAt(1).?.colorIndex());
    try std.testing.expectEqual(@as(u8, 2), idx.entryAt(2).?.colorIndex());
    try std.testing.expectEqual(@as(u8, 0), idx.entryAt(3).?.colorIndex()); // wrap
}

test "pairNear finds caret after bracket" {
    const src = "(x)";
    var idx = try build(std.testing.allocator, src);
    defer idx.deinit();
    // caret after '(' is offset 1
    const p = idx.pairNear(1).?;
    try std.testing.expectEqual(@as(u32, 0), p.open);
    try std.testing.expectEqual(@as(u32, 2), p.close);
}
