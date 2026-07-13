//! Lightweight Zig completions (no LSP). Keywords, builtins, and identifiers
//! from open document sources — file + working-set aware.

const std = @import("std");

pub const Kind = enum {
    keyword,
    builtin,
    symbol,
};

pub const Candidate = struct {
    /// Text inserted on accept (owned when returned from suggestOwned).
    label: []const u8,
    kind: Kind,
    /// Lower is better.
    score: i32 = 0,
};

pub const max_results: usize = 12;

/// Options for a completion query.
pub const SuggestOpts = struct {
    prefix: []const u8,
    /// When true (caret after `.`), skip keywords; prefer symbols/builtins.
    after_dot: bool = false,
    /// Source buffers to scan for identifiers (current file + open docs).
    sources: []const []const u8 = &.{},
};

pub fn kindTag(k: Kind) []const u8 {
    return switch (k) {
        .keyword => "kw",
        .builtin => "bi",
        .symbol => "sym",
    };
}

pub fn zigKeywords() []const []const u8 {
    return &[_][]const u8{
        "addrspace",  "align",      "allowzero",  "and",        "anyframe",
        "anytype",    "asm",        "async",      "await",      "break",
        "callconv",   "catch",      "comptime",   "const",      "continue",
        "defer",      "else",       "enum",       "errdefer",   "error",
        "export",     "extern",     "fn",         "for",        "if",
        "inline",     "noalias",    "noinline",   "nosuspend",  "opaque",
        "or",         "orelse",     "packed",     "pub",        "resume",
        "return",     "linksection","struct",     "suspend",    "switch",
        "test",       "threadlocal","try",        "union",      "unreachable",
        "usingnamespace", "var",    "volatile",   "while",      "true",
        "false",      "null",       "undefined",
    };
}

pub fn zigBuiltins() []const []const u8 {
    return &[_][]const u8{
        "@addWithOverflow", "@alignCast",     "@alignOf",         "@as",
        "@asyncCall",       "@atomicLoad",    "@atomicRmw",       "@atomicStore",
        "@bitCast",         "@bitOffsetOf",   "@bitSizeOf",       "@breakpoint",
        "@mulAdd",          "@byteSwap",      "@bitReverse",      "@offsetOf",
        "@call",            "@cDefine",       "@cImport",         "@cInclude",
        "@clz",             "@cmpxchgStrong", "@cmpxchgWeak",     "@compileError",
        "@compileLog",      "@constCast",     "@ctz",             "@cUndef",
        "@cVaArg",          "@cVaCopy",       "@cVaEnd",          "@cVaStart",
        "@divExact",        "@divFloor",      "@divTrunc",        "@embedFile",
        "@enumFromInt",     "@errorFromInt",  "@errorName",       "@errorReturnTrace",
        "@errorCast",       "@export",        "@extern",          "@fence",
        "@field",           "@fieldParentPtr","@floatCast",       "@floatFromInt",
        "@frameAddress",    "@hasDecl",       "@hasField",        "@import",
        "@inComptime",      "@intCast",       "@intFromBool",     "@intFromEnum",
        "@intFromError",    "@intFromFloat",  "@intFromPtr",      "@max",
        "@memcpy",          "@memset",        "@min",             "@wasmMemorySize",
        "@wasmMemoryGrow",  "@mod",           "@mulWithOverflow", "@panic",
        "@popCount",        "@prefetch",      "@ptrCast",         "@ptrFromInt",
        "@rem",             "@returnAddress", "@select",          "@setEvalBranchQuota",
        "@setFloatMode",    "@setRuntimeSafety", "@shlExact",     "@shlWithOverflow",
        "@shrExact",        "@shuffle",       "@sizeOf",          "@splat",
        "@reduce",          "@src",           "@sqrt",            "@sin",
        "@cos",             "@tan",           "@exp",             "@exp2",
        "@log",             "@log2",          "@log10",           "@abs",
        "@floor",           "@ceil",          "@trunc",           "@round",
        "@subWithOverflow", "@tagName",       "@This",            "@trap",
        "@truncate",        "@Type",          "@typeInfo",        "@typeName",
        "@TypeOf",          "@unionInit",     "@Vector",          "@volatileCast",
        "@workGroupId",     "@workGroupSize", "@workItemId",
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '@';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Scan `source` for identifier-like tokens (skips // comments and simple strings).
pub fn scanIdentifiers(source: []const u8, out: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    var in_line_comment = false;
    var in_block_comment = false;
    var in_str = false;
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

        if (isIdentStart(c) and c != '@') {
            const start = i;
            i += 1;
            while (i < source.len and isIdentCont(source[i])) : (i += 1) {}
            const id = source[start..i];
            if (id.len >= 2) {
                try out.put(allocator, id, {});
            }
            continue;
        }
        i += 1;
    }
}

fn startsWithIgnoreCase(hay: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (hay.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..prefix.len], prefix);
}

fn scoreMatch(label: []const u8, prefix: []const u8, kind: Kind) i32 {
    if (prefix.len == 0) {
        return switch (kind) {
            .symbol => 10,
            .keyword => 20,
            .builtin => 30,
        };
    }
    if (!startsWithIgnoreCase(label, prefix)) return std.math.maxInt(i32);
    var s: i32 = @intCast(label.len); // shorter first
    if (!std.mem.startsWith(u8, label, prefix)) s += 5; // case-insensitive only
    s += switch (kind) {
        .symbol => 0,
        .keyword => 15,
        .builtin => 8,
    };
    return s;
}

/// Build ranked completion list. Caller owns returned slice of Candidates whose
/// `label` points into static tables or into `sources` (not owned duplicates).
/// Labels are NOT allocated — valid while sources remain alive.
pub fn suggest(
    allocator: std.mem.Allocator,
    opts: SuggestOpts,
    out: *std.ArrayListUnmanaged(Candidate),
) !void {
    out.clearRetainingCapacity();
    const prefix = opts.prefix;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var raw: std.ArrayListUnmanaged(Candidate) = .empty;
    defer raw.deinit(allocator);

    if (!opts.after_dot) {
        for (zigKeywords()) |kw| {
            const sc = scoreMatch(kw, prefix, .keyword);
            if (sc == std.math.maxInt(i32)) continue;
            if (seen.contains(kw)) continue;
            try seen.put(allocator, kw, {});
            try raw.append(allocator, .{ .label = kw, .kind = .keyword, .score = sc });
        }
    }

    // Builtins: match with or without leading @ in prefix.
    const bi_prefix = if (prefix.len > 0 and prefix[0] == '@') prefix else prefix;
    for (zigBuiltins()) |bi| {
        const sc = scoreMatch(bi, bi_prefix, .builtin);
        // Also allow prefix without @ matching @import
        const sc2 = if (prefix.len > 0 and prefix[0] != '@' and bi.len > 1)
            scoreMatch(bi[1..], prefix, .builtin)
        else
            std.math.maxInt(i32);
        const best = @min(sc, sc2);
        if (best == std.math.maxInt(i32)) continue;
        if (seen.contains(bi)) continue;
        try seen.put(allocator, bi, {});
        try raw.append(allocator, .{ .label = bi, .kind = .builtin, .score = best });
    }

    var idents: std.StringHashMapUnmanaged(void) = .empty;
    defer idents.deinit(allocator);
    for (opts.sources) |src| {
        try scanIdentifiers(src, &idents, allocator);
    }
    var it = idents.keyIterator();
    while (it.next()) |key_ptr| {
        const id = key_ptr.*;
        const sc = scoreMatch(id, prefix, .symbol);
        if (sc == std.math.maxInt(i32)) continue;
        if (seen.contains(id)) continue;
        try seen.put(allocator, id, {});
        try raw.append(allocator, .{ .label = id, .kind = .symbol, .score = sc });
    }

    std.mem.sort(Candidate, raw.items, {}, struct {
        fn less(_: void, a: Candidate, b: Candidate) bool {
            if (a.score != b.score) return a.score < b.score;
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.less);

    const n = @min(raw.items.len, max_results);
    try out.appendSlice(allocator, raw.items[0..n]);
}

/// Extract the identifier (or @builtin) prefix left of `col` on `line`.
/// Also reports whether the caret is in a member-access position after `.`.
pub fn prefixAt(line: []const u8, col: u32) struct { prefix: []const u8, after_dot: bool } {
    const c = @min(col, @as(u32, @intCast(line.len)));
    if (c == 0) return .{ .prefix = "", .after_dot = false };

    var i: usize = c;
    // Include @ in builtins.
    while (i > 0) {
        const ch = line[i - 1];
        if (isIdentCont(ch) or ch == '@') {
            i -= 1;
            continue;
        }
        break;
    }
    const prefix = line[i..c];

    var after_dot = false;
    if (i > 0 and line[i - 1] == '.') {
        after_dot = true;
    } else if (prefix.len == 0 and c > 0 and line[c - 1] == '.') {
        after_dot = true;
    }
    return .{ .prefix = prefix, .after_dot = after_dot };
}

// --- tests ---

test "prefixAt extracts identifier" {
    const line = "    const foo_bar = 1;";
    // caret after "foo"
    const p = prefixAt(line, 12); // "    const fo" → positions: 4=c of const... let's compute
    // "    const " = 10 chars, then foo_bar
    // col 13 = after "foo"
    const p2 = prefixAt("    const foo_bar", 13);
    try std.testing.expectEqualStrings("foo", p2.prefix);
    _ = p;
}

test "prefixAt after dot" {
    const p = prefixAt("obj.", 4);
    try std.testing.expect(p.after_dot);
    try std.testing.expectEqualStrings("", p.prefix);
    const p2 = prefixAt("obj.na", 6);
    try std.testing.expect(p2.after_dot);
    try std.testing.expectEqualStrings("na", p2.prefix);
}

test "suggest keywords for co" {
    var list: std.ArrayListUnmanaged(Candidate) = .empty;
    defer list.deinit(std.testing.allocator);
    try suggest(std.testing.allocator, .{ .prefix = "co" }, &list);
    try std.testing.expect(list.items.len >= 1);
    var found_const = false;
    for (list.items) |c| {
        if (std.mem.eql(u8, c.label, "const")) found_const = true;
    }
    try std.testing.expect(found_const);
}

test "suggest symbols from source" {
    const src =
        \\fn loadConfig() void {}
        \\fn main() void { loadConfig(); }
        \\
    ;
    var list: std.ArrayListUnmanaged(Candidate) = .empty;
    defer list.deinit(std.testing.allocator);
    try suggest(std.testing.allocator, .{
        .prefix = "load",
        .sources = &.{src},
    }, &list);
    var found = false;
    for (list.items) |c| {
        if (std.mem.eql(u8, c.label, "loadConfig")) found = true;
    }
    try std.testing.expect(found);
}

test "suggest builtin import" {
    var list: std.ArrayListUnmanaged(Candidate) = .empty;
    defer list.deinit(std.testing.allocator);
    try suggest(std.testing.allocator, .{ .prefix = "@im" }, &list);
    var found = false;
    for (list.items) |c| {
        if (std.mem.eql(u8, c.label, "@import")) found = true;
    }
    try std.testing.expect(found);
}
