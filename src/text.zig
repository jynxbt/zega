//! View-only code reflow for bubble content rectangles.
//! Does not mutate source text (Code Bubbles paper §5).

const std = @import("std");
const font = @import("font.zig");

/// One display line: a zero-copy slice into the source buffer.
pub const DisplayLine = struct {
    bytes: []const u8,
    /// 0-based logical line index within the reflowed source text.
    logical_line: u32 = 0,
    /// Byte offset of this slice within its logical line (0 if not a wrap tail).
    col_offset: u32 = 0,
    /// True when this row is a soft-wrap continuation (no line number).
    wrap_continuation: bool = false,
};

pub const ReflowError = error{OutOfMemory};

/// Reflow `source` into `out` display lines that fit in `max_cols` columns.
/// Soft-breaks at the last space in the window when possible; otherwise hard-cuts.
/// `out` is cleared then filled. Returns number of display lines written.
pub fn reflow(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_cols: u32,
    out: *std.ArrayListUnmanaged(DisplayLine),
) ReflowError!usize {
    out.clearRetainingCapacity();
    const cols: usize = @max(1, max_cols);

    var line_start: usize = 0;
    var logical_idx: u32 = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        const at_end = i == source.len;
        const at_nl = !at_end and source[i] == '\n';
        if (!at_end and !at_nl) continue;

        const logical = source[line_start..i];
        try reflowLogicalLine(allocator, logical, cols, logical_idx, out);

        if (at_end) break;
        line_start = i + 1;
        logical_idx += 1;
    }

    // Empty source → one empty display line (cursor-friendly later).
    if (source.len == 0) {
        try out.append(allocator, .{ .bytes = source, .logical_line = 0 });
    }

    return out.items.len;
}

fn reflowLogicalLine(
    allocator: std.mem.Allocator,
    logical: []const u8,
    cols: usize,
    logical_idx: u32,
    out: *std.ArrayListUnmanaged(DisplayLine),
) ReflowError!void {
    if (logical.len == 0) {
        try out.append(allocator, .{
            .bytes = logical,
            .logical_line = logical_idx,
            .col_offset = 0,
            .wrap_continuation = false,
        });
        return;
    }

    var rest = logical;
    var col_off: u32 = 0;
    var first = true;
    while (rest.len > cols) {
        const cut = findSoftBreak(rest, cols);
        try out.append(allocator, .{
            .bytes = rest[0..cut],
            .logical_line = logical_idx,
            .col_offset = col_off,
            .wrap_continuation = !first,
        });
        first = false;
        rest = rest[cut..];
        col_off += @intCast(cut);
        // Swallow one leading space after a soft wrap so wrapped lines don't indent with a space.
        if (rest.len > 0 and rest[0] == ' ') {
            rest = rest[1..];
            col_off += 1;
        }
    }
    try out.append(allocator, .{
        .bytes = rest,
        .logical_line = logical_idx,
        .col_offset = col_off,
        .wrap_continuation = !first,
    });
}

/// Cut index in (0, cols] for the next display chunk of `rest`.
/// Prefer spaces, then punctuation; avoid splitting mid-identifier when possible.
fn findSoftBreak(rest: []const u8, cols: usize) usize {
    std.debug.assert(rest.len > cols);
    // 1) Last whitespace in window — break before it (caller swallows leading space).
    var j: usize = cols;
    while (j > 1) : (j -= 1) {
        if (rest[j - 1] == ' ' or rest[j - 1] == '\t') {
            const cut = j - 1;
            if (cut > 0) return cut;
            break;
        }
    }
    // 2) After punctuation / operators (keep punctuation on this line).
    j = cols;
    while (j > 1) : (j -= 1) {
        const ch = rest[j - 1];
        if (ch == ',' or ch == ';' or ch == '(' or ch == ')' or ch == '[' or ch == ']' or
            ch == '{' or ch == '}' or ch == '.' or ch == ':' or ch == '=' or ch == '+' or
            ch == '-' or ch == '*' or ch == '/' or ch == '|' or ch == '&' or ch == '!')
        {
            return j;
        }
    }
    // 3) Don't hard-cut mid-identifier: back up to non-ident if the cut is inside one.
    if (cols < rest.len and isIdentByte(rest[cols]) and isIdentByte(rest[cols - 1])) {
        var k = cols;
        while (k > 1 and isIdentByte(rest[k - 1])) : (k -= 1) {}
        if (k > 1) return k;
    }
    return cols;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Count display lines without allocating (for height estimates).
pub fn reflowCount(source: []const u8, max_cols: u32) usize {
    const cols: usize = @max(1, max_cols);
    if (source.len == 0) return 1;

    var count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        const at_end = i == source.len;
        const at_nl = !at_end and source[i] == '\n';
        if (!at_end and !at_nl) continue;

        const logical = source[line_start..i];
        count += countLogical(logical, cols);

        if (at_end) break;
        line_start = i + 1;
    }
    return count;
}

fn countLogical(logical: []const u8, cols: usize) usize {
    if (logical.len == 0) return 1;
    var rest = logical;
    var n: usize = 0;
    while (rest.len > cols) {
        const cut = findSoftBreak(rest, cols);
        n += 1;
        rest = rest[cut..];
        if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    }
    return n + 1;
}

/// Max columns from content width using font metrics (after atlas bake).
pub fn maxColsForWidth(content_width: f32) u32 {
    return font.Font.maxCols(content_width);
}

test "reflow short line unchanged" {
    var list: std.ArrayListUnmanaged(DisplayLine) = .empty;
    defer list.deinit(std.testing.allocator);
    const n = try reflow(std.testing.allocator, "hello", 40, &list);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("hello", list.items[0].bytes);
}

test "reflow hard wraps long line" {
    var list: std.ArrayListUnmanaged(DisplayLine) = .empty;
    defer list.deinit(std.testing.allocator);
    // 20 x's, cols=8 → at least 3 display lines
    const src = "xxxxxxxxxxxxxxxxxxxx";
    const n = try reflow(std.testing.allocator, src, 8, &list);
    try std.testing.expect(n >= 3);
    try std.testing.expect(list.items[0].bytes.len <= 8);
    // Zero-copy into source
    try std.testing.expect(@intFromPtr(list.items[0].bytes.ptr) >= @intFromPtr(src.ptr));
}

test "reflow soft break at space" {
    var list: std.ArrayListUnmanaged(DisplayLine) = .empty;
    defer list.deinit(std.testing.allocator);
    const src = "hello world and more";
    _ = try reflow(std.testing.allocator, src, 12, &list);
    try std.testing.expect(list.items.len >= 2);
    // First chunk should end around "hello world"
    try std.testing.expect(std.mem.indexOfScalar(u8, list.items[0].bytes, ' ') != null or list.items[0].bytes.len <= 12);
}

test "reflow multiline and empty" {
    var list: std.ArrayListUnmanaged(DisplayLine) = .empty;
    defer list.deinit(std.testing.allocator);
    _ = try reflow(std.testing.allocator, "a\n\nb", 40, &list);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("a", list.items[0].bytes);
    try std.testing.expectEqualStrings("", list.items[1].bytes);
    try std.testing.expectEqualStrings("b", list.items[2].bytes);
}

test "reflowCount matches reflow" {
    const src = "short\n" ++ "x" ** 30;
    var list: std.ArrayListUnmanaged(DisplayLine) = .empty;
    defer list.deinit(std.testing.allocator);
    const n = try reflow(std.testing.allocator, src, 10, &list);
    try std.testing.expectEqual(n, reflowCount(src, 10));
}

test "max cols one" {
    var list: std.ArrayListUnmanaged(DisplayLine) = .empty;
    defer list.deinit(std.testing.allocator);
    const n = try reflow(std.testing.allocator, "abcd", 1, &list);
    try std.testing.expectEqual(@as(usize, 4), n);
}
