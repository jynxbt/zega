//! Lightweight syntax highlighting for Zig and Rust (file-type aware).
//! Lexer is line-oriented for bubble rendering; not a full parser.

const std = @import("std");
const detect = @import("detect.zig");

pub const Language = detect.Language;

pub const TokenKind = enum {
    text,
    keyword,
    string,
    comment,
    number,
    type_name,
    function,
    operator,
    punctuation,
    attribute,
    constant, // true/false/null/undefined-style
};

pub const Span = struct {
    start: u32,
    end: u32,
    kind: TokenKind,
};

/// Dark-theme colors (similar to common editor themes).
pub fn colorRgb(kind: TokenKind) struct { r: f32, g: f32, b: f32 } {
    return switch (kind) {
        .text => .{ .r = 0.85, .g = 0.87, .b = 0.90 },
        .keyword => .{ .r = 0.78, .g = 0.47, .b = 0.90 }, // purple
        .string => .{ .r = 0.90, .g = 0.62, .b = 0.35 }, // orange
        .comment => .{ .r = 0.42, .g = 0.58, .b = 0.40 }, // muted green
        .number => .{ .r = 0.72, .g = 0.82, .b = 0.55 }, // lime
        .type_name => .{ .r = 0.45, .g = 0.75, .b = 0.92 }, // cyan/blue
        .function => .{ .r = 0.55, .g = 0.78, .b = 0.95 }, // light blue
        .operator => .{ .r = 0.70, .g = 0.72, .b = 0.78 },
        .punctuation => .{ .r = 0.65, .g = 0.68, .b = 0.72 },
        .attribute => .{ .r = 0.85, .g = 0.75, .b = 0.45 }, // gold
        .constant => .{ .r = 0.78, .g = 0.55, .b = 0.90 },
    };
}

pub fn highlightLine(
    lang: Language,
    line: []const u8,
    out: *std.ArrayListUnmanaged(Span),
    allocator: std.mem.Allocator,
) !void {
    out.clearRetainingCapacity();
    if (line.len == 0) return;

    switch (lang) {
        .zig => try lexZig(line, out, allocator),
        .rust => try lexRust(line, out, allocator),
        .unknown => try out.append(allocator, .{ .start = 0, .end = @intCast(line.len), .kind = .text }),
    }
}

/// Kind at byte offset (for drawing).
pub fn kindAt(spans: []const Span, offset: u32) TokenKind {
    for (spans) |s| {
        if (offset >= s.start and offset < s.end) return s.kind;
    }
    return .text;
}

fn push(out: *std.ArrayListUnmanaged(Span), allocator: std.mem.Allocator, start: u32, end: u32, kind: TokenKind) !void {
    if (end <= start) return;
    try out.append(allocator, .{ .start = start, .end = end, .kind = kind });
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn lexZig(line: []const u8, out: *std.ArrayListUnmanaged(Span), allocator: std.mem.Allocator) !void {
    var i: u32 = 0;
    while (i < line.len) {
        const c = line[i];

        // whitespace
        if (c == ' ' or c == '\t') {
            const s = i;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            try push(out, allocator, s, i, .text);
            continue;
        }

        // line comment
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            try push(out, allocator, i, @intCast(line.len), .comment);
            return;
        }

        // string / multiline start
        if (c == '"') {
            const s = i;
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (line[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try push(out, allocator, s, i, .string);
            continue;
        }

        // char literal
        if (c == '\'') {
            const s = i;
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (line[i] == '\'') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try push(out, allocator, s, i, .string);
            continue;
        }

        // number
        if (isDigit(c) or (c == '.' and i + 1 < line.len and isDigit(line[i + 1]))) {
            const s = i;
            if (c == '0' and i + 1 < line.len and (line[i + 1] == 'x' or line[i + 1] == 'b' or line[i + 1] == 'o')) {
                i += 2;
            }
            while (i < line.len and (isIdentCont(line[i]) or line[i] == '.' or line[i] == '\'')) : (i += 1) {}
            try push(out, allocator, s, i, .number);
            continue;
        }

        // @builtin
        if (c == '@') {
            const s = i;
            i += 1;
            while (i < line.len and isIdentCont(line[i])) : (i += 1) {}
            try push(out, allocator, s, i, .attribute);
            continue;
        }

        // identifier / keyword
        if (isIdentStart(c)) {
            const s = i;
            i += 1;
            while (i < line.len and isIdentCont(line[i])) : (i += 1) {}
            const word = line[s..i];
            const kind = classifyIdent(.zig, word, line, i);
            try push(out, allocator, s, i, kind);
            continue;
        }

        // operators / punctuation
        const s = i;
        i += 1;
        // multi-char ops
        if (s + 1 < line.len) {
            const two = line[s .. s + 2];
            if (std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "!=") or
                std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=") or
                std.mem.eql(u8, two, "=>") or std.mem.eql(u8, two, "->") or
                std.mem.eql(u8, two, "++") or std.mem.eql(u8, two, "--") or
                std.mem.eql(u8, two, "<<") or std.mem.eql(u8, two, ">>") or
                std.mem.eql(u8, two, "||") or std.mem.eql(u8, two, "&&") or
                std.mem.eql(u8, two, "+=") or std.mem.eql(u8, two, "-=") or
                std.mem.eql(u8, two, "*=") or std.mem.eql(u8, two, "/=") or
                std.mem.eql(u8, two, "..") or std.mem.eql(u8, two, ".*") or
                std.mem.eql(u8, two, ".?"))
            {
                i = s + 2;
            }
        }
        const ch = line[s];
        const kind: TokenKind = if (ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == '[' or ch == ']' or ch == ',' or ch == ';' or ch == ':')
            .punctuation
        else
            .operator;
        try push(out, allocator, s, i, kind);
    }
}

fn lexRust(line: []const u8, out: *std.ArrayListUnmanaged(Span), allocator: std.mem.Allocator) !void {
    var i: u32 = 0;
    while (i < line.len) {
        const c = line[i];

        if (c == ' ' or c == '\t') {
            const s = i;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            try push(out, allocator, s, i, .text);
            continue;
        }

        // // comment
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            try push(out, allocator, i, @intCast(line.len), .comment);
            return;
        }

        // attribute #[...]
        if (c == '#' and i + 1 < line.len and line[i + 1] == '[') {
            const s = i;
            i += 2;
            var depth: u32 = 1;
            while (i < line.len and depth > 0) : (i += 1) {
                if (line[i] == '[') depth += 1;
                if (line[i] == ']') depth -= 1;
            }
            try push(out, allocator, s, i, .attribute);
            continue;
        }

        // raw string r#"..."# or normal "
        if (c == 'r' and i + 1 < line.len and (line[i + 1] == '"' or line[i + 1] == '#')) {
            const s = i;
            i += 1;
            var hashes: u32 = 0;
            while (i < line.len and line[i] == '#') : (i += 1) hashes += 1;
            if (i < line.len and line[i] == '"') {
                i += 1;
                while (i < line.len) {
                    if (line[i] == '"') {
                        var h: u32 = 0;
                        var j = i + 1;
                        while (j < line.len and h < hashes and line[j] == '#') : (j += 1) h += 1;
                        if (h == hashes) {
                            i = j;
                            break;
                        }
                    }
                    i += 1;
                }
                try push(out, allocator, s, i, .string);
                continue;
            }
            // fallthrough as ident if not raw string
            i = s;
        }

        if (c == '"') {
            const s = i;
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (line[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try push(out, allocator, s, i, .string);
            continue;
        }

        if (c == '\'') {
            // lifetime 'a or char 'x'
            const s = i;
            i += 1;
            if (i < line.len and isIdentStart(line[i])) {
                while (i < line.len and isIdentCont(line[i])) : (i += 1) {}
                // if next is ' then char; else lifetime
                if (i < line.len and line[i] == '\'') {
                    i += 1;
                    try push(out, allocator, s, i, .string);
                } else {
                    try push(out, allocator, s, i, .attribute);
                }
                continue;
            }
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (line[i] == '\'') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try push(out, allocator, s, i, .string);
            continue;
        }

        if (isDigit(c)) {
            const s = i;
            if (c == '0' and i + 1 < line.len and (line[i + 1] == 'x' or line[i + 1] == 'b' or line[i + 1] == 'o')) {
                i += 2;
            }
            while (i < line.len and (isIdentCont(line[i]) or line[i] == '.' or line[i] == '\'')) : (i += 1) {}
            try push(out, allocator, s, i, .number);
            continue;
        }

        if (isIdentStart(c)) {
            const s = i;
            i += 1;
            while (i < line.len and isIdentCont(line[i])) : (i += 1) {}
            const word = line[s..i];
            const kind = classifyIdent(.rust, word, line, i);
            try push(out, allocator, s, i, kind);
            continue;
        }

        const s = i;
        i += 1;
        if (s + 1 < line.len) {
            const two = line[s .. s + 2];
            if (std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "!=") or
                std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=") or
                std.mem.eql(u8, two, "=>") or std.mem.eql(u8, two, "->") or
                std.mem.eql(u8, two, "::") or std.mem.eql(u8, two, "&&") or
                std.mem.eql(u8, two, "||") or std.mem.eql(u8, two, "<<") or
                std.mem.eql(u8, two, ">>") or std.mem.eql(u8, two, ".."))
            {
                i = s + 2;
            }
        }
        const ch = line[s];
        const kind: TokenKind = if (ch == '(' or ch == ')' or ch == '{' or ch == '}' or ch == '[' or ch == ']' or ch == ',' or ch == ';' or ch == ':')
            .punctuation
        else
            .operator;
        try push(out, allocator, s, i, kind);
    }
}

fn classifyIdent(lang: Language, word: []const u8, line: []const u8, after: u32) TokenKind {
    if (isKeyword(lang, word)) return .keyword;
    if (isConstant(word)) return .constant;

    // function call heuristic: name(
    var j = after;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
    if (j < line.len and line[j] == '(') return .function;

    // Type heuristic: starts with uppercase
    if (word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') return .type_name;

    return .text;
}

fn isConstant(word: []const u8) bool {
    return std.mem.eql(u8, word, "true") or
        std.mem.eql(u8, word, "false") or
        std.mem.eql(u8, word, "null") or
        std.mem.eql(u8, word, "undefined") or
        std.mem.eql(u8, word, "None") or
        std.mem.eql(u8, word, "Some") or
        std.mem.eql(u8, word, "Ok") or
        std.mem.eql(u8, word, "Err") or
        std.mem.eql(u8, word, "self") or
        std.mem.eql(u8, word, "Self");
}

fn isKeyword(lang: Language, word: []const u8) bool {
    const zig_kw = [_][]const u8{
        "addrspace", "align", "allowzero", "and",    "anyframe", "anytype", "asm",     "async",
        "await",     "break", "callconv",  "catch",  "comptime", "const",   "continue", "defer",
        "else",      "enum",  "errdefer",  "error",  "export",   "extern",  "fn",       "for",
        "if",        "inline","noalias",   "noinline","nosuspend","opaque", "or",       "orelse",
        "packed",    "pub",   "resume",    "return", "linksection", "struct", "suspend", "switch",
        "test",      "threadlocal", "try", "union",  "unreachable", "usingnamespace", "var", "volatile",
        "while",     "void",  "type",      "bool",   "f16", "f32", "f64", "f80", "f128",
        "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize",
        "c_char", "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong", "c_longlong", "c_ulonglong", "c_longdouble",
    };
    const rust_kw = [_][]const u8{
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
        "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while", "abstract", "become",
        "box", "do", "final", "macro", "override", "priv", "typeof", "unsized", "virtual", "yield",
        "try", "union", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64",
        "u128", "usize", "f32", "f64", "bool", "char", "str",
    };

    const list: []const []const u8 = switch (lang) {
        .zig => &zig_kw,
        .rust => &rust_kw,
        .unknown => &zig_kw,
    };
    for (list) |kw| {
        if (std.mem.eql(u8, kw, word)) return true;
    }
    return false;
}

test "highlight zig keywords and strings" {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(std.testing.allocator);
    try highlightLine(.zig, "pub fn main() void {", &spans, std.testing.allocator);
    try std.testing.expect(spans.items.len >= 3);
    try std.testing.expect(kindAt(spans.items, 0) == .keyword); // pub
}

test "highlight rust comment" {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    defer spans.deinit(std.testing.allocator);
    try highlightLine(.rust, "let x = 1; // hi", &spans, std.testing.allocator);
    const last = spans.items[spans.items.len - 1];
    try std.testing.expect(last.kind == .comment);
}
