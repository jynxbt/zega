//! Structural outline for Zig and Rust — top-level items for bubble creation.
//! Best-effort brace-depth scanner (tree-sitter upgrade path later).

const std = @import("std");
const detect = @import("detect.zig");

pub const Language = detect.Language;

pub const ItemKind = enum {
    function,
    @"struct",
    @"enum",
    @"union",
    impl,
    module,
    trait,
    constant,
    test_block,
    /// Module import / use statement (`@import`, `use`, …).
    import,
    other,
};

pub const OutlineItem = struct {
    name: []const u8,
    kind: ItemKind,
    /// Inclusive start line.
    start_line: u32,
    /// Exclusive end line.
    end_line: u32,
    /// Enclosing type name (e.g. `App` for `App.init`); slice into source when set.
    parent_name: ?[]const u8 = null,
};

/// Nested methods shorter than this stay inside the parent type bubble.
/// Only longer methods get their own bubble (compact canvas).
pub const method_bubble_min_lines: u32 = 12;

pub fn outline(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: Language,
    out: *std.ArrayListUnmanaged(OutlineItem),
) !void {
    out.clearRetainingCapacity();
    switch (lang) {
        .zig => try outlineZig(allocator, source, out),
        .rust => try outlineRust(allocator, source, out),
        .unknown => {},
    }
}

// --- shared helpers ---

const Scan = struct {
    src: []const u8,
    /// Byte offset of each line start.
    line_starts: []u32,
};

fn buildLineStarts(allocator: std.mem.Allocator, src: []const u8) ![]u32 {
    var list: std.ArrayListUnmanaged(u32) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, 0);
    var i: u32 = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') try list.append(allocator, i + 1);
    }
    return try list.toOwnedSlice(allocator);
}

fn lineOf(line_starts: []const u32, offset: usize) u32 {
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

fn lineStart(line_starts: []const u32, line: u32) usize {
    return line_starts[line];
}

fn lineCount(line_starts: []const u32, src_len: usize) u32 {
    _ = src_len;
    return @intCast(line_starts.len);
}

fn trimStart(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t");
}

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

/// Find matching close for `{` at open_off (must point at '{'). Returns byte after '}'.
fn skipBraceBlock(src: []const u8, open_off: usize) usize {
    if (open_off >= src.len or src[open_off] != '{') return open_off;
    var depth: i32 = 0;
    var i = open_off;
    var in_str = false;
    var in_char = false;
    var in_line_comment = false;
    var in_block_comment = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        const n = if (i + 1 < src.len) src[i + 1] else 0;

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
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (in_char) {
            if (c == '\\' and i + 1 < src.len) {
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
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return src.len;
}

fn findNextBrace(src: []const u8, from: usize) ?usize {
    var i = from;
    var in_str = false;
    var in_line_comment = false;
    var in_block_comment = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        const n = if (i + 1 < src.len) src[i + 1] else 0;
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
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
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
        if (c == '{') return i;
        if (c == ';') return null; // decl without body
    }
    return null;
}

fn endLineExclusive(line_starts: []const u32, end_off: usize) u32 {
    // end_off is first byte after item; exclusive end line = line of last byte of item + 1
    if (end_off == 0) return 0;
    const last = end_off - 1;
    return lineOf(line_starts, last) + 1;
}

// --- Zig ---

fn outlineZig(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayListUnmanaged(OutlineItem)) !void {
    const line_starts = try buildLineStarts(allocator, source);
    defer allocator.free(line_starts);

    var depth: i32 = 0;
    var i: usize = 0;
    var in_str = false;
    var in_line_comment = false;
    var in_block_comment = false;

    while (i < source.len) {
        const c = source[i];
        const n = if (i + 1 < source.len) source[i + 1] else 0;

        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            i += 1;
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and n == '/') {
                in_block_comment = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if (in_str) {
            if (c == '\\' and i + 1 < source.len) {
                i += 2;
                continue;
            }
            if (c == '"') in_str = false;
            i += 1;
            continue;
        }
        if (c == '/' and n == '/') {
            in_line_comment = true;
            i += 2;
            continue;
        }
        if (c == '/' and n == '*') {
            in_block_comment = true;
            i += 2;
            continue;
        }
        if (c == '"') {
            in_str = true;
            i += 1;
            continue;
        }

        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            depth -= 1;
            i += 1;
            continue;
        }

        // Top-level items at line starts.
        if (depth == 0 and (i == 0 or source[i - 1] == '\n')) {
            const line = lineOf(line_starts, i);
            const rest = source[i..];
            const t = trimStart(rest);
            const lead = rest.len - t.len;
            const at = i + lead;

            if (matchZigItem(t)) |m| {
                const start_line = line;
                const name = m.name;
                const kind = m.kind;
                const body_from = at + m.consume;
                const brace_off = findNextBrace(source, body_from);
                const end_off: usize = if (brace_off) |bo|
                    skipBraceBlock(source, bo)
                else blk: {
                    var j = body_from;
                    while (j < source.len and source[j] != ';' and source[j] != '\n') : (j += 1) {}
                    if (j < source.len and source[j] == ';') j += 1;
                    break :blk j;
                };
                const full_end_line = endLineExclusive(line_starts, end_off);

                // Container types: one bubble for the full type (fields + short methods).
                // Only *large* methods are also extracted as separate bubbles.
                const is_container = kind == .@"struct" or kind == .@"enum" or kind == .@"union";
                if (is_container) {
                    if (brace_off) |bo| {
                        try out.append(allocator, .{
                            .name = name,
                            .kind = kind,
                            .start_line = start_line,
                            .end_line = @max(full_end_line, start_line + 1),
                        });
                        var methods: std.ArrayListUnmanaged(OutlineItem) = .empty;
                        defer methods.deinit(allocator);
                        try collectZigMethods(
                            allocator,
                            source,
                            line_starts,
                            bo,
                            end_off,
                            name,
                            method_bubble_min_lines,
                            &methods,
                        );
                        for (methods.items) |meth| {
                            try out.append(allocator, meth);
                        }
                        i = end_off;
                        continue;
                    }
                }

                const item = OutlineItem{
                    .name = name,
                    .kind = kind,
                    .start_line = start_line,
                    .end_line = @max(full_end_line, start_line + 1),
                };
                if (kind == .import) {
                    try appendOrMergeImport(allocator, out, item);
                } else {
                    try out.append(allocator, item);
                }
                i = end_off;
                continue;
            }
        }
        i += 1;
    }
}

/// Merge consecutive top-level imports into one bubble (blank line allowed between).
fn appendOrMergeImport(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(OutlineItem),
    item: OutlineItem,
) !void {
    if (out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (last.kind == .import and item.start_line <= last.end_line + 1) {
            last.end_line = @max(last.end_line, item.end_line);
            // Multi-import block gets a stable group name.
            if (!std.mem.eql(u8, last.name, "imports")) {
                last.name = "imports";
            }
            return;
        }
    }
    try out.append(allocator, item);
}

/// Scan inside a type body `{ ... }` for large `fn` methods (depth relative to type brace = 1).
/// Only methods with at least `min_lines` source lines become separate outline items.
fn collectZigMethods(
    allocator: std.mem.Allocator,
    source: []const u8,
    line_starts: []const u32,
    type_brace_off: usize,
    type_end_off: usize,
    parent_name: []const u8,
    min_lines: u32,
    out: *std.ArrayListUnmanaged(OutlineItem),
) !void {
    // Start just after the opening `{`.
    var i = type_brace_off + 1;
    var depth: i32 = 1; // inside type body
    var in_str = false;
    var in_line_comment = false;
    var in_block_comment = false;

    while (i < type_end_off and i < source.len) {
        const c = source[i];
        const n = if (i + 1 < source.len) source[i + 1] else 0;

        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            i += 1;
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and n == '/') {
                in_block_comment = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if (in_str) {
            if (c == '\\' and i + 1 < source.len) {
                i += 2;
                continue;
            }
            if (c == '"') in_str = false;
            i += 1;
            continue;
        }
        if (c == '/' and n == '/') {
            in_line_comment = true;
            i += 2;
            continue;
        }
        if (c == '/' and n == '*') {
            in_block_comment = true;
            i += 2;
            continue;
        }
        if (c == '"') {
            in_str = true;
            i += 1;
            continue;
        }

        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            depth -= 1;
            i += 1;
            continue;
        }

        // Methods are direct children of the type (depth == 1) at line starts.
        if (depth == 1 and (source[i - 1] == '\n' or i == type_brace_off + 1)) {
            const rest = source[i..];
            const t = trimStart(rest);
            const lead = rest.len - t.len;
            const at = i + lead;
            if (matchZigMethod(t)) |m| {
                const start_line = lineOf(line_starts, at);
                const body_from = at + m.consume;
                const brace = findNextBrace(source, body_from);
                const end_off: usize = if (brace) |bo|
                    skipBraceBlock(source, bo)
                else blk: {
                    var j = body_from;
                    while (j < source.len and source[j] != ';' and source[j] != '\n') : (j += 1) {}
                    if (j < source.len and source[j] == ';') j += 1;
                    break :blk j;
                };
                const end_line = endLineExclusive(line_starts, end_off);
                const line_count = if (end_line > start_line) end_line - start_line else 1;
                // Short methods stay only inside the parent type bubble.
                if (line_count >= min_lines) {
                    try out.append(allocator, .{
                        .name = m.name,
                        .kind = .function,
                        .start_line = start_line,
                        .end_line = @max(end_line, start_line + 1),
                        .parent_name = parent_name,
                    });
                }
                i = end_off;
                continue;
            }
        }
        i += 1;
    }
}

/// Like matchZigItem but only functions (methods inside types).
fn matchZigMethod(t: []const u8) ?Match {
    var s = t;
    if (std.mem.startsWith(u8, s, "pub")) {
        s = trimStart(s["pub".len..]);
    }
    if (std.mem.startsWith(u8, s, "export")) {
        s = trimStart(s["export".len..]);
    }
    // Skip comptime/inline modifiers common on methods.
    if (std.mem.startsWith(u8, s, "inline")) {
        s = trimStart(s["inline".len..]);
    }
    if (std.mem.startsWith(u8, s, "comptime")) {
        s = trimStart(s["comptime".len..]);
    }
    if (!(std.mem.startsWith(u8, s, "fn") and (s.len == 2 or !isIdentCont(s[2])))) return null;
    const after_fn = trimStart(s[2..]);
    const name = readIdent(after_fn);
    if (name.len == 0) return null;
    const name_off = @intFromPtr(name.ptr) - @intFromPtr(t.ptr);
    return .{ .name = name, .kind = .function, .consume = name_off + name.len };
}

const Match = struct {
    name: []const u8,
    kind: ItemKind,
    /// Bytes consumed from trimmed line start through name end (approx).
    consume: usize,
};

fn matchZigItem(t: []const u8) ?Match {
    var s = t;
    var consume_base: usize = 0;
    // optional pub / export
    if (std.mem.startsWith(u8, s, "pub")) {
        const after = trimStart(s["pub".len..]);
        consume_base += s.len - after.len;
        s = after;
    }
    if (std.mem.startsWith(u8, s, "export")) {
        const after = trimStart(s["export".len..]);
        consume_base += s.len - after.len;
        s = after;
    }
    if (std.mem.startsWith(u8, s, "extern")) {
        // skip extern "c" etc — still a fn
        var rest = s["extern".len..];
        rest = trimStart(rest);
        if (rest.len > 0 and rest[0] == '"') {
            if (std.mem.indexOfScalar(u8, rest[1..], '"')) |q| {
                rest = trimStart(rest[q + 2 ..]);
            }
        }
        consume_base += s.len - rest.len;
        s = rest;
    }

    if (std.mem.startsWith(u8, s, "fn") and (s.len == 2 or !isIdentCont(s[2]))) {
        const after_fn = trimStart(s[2..]);
        const name = readIdent(after_fn);
        if (name.len == 0) return null;
        const name_off = (@intFromPtr(name.ptr) - @intFromPtr(t.ptr));
        return .{ .name = name, .kind = .function, .consume = name_off + name.len };
    }
    if (std.mem.startsWith(u8, s, "test")) {
        const after = trimStart(s[4..]);
        // test "name" or test {
        var name: []const u8 = "test";
        if (after.len > 0 and after[0] == '"') {
            if (std.mem.indexOfScalar(u8, after[1..], '"')) |q| {
                name = after[0 .. q + 2];
            }
        }
        const name_off = @intFromPtr(name.ptr) - @intFromPtr(t.ptr);
        return .{ .name = name, .kind = .test_block, .consume = name_off + name.len };
    }
    // usingnamespace @import("…");
    if (std.mem.startsWith(u8, s, "usingnamespace") and (s.len == 14 or !isIdentCont(s[14]))) {
        const after = trimStart(s["usingnamespace".len..]);
        if (isZigImportRhs(after)) {
            return .{
                .name = "usingnamespace",
                .kind = .import,
                .consume = "usingnamespace".len,
            };
        }
    }

    if (std.mem.startsWith(u8, s, "const") and (s.len == 5 or !isIdentCont(s[5]))) {
        const after = trimStart(s[5..]);
        const name = readIdent(after);
        if (name.len == 0) return null;
        // only if looks like type decl: `const Name = struct` or similar
        const after_name = trimStart(after[name.len..]);
        if (!std.mem.startsWith(u8, after_name, "=")) return null;
        const rhs = trimStart(after_name[1..]);
        // Module import: `const std = @import("std");` / `@cImport({…})`
        if (isZigImportRhs(rhs)) {
            const name_off = @intFromPtr(name.ptr) - @intFromPtr(t.ptr);
            return .{ .name = name, .kind = .import, .consume = name_off + name.len };
        }
        const kind: ItemKind = if (std.mem.startsWith(u8, rhs, "struct"))
            .@"struct"
        else if (std.mem.startsWith(u8, rhs, "enum"))
            .@"enum"
        else if (std.mem.startsWith(u8, rhs, "union"))
            .@"union"
        else if (std.mem.startsWith(u8, rhs, "opaque"))
            .other
        else
            .constant;
        // Skip plain constants without brace bodies for outline noise? Keep types + multi-line.
        // Include all const for now only if `{` exists or type keyword.
        if (kind == .constant) {
            if (findNextBrace(t, 0) == null) return null;
        }
        const name_off = @intFromPtr(name.ptr) - @intFromPtr(t.ptr);
        return .{ .name = name, .kind = kind, .consume = name_off + name.len };
    }
    return null;
}

/// True for `@import(…)`, `@cImport(…)`, or those with field access after.
/// True when the right-hand side of a `const` binding makes it a module import.
/// Shared with the pill view so the RHS test has one definition — though the surrounding
/// context tests (strings, comments, depth) are this scanner's alone; see `pills.parse`.
pub fn isZigImportRhs(rhs: []const u8) bool {
    if (std.mem.startsWith(u8, rhs, "@import") and (rhs.len == 7 or !isIdentCont(rhs[7])))
        return true;
    if (std.mem.startsWith(u8, rhs, "@cImport") and (rhs.len == 8 or !isIdentCont(rhs[8])))
        return true;
    return false;
}

// --- Rust ---

fn outlineRust(allocator: std.mem.Allocator, source: []const u8, out: *std.ArrayListUnmanaged(OutlineItem)) !void {
    const line_starts = try buildLineStarts(allocator, source);
    defer allocator.free(line_starts);

    var depth: i32 = 0;
    var i: usize = 0;
    var in_str = false;
    var in_line_comment = false;
    var in_block_comment = false;

    while (i < source.len) {
        const c = source[i];
        const n = if (i + 1 < source.len) source[i + 1] else 0;

        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            i += 1;
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and n == '/') {
                in_block_comment = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if (in_str) {
            if (c == '\\' and i + 1 < source.len) {
                i += 2;
                continue;
            }
            if (c == '"') in_str = false;
            i += 1;
            continue;
        }
        if (c == '/' and n == '/') {
            in_line_comment = true;
            i += 2;
            continue;
        }
        if (c == '/' and n == '*') {
            in_block_comment = true;
            i += 2;
            continue;
        }
        if (c == '"') {
            in_str = true;
            i += 1;
            continue;
        }

        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            depth -= 1;
            i += 1;
            continue;
        }

        if (depth == 0 and (i == 0 or source[i - 1] == '\n')) {
            const line = lineOf(line_starts, i);
            const rest = source[i..];
            const t = trimStart(rest);
            if (matchRustItem(t)) |m| {
                const start_line = line;
                const at = i + (rest.len - t.len);
                const body_from = at;
                const brace_off = findNextBrace(source, body_from);
                const end_off: usize = if (brace_off) |bo|
                    skipBraceBlock(source, bo)
                else blk: {
                    var j = body_from;
                    while (j < source.len and source[j] != ';' and source[j] != '\n') : (j += 1) {}
                    if (j < source.len and source[j] == ';') j += 1;
                    break :blk j;
                };
                const end_line = endLineExclusive(line_starts, end_off);
                const item = OutlineItem{
                    .name = m.name,
                    .kind = m.kind,
                    .start_line = start_line,
                    .end_line = @max(end_line, start_line + 1),
                };
                if (m.kind == .import) {
                    try appendOrMergeImport(allocator, out, item);
                } else {
                    try out.append(allocator, item);
                }
                i = end_off;
                continue;
            }
        }
        i += 1;
    }
}

fn matchRustItem(t: []const u8) ?Match {
    var s = t;
    // attributes / visibility
    while (std.mem.startsWith(u8, s, "#[")) {
        if (std.mem.indexOfScalar(u8, s, ']')) |br| {
            s = trimStart(s[br + 1 ..]);
        } else break;
    }
    while (true) {
        const vis = [_][]const u8{ "pub(crate)", "pub(super)", "pub(in", "pub", "const", "async", "unsafe", "extern" };
        // handle pub / async / unsafe prefixes
        var advanced = false;
        if (std.mem.startsWith(u8, s, "pub")) {
            var rest = s[3..];
            if (rest.len > 0 and rest[0] == '(') {
                if (std.mem.indexOfScalar(u8, rest, ')')) |cl| rest = rest[cl + 1 ..];
            }
            s = trimStart(rest);
            advanced = true;
        }
        for ([_][]const u8{ "async", "unsafe", "const", "default" }) |kw| {
            if (std.mem.startsWith(u8, s, kw) and (s.len == kw.len or !isIdentCont(s[kw.len]))) {
                s = trimStart(s[kw.len..]);
                advanced = true;
            }
        }
        if (std.mem.startsWith(u8, s, "extern")) {
            s = trimStart(s["extern".len..]);
            if (s.len > 0 and s[0] == '"') {
                if (std.mem.indexOfScalar(u8, s[1..], '"')) |q| s = trimStart(s[q + 2 ..]);
            }
            advanced = true;
        }
        if (!advanced) break;
        _ = vis;
    }

    // `use std::io::{self, Read};` / `pub use foo::bar;`
    if (std.mem.startsWith(u8, s, "use") and (s.len == 3 or !isIdentCont(s[3]))) {
        const after = trimStart(s[3..]);
        const name = rustUseDisplayName(after);
        const name_off: usize = blk: {
            const np = @intFromPtr(name.ptr);
            const tp = @intFromPtr(t.ptr);
            if (np >= tp and np < tp + t.len) break :blk np - tp;
            break :blk 0;
        };
        return .{ .name = name, .kind = .import, .consume = @max(name_off + name.len, @as(usize, 3)) };
    }

    const keywords = [_]struct { []const u8, ItemKind }{
        .{ "fn", .function },
        .{ "struct", .@"struct" },
        .{ "enum", .@"enum" },
        .{ "impl", .impl },
        .{ "mod", .module },
        .{ "trait", .trait },
        .{ "type", .constant },
        .{ "static", .constant },
        // bare const item (not const fn — handled via prefix strip)
        .{ "const", .constant },
    };

    for (keywords) |kw| {
        const k = kw[0];
        const kind = kw[1];
        if (std.mem.startsWith(u8, s, k) and (s.len == k.len or !isIdentCont(s[k.len]))) {
            const after = trimStart(s[k.len..]);
            // impl may be `impl Foo` or `impl Trait for Foo`
            if (kind == .impl) {
                // name = whole rest until `{` simplified
                const name = if (readIdent(after).len > 0) blk: {
                    // if Trait for Type
                    var parts = after;
                    const first = readIdent(parts);
                    parts = trimStart(parts[first.len..]);
                    if (std.mem.startsWith(u8, parts, "for")) {
                        parts = trimStart(parts[3..]);
                        const ty = readIdent(parts);
                        if (ty.len > 0) break :blk ty;
                    }
                    break :blk first;
                } else "impl";
                const name_off: usize = if (@intFromPtr(name.ptr) >= @intFromPtr(t.ptr) and
                    @intFromPtr(name.ptr) < @intFromPtr(t.ptr) + t.len)
                    @intFromPtr(name.ptr) - @intFromPtr(t.ptr)
                else
                    0;
                return .{ .name = name, .kind = .impl, .consume = name_off + name.len };
            }
            if (kind == .function) {
                // skip lifetime generics briefly: fn foo / fn foo<
                const name = readIdent(after);
                if (name.len == 0) return null;
                const name_off = @intFromPtr(name.ptr) - @intFromPtr(t.ptr);
                return .{ .name = name, .kind = .function, .consume = name_off + name.len };
            }
            // struct/enum/mod/trait/type/const/static
            const name = readIdent(after);
            if (name.len == 0 and kind != .impl) return null;
            const n = if (name.len > 0) name else "item";
            const name_off = @intFromPtr(n.ptr) - @intFromPtr(t.ptr);
            // skip const FOO: ty = expr; without braces for outline? skip simple one-liners
            if (kind == .constant and findNextBrace(t, 0) == null and std.mem.indexOfScalar(u8, t, ';') != null) {
                // allow type aliases without braces
                if (!std.mem.startsWith(u8, s, "type")) return null;
            }
            return .{ .name = n, .kind = kind, .consume = name_off + n.len };
        }
    }
    return null;
}

/// Best-effort display name for a Rust `use` path (last path segment before `{`/`as`/`;`).
fn rustUseDisplayName(after: []const u8) []const u8 {
    var s = after;
    // skip leading `::`
    if (std.mem.startsWith(u8, s, "::")) s = s[2..];
    var last = readIdent(s);
    if (last.len == 0) return "use";
    var rest = s[last.len..];
    while (true) {
        rest = trimStart(rest);
        if (rest.len >= 2 and rest[0] == ':' and rest[1] == ':') {
            rest = rest[2..];
            const n = readIdent(rest);
            if (n.len == 0) break;
            last = n;
            rest = rest[n.len..];
            continue;
        }
        break;
    }
    // `use foo as bar` → bar
    rest = trimStart(rest);
    if (std.mem.startsWith(u8, rest, "as") and (rest.len == 2 or !isIdentCont(rest[2]))) {
        const alias = readIdent(trimStart(rest[2..]));
        if (alias.len > 0) return alias;
    }
    return last;
}

// --- tests ---

test "outline zig functions and struct" {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    hello();
        \\}
        \\
        \\fn hello() void {
        \\    _ = 1;
        \\}
        \\
        \\pub const Point = struct {
        \\    x: i32,
        \\    y: i32,
        \\};
    ;
    var items: std.ArrayListUnmanaged(OutlineItem) = .empty;
    defer items.deinit(std.testing.allocator);
    try outline(std.testing.allocator, src, .zig, &items);
    try std.testing.expect(items.items.len >= 4);
    try std.testing.expectEqualStrings("std", items.items[0].name);
    try std.testing.expect(items.items[0].kind == .import);
    try std.testing.expectEqualStrings("main", items.items[1].name);
    try std.testing.expectEqualStrings("hello", items.items[2].name);
    try std.testing.expectEqualStrings("Point", items.items[3].name);
}

test "outline zig merges consecutive imports" {
    const src =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const mem = @import("std").mem;
        \\
        \\pub fn main() void {}
        \\
    ;
    var items: std.ArrayListUnmanaged(OutlineItem) = .empty;
    defer items.deinit(std.testing.allocator);
    try outline(std.testing.allocator, src, .zig, &items);
    try std.testing.expect(items.items.len >= 2);
    try std.testing.expectEqualStrings("imports", items.items[0].name);
    try std.testing.expect(items.items[0].kind == .import);
    try std.testing.expectEqual(@as(u32, 0), items.items[0].start_line);
    try std.testing.expect(items.items[0].end_line >= 3);
    try std.testing.expectEqualStrings("main", items.items[1].name);
}

test "outline rust use statements" {
    const src =
        \\use std::io;
        \\use std::collections::HashMap;
        \\
        \\fn main() {}
        \\
    ;
    var items: std.ArrayListUnmanaged(OutlineItem) = .empty;
    defer items.deinit(std.testing.allocator);
    try outline(std.testing.allocator, src, .rust, &items);
    try std.testing.expect(items.items.len >= 2);
    try std.testing.expect(items.items[0].kind == .import);
    try std.testing.expectEqualStrings("imports", items.items[0].name);
    try std.testing.expectEqualStrings("main", items.items[1].name);
}

test "outline zig short methods stay inside type" {
    const src =
        \\pub const App = struct {
        \\    steps: u32 = 0,
        \\
        \\    pub fn init() App {
        \\        return .{};
        \\    }
        \\
        \\    pub fn run(self: *App) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    var items: std.ArrayListUnmanaged(OutlineItem) = .empty;
    defer items.deinit(std.testing.allocator);
    try outline(std.testing.allocator, src, .zig, &items);
    // Only the type bubble — short methods are not extracted.
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqualStrings("App", items.items[0].name);
    // Full type range includes methods.
    try std.testing.expect(items.items[0].end_line > items.items[0].start_line + 5);
}

test "outline zig large methods become separate bubbles" {
    // Build a method with many lines so it exceeds method_bubble_min_lines.
    var src_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer src_buf.deinit(std.testing.allocator);
    try src_buf.appendSlice(std.testing.allocator,
        \\pub const App = struct {
        \\    pub fn big(self: *App) void {
        \\
    );
    var n: u32 = 0;
    while (n < method_bubble_min_lines + 2) : (n += 1) {
        try src_buf.appendSlice(std.testing.allocator, "        _ = self;\n");
    }
    try src_buf.appendSlice(std.testing.allocator,
        \\    }
        \\    pub fn tiny(self: *App) void {
        \\        _ = self;
        \\    }
        \\};
        \\
    );
    var items: std.ArrayListUnmanaged(OutlineItem) = .empty;
    defer items.deinit(std.testing.allocator);
    try outline(std.testing.allocator, src_buf.items, .zig, &items);
    try std.testing.expect(items.items.len >= 2);
    try std.testing.expectEqualStrings("App", items.items[0].name);
    try std.testing.expectEqualStrings("big", items.items[1].name);
    try std.testing.expectEqualStrings("App", items.items[1].parent_name.?);
    // tiny stays inside App only
    for (items.items) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.name, "tiny"));
    }
}

test "outline rust fn and struct" {
    const src =
        \\fn main() {
        \\    let p = Point { x: 1, y: 2 };
        \\}
        \\
        \\pub struct Point {
        \\    pub x: i32,
        \\    pub y: i32,
        \\}
        \\
        \\impl Point {
        \\    pub fn new(x: i32, y: i32) -> Self {
        \\        Self { x, y }
        \\    }
        \\}
    ;
    var items: std.ArrayListUnmanaged(OutlineItem) = .empty;
    defer items.deinit(std.testing.allocator);
    try outline(std.testing.allocator, src, .rust, &items);
    try std.testing.expect(items.items.len >= 3);
    try std.testing.expectEqualStrings("main", items.items[0].name);
    try std.testing.expectEqualStrings("Point", items.items[1].name);
}
