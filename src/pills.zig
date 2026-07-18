//! Import bubbles as a grid of name pills.
//!
//! An import block is ~8 lines of `const X = @import("…");` — near-identical text where the only
//! thing a reader wants is the set of names. This turns that block into wrapped chips.
//!
//! Both halves live here because they must agree: `parse` decides which pills exist, and `Walker`
//! decides where they sit. Height, drawing and hit-testing all walk the same sequence.

const std = @import("std");
const geom = @import("geom.zig");
const font = @import("font.zig");
const detect = @import("lang/detect.zig");
const outline = @import("lang/outline.zig");

pub const Language = detect.Language;

/// A `const X = @import("…")` binding inside an import block.
pub const Import = struct {
    /// Binding name — what the pill shows (`std`).
    name: []const u8,
    /// First quoted argument: the module path for `@import`, the header for `@cImport`'s
    /// `@cInclude`. Empty when there is no quoted string at all.
    path: []const u8,
    /// Line within the *fragment*, not the document — clicking a pill puts the caret here.
    line: u32,
};

pub const ParseError = error{OutOfMemory};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn readIdent(s: []const u8) []const u8 {
    if (s.len == 0 or !isIdentStart(s[0])) return &.{};
    var i: usize = 1;
    while (i < s.len and isIdentCont(s[i])) : (i += 1) {}
    return s[0..i];
}

fn trimStart(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t");
}

/// Contents of the first `"…"` in `s`, or empty when there isn't one.
/// For `@cImport({ @cInclude("x.h"); })` that lands on the header, which is the closest thing
/// to a path it has.
fn quotedArg(s: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, s, '"') orelse return &.{};
    const rest = s[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return &.{};
    return rest[0..close];
}

/// True when an import block should render as pills at all.
///
/// False means "show the code instead". Rust `use` blocks have no binding name to put on a
/// pill, and a Zig block of only `usingnamespace` yields none either — in both cases the pill
/// view would be an empty box with a `+`, hiding statements that are really there. Callers
/// must consult this rather than assuming every `.imports` bubble has pills.
pub fn hasPills(imports: []const Import) bool {
    return imports.len > 0;
}

/// Parse the import bindings out of `source`, one entry per `@import`/`@cImport` line.
///
/// Deliberately narrow: `const assert = std.debug.assert;` and `const Air = @This();` are
/// bindings in the same block but are not imports, so they get no pill. Non-matching lines are
/// skipped, not an error; an import block can contain blanks and comments.
///
/// **This does not exactly mirror `outline`.** Sharing `isZigImportRhs` unifies only the
/// right-hand-side test; `outline`'s scanner also tracks strings and block comments and only
/// matches at depth-0 line starts, while this splits on newlines. So a `const x = @import(…)`
/// buried in a `/* */` block gets a pill that `outline` ignores, and `usingnamespace @import(…)`
/// is an import to `outline` but has no binding name to put on a pill. Both are cosmetic —
/// wrong pill set, never wrong bytes — but the two are not interchangeable.
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: Language,
    out: *std.ArrayListUnmanaged(Import),
) ParseError!void {
    out.clearRetainingCapacity();
    if (lang != .zig) return; // Rust `use` has no binding name to show

    var line: u32 = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| : (line += 1) {
        if (parseLine(raw)) |imp| {
            try out.append(allocator, .{ .name = imp.name, .path = imp.path, .line = line });
        }
    }
}

const LineMatch = struct { name: []const u8, path: []const u8 };

fn parseLine(raw: []const u8) ?LineMatch {
    var s = trimStart(raw);
    if (std.mem.startsWith(u8, s, "pub")) s = trimStart(s["pub".len..]);
    if (!(std.mem.startsWith(u8, s, "const") and (s.len == 5 or !isIdentCont(s[5])))) return null;

    const after = trimStart(s[5..]);
    const name = readIdent(after);
    if (name.len == 0) return null;

    var after_name = trimStart(after[name.len..]);
    // Skip an explicit type: `const x: type = @import(…)`.
    if (after_name.len > 0 and after_name[0] == ':') {
        const eq = std.mem.indexOfScalar(u8, after_name, '=') orelse return null;
        after_name = after_name[eq..];
    }
    if (!std.mem.startsWith(u8, after_name, "=")) return null;

    const rhs = trimStart(after_name[1..]);
    if (!outline.isZigImportRhs(rhs)) return null;
    return .{ .name = name, .path = quotedArg(rhs) };
}

// --- geometry ---

/// Padding inside a pill, around its text (world units).
pub const pill_pad_x: f32 = 6;
pub const pill_pad_y: f32 = 3;
/// Gap between pills, both axes.
pub const pill_gap: f32 = 5;

pub fn pillHeight() f32 {
    return font.Font.charH() + pill_pad_y * 2;
}

pub fn pillWidth(name_len: usize) f32 {
    return @as(f32, @floatFromInt(name_len)) * font.Font.charW() + pill_pad_x * 2;
}

/// The `+` control is square, matching the pill row height.
pub fn plusWidth() f32 {
    return pillHeight();
}

/// Walks pill rects in flow order, wrapping at the content edge.
///
/// No allocation and no stored layout: height, drawing and hit-testing each construct a walker
/// over the same imports and content box and therefore produce identical rects. Storing the
/// rects instead would give three consumers three chances to drift.
///
/// Rows never exceed `content`'s width, but the walk *can* run past its bottom — the caller
/// sizes the bubble from `height()` rather than clipping.
pub const Walker = struct {
    content: geom.BoundingBox,
    x: f32,
    y: f32,
    /// True until the first pill on the current row is placed (no leading gap).
    row_empty: bool = true,

    pub fn init(content: geom.BoundingBox) Walker {
        return .{ .content = content, .x = content.x, .y = content.y };
    }

    /// Rect for the next pill of `name_len` characters.
    pub fn next(self: *Walker, name_len: usize) geom.BoundingBox {
        return self.place(pillWidth(name_len));
    }

    /// Rect for the trailing `+` control.
    pub fn plus(self: *Walker) geom.BoundingBox {
        return self.place(plusWidth());
    }

    fn place(self: *Walker, w: f32) geom.BoundingBox {
        const gap = if (self.row_empty) 0 else pill_gap;
        // Wrap when this pill would cross the right edge — but never strand a pill on an empty
        // row, or one wider than the content would loop forever.
        if (!self.row_empty and self.x + gap + w > self.content.right()) {
            self.x = self.content.x;
            self.y += pillHeight() + pill_gap;
            self.row_empty = true;
            return self.place(w);
        }
        const box = geom.BoundingBox{ .x = self.x + gap, .y = self.y, .w = w, .h = pillHeight() };
        self.x = box.right();
        self.row_empty = false;
        return box;
    }

    /// Total height consumed so far, including the row in progress.
    pub fn height(self: Walker) f32 {
        return self.y - self.content.y + pillHeight();
    }
};

/// Height needed to lay `imports` out as pills inside `content`, including the `+` control.
pub fn layoutHeight(imports: []const Import, content: geom.BoundingBox) f32 {
    var w = Walker.init(content);
    for (imports) |imp| _ = w.next(imp.name.len);
    _ = w.plus();
    return w.height();
}

// --- tests ---

const testing = std.testing;

fn parseAll(src: []const u8, out: *std.ArrayListUnmanaged(Import)) !void {
    try parse(testing.allocator, src, .zig, out);
}

test "parse extracts name and path" {
    var out: std.ArrayListUnmanaged(Import) = .empty;
    defer out.deinit(testing.allocator);
    try parseAll("const std = @import(\"std\");\nconst print = @import(\"Air/print.zig\");", &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("std", out.items[0].name);
    try testing.expectEqualStrings("std", out.items[0].path);
    try testing.expectEqualStrings("print", out.items[1].name);
    try testing.expectEqualStrings("Air/print.zig", out.items[1].path);
}

test "parse takes pub const imports" {
    var out: std.ArrayListUnmanaged(Import) = .empty;
    defer out.deinit(testing.allocator);
    try parseAll("pub const Legalize = @import(\"Air/Legalize.zig\");", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("Legalize", out.items[0].name);
}

test "parse skips non-imports" {
    var out: std.ArrayListUnmanaged(Import) = .empty;
    defer out.deinit(testing.allocator);
    // Bindings in the same block that aren't imports — they get no pill, matching `outline`.
    try parseAll(
        \\const assert = std.debug.assert;
        \\const Air = @This();
        \\var x = @import("nope.zig");
        \\// const commented = @import("x.zig");
        \\
    , &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "parse handles @cImport" {
    var out: std.ArrayListUnmanaged(Import) = .empty;
    defer out.deinit(testing.allocator);
    try parseAll("const c = @cImport({ @cInclude(\"stb.h\"); });", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("c", out.items[0].name);
    // @cImport has no module path; the first quoted string is the @cInclude header.
    try testing.expectEqualStrings("stb.h", out.items[0].path);
}

test "parse records the fragment-local line" {
    // This is the caret target: an off-by-one here lands you on the wrong import.
    var out: std.ArrayListUnmanaged(Import) = .empty;
    defer out.deinit(testing.allocator);
    try parseAll(
        \\const a = @import("a.zig");
        \\
        \\const notanimport = 1;
        \\const b = @import("b.zig");
    , &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 0), out.items[0].line);
    try testing.expectEqual(@as(u32, 3), out.items[1].line); // 3, not 1
}

test "parse skips a typed import binding cleanly" {
    var out: std.ArrayListUnmanaged(Import) = .empty;
    defer out.deinit(testing.allocator);
    try parseAll("const t: type = @import(\"t.zig\");", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("t", out.items[0].name);
}

const test_content = geom.BoundingBox{ .x = 10, .y = 20, .w = 200, .h = 500 };

test "pills flow left to right then wrap at the content edge" {
    var w = Walker.init(test_content);
    const a = w.next(4);
    const b = w.next(4);
    try testing.expectApproxEqAbs(test_content.x, a.x, 1e-4);
    try testing.expectApproxEqAbs(a.y, b.y, 1e-4); // same row
    try testing.expect(b.x > a.right()); // gap between them

    // Force a wrap with a name too long to share the row.
    const c = w.next(60);
    try testing.expect(c.y > a.y);
    try testing.expectApproxEqAbs(test_content.x, c.x, 1e-4);
}

test "no pill exceeds the content width" {
    var w = Walker.init(test_content);
    const lens = [_]usize{ 3, 7, 12, 4, 9, 15, 2, 6 };
    for (lens) |n| {
        const box = w.next(n);
        try testing.expect(box.x >= test_content.x);
        try testing.expect(box.right() <= test_content.right() + 0.001);
    }
}

test "a pill wider than the content still gets placed" {
    // Guards the recursion in `place`: an over-wide pill on an empty row must not wrap forever.
    var w = Walker.init(.{ .x = 0, .y = 0, .w = 20, .h = 100 });
    const box = w.next(40);
    try testing.expectApproxEqAbs(@as(f32, 0), box.x, 1e-4);
    try testing.expect(box.w > 20); // overflows rather than hanging
}

test "the + button follows the last pill" {
    var w = Walker.init(test_content);
    const last = w.next(4);
    const p = w.plus();
    try testing.expectApproxEqAbs(last.y, p.y, 1e-4);
    try testing.expect(p.x > last.right());
    try testing.expectApproxEqAbs(pillHeight(), p.w, 1e-4); // square
}

test "walker is deterministic" {
    // Load-bearing: drawing and hit-testing agree only because two independent walks over the
    // same inputs produce identical rects. Nothing stores the layout to compare against.
    const lens = [_]usize{ 3, 7, 12, 4, 9, 15, 2, 6, 11 };
    var a = Walker.init(test_content);
    var b = Walker.init(test_content);
    for (lens) |n| {
        const ra = a.next(n);
        const rb = b.next(n);
        try testing.expectEqual(ra.x, rb.x);
        try testing.expectEqual(ra.y, rb.y);
        try testing.expectEqual(ra.w, rb.w);
        try testing.expectEqual(ra.h, rb.h);
    }
    try testing.expectEqual(a.plus().x, b.plus().x);
    try testing.expectEqual(a.height(), b.height());
}

test "layoutHeight covers every pill it places" {
    // The bubble is sized from this, so it must not come out shorter than the pills drawn.
    const imports = [_]Import{
        .{ .name = "std", .path = "std", .line = 0 },
        .{ .name = "builtin", .path = "builtin", .line = 1 },
        .{ .name = "types_resolved", .path = "Air/types_resolved.zig", .line = 2 },
        .{ .name = "InternPool", .path = "InternPool.zig", .line = 3 },
    };
    const h = layoutHeight(&imports, test_content);

    var w = Walker.init(test_content);
    for (imports) |imp| {
        const box = w.next(imp.name.len);
        try testing.expect(box.bottom() <= test_content.y + h + 0.001);
    }
    const p = w.plus();
    try testing.expect(p.bottom() <= test_content.y + h + 0.001);
}

test "layoutHeight is one row when everything fits" {
    const imports = [_]Import{.{ .name = "std", .path = "std", .line = 0 }};
    try testing.expectApproxEqAbs(pillHeight(), layoutHeight(&imports, test_content), 1e-4);
}

test "layoutHeight makes room for the + control" {
    // The wide-box test above can't catch a height that forgets the `+`, because the control
    // shares the last pill's row there. A box too narrow for two pills forces one per row, so
    // the `+` must claim its own — and a height that skipped it is exactly one row short.
    const narrow = geom.BoundingBox{ .x = 0, .y = 0, .w = 30, .h = 500 };
    const imports = [_]Import{
        .{ .name = "aaaa", .path = "", .line = 0 },
        .{ .name = "bbbb", .path = "", .line = 1 },
    };

    var w = Walker.init(narrow);
    for (imports) |imp| _ = w.next(imp.name.len);
    const p = w.plus();
    try testing.expect(p.y > narrow.y); // the control really did wrap

    // Two pill rows plus the control's row.
    const h = layoutHeight(&imports, narrow);
    try testing.expectApproxEqAbs(pillHeight() * 3 + pill_gap * 2, h, 1e-3);
    try testing.expect(p.bottom() <= narrow.y + h + 0.001);
}
