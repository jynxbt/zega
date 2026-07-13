//! Lightweight diagnostics for bubble error boxes.
//! Structural checks always; Zig files can also run `zig ast-check` when an Io is available.

const std = @import("std");
const detect = @import("lang/detect.zig");

pub const Language = detect.Language;

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    severity: Severity = .err,
    /// Absolute 0-based document line.
    line: u32 = 0,
    col: u32 = 0,
    /// Owned message text.
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const DiagList = struct {
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn deinit(self: *DiagList, allocator: std.mem.Allocator) void {
        for (self.items.items) |*d| d.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *DiagList, allocator: std.mem.Allocator) void {
        for (self.items.items) |*d| d.deinit(allocator);
        self.items.clearRetainingCapacity();
    }
};

pub const AnalyzeOptions = struct {
    /// Run `zig ast-check` for Zig sources (needs a real path on disk + Io).
    zig_ast_check: bool = true,
};

/// Per-document diagnostics cache.
pub const DiagStore = struct {
    allocator: std.mem.Allocator,
    /// keyed by DocId
    map: std.AutoHashMapUnmanaged(u32, DiagList) = .empty,

    pub fn init(allocator: std.mem.Allocator) DiagStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *const DiagStore, doc_id: u32) []const Diagnostic {
        if (self.map.get(doc_id)) |list| return list.items.items;
        return &.{};
    }

    pub fn set(self: *DiagStore, doc_id: u32, list: DiagList) !void {
        const gop = try self.map.getOrPut(self.allocator, doc_id);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.allocator);
        }
        gop.value_ptr.* = list;
    }

    pub fn clearDoc(self: *DiagStore, doc_id: u32) void {
        if (self.map.fetchRemove(doc_id)) |kv| {
            var list = kv.value;
            list.deinit(self.allocator);
        }
    }

    /// Re-analyze a document and replace its cached diagnostics.
    pub fn refresh(
        self: *DiagStore,
        io: ?std.Io,
        doc_id: u32,
        path: []const u8,
        lang: Language,
        text: []const u8,
        options: AnalyzeOptions,
    ) !void {
        const list = try analyzeDocument(self.allocator, io, path, lang, text, options);
        try self.set(doc_id, list);
    }

    /// Count diagnostics whose line falls in [start_line, end_line).
    pub fn countInRange(
        self: *const DiagStore,
        doc_id: u32,
        start_line: u32,
        end_line: u32,
    ) usize {
        var n: usize = 0;
        for (self.get(doc_id)) |d| {
            if (d.line >= start_line and d.line < end_line) n += 1;
        }
        return n;
    }

    /// Append diagnostics in [start_line, end_line) into `out` (shallow: messages owned by store).
    pub fn forRange(
        self: *const DiagStore,
        doc_id: u32,
        start_line: u32,
        end_line: u32,
        out: *std.ArrayListUnmanaged(Diagnostic),
        allocator: std.mem.Allocator,
    ) !void {
        out.clearRetainingCapacity();
        for (self.get(doc_id)) |d| {
            if (d.line >= start_line and d.line < end_line) {
                try out.append(allocator, d);
            }
        }
    }
};

/// Run structural analysis + optional zig ast-check.
pub fn analyzeDocument(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    path: []const u8,
    lang: Language,
    text: []const u8,
    options: AnalyzeOptions,
) !DiagList {
    var list: DiagList = .{};
    errdefer list.deinit(allocator);

    try analyzeStructure(allocator, text, &list);

    if (options.zig_ast_check and lang == .zig and path.len > 0) {
        if (io) |i| {
            try analyzeZigAstCheck(allocator, i, path, &list);
        }
    }

    return list;
}

/// Unmatched braces / unclosed strings / empty critical issues.
pub fn analyzeStructure(
    allocator: std.mem.Allocator,
    text: []const u8,
    out: *DiagList,
) !void {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;

    var in_str = false;
    var in_char = false;
    var in_line_comment = false;
    var in_block_comment = false;
    var str_line: u32 = 0;
    var str_col: u32 = 0;

    // Stack of openers for better messages: type + line + col
    var stack: std.ArrayListUnmanaged(struct { ch: u8, line: u32, col: u32 }) = .empty;
    defer stack.deinit(allocator);

    while (i < text.len) : (i += 1) {
        const c = text[i];
        const n = if (i + 1 < text.len) text[i + 1] else 0;

        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
                line += 1;
                col = 0;
            } else col += 1;
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and n == '/') {
                in_block_comment = false;
                i += 1;
                col += 2;
                continue;
            }
            if (c == '\n') {
                line += 1;
                col = 0;
            } else col += 1;
            continue;
        }
        if (in_str) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                col += 2;
                continue;
            }
            if (c == '"') {
                in_str = false;
                col += 1;
                continue;
            }
            if (c == '\n') {
                try pushDiag(allocator, out, .err, str_line, str_col, "unclosed string literal");
                in_str = false;
                line += 1;
                col = 0;
                continue;
            }
            col += 1;
            continue;
        }
        if (in_char) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                col += 2;
                continue;
            }
            if (c == '\'') {
                in_char = false;
                col += 1;
                continue;
            }
            if (c == '\n') {
                try pushDiag(allocator, out, .err, line, col, "unclosed character literal");
                in_char = false;
                line += 1;
                col = 0;
                continue;
            }
            col += 1;
            continue;
        }

        if (c == '/' and n == '/') {
            in_line_comment = true;
            i += 1;
            col += 2;
            continue;
        }
        if (c == '/' and n == '*') {
            in_block_comment = true;
            i += 1;
            col += 2;
            continue;
        }
        if (c == '"') {
            in_str = true;
            str_line = line;
            str_col = col;
            col += 1;
            continue;
        }
        if (c == '\'') {
            in_char = true;
            col += 1;
            continue;
        }

        if (c == '(' or c == '[' or c == '{') {
            try stack.append(allocator, .{ .ch = c, .line = line, .col = col });
            col += 1;
            continue;
        }
        if (c == ')' or c == ']' or c == '}') {
            const want: u8 = switch (c) {
                ')' => '(',
                ']' => '[',
                else => '{',
            };
            if (stack.items.len == 0) {
                try pushDiag(allocator, out, .err, line, col, "unmatched closing delimiter");
            } else {
                const top = stack.items[stack.items.len - 1];
                if (top.ch != want) {
                    try pushDiag(allocator, out, .err, line, col, "mismatched closing delimiter");
                } else {
                    _ = stack.pop();
                }
            }
            col += 1;
            continue;
        }

        if (c == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }

    if (in_str) {
        try pushDiag(allocator, out, .err, str_line, str_col, "unclosed string literal");
    }
    if (in_block_comment) {
        try pushDiag(allocator, out, .err, line, col, "unclosed block comment");
    }
    // Report unclosed openers from the stack (most recent first, capped).
    var reported: usize = 0;
    var si = stack.items.len;
    while (si > 0 and reported < 8) {
        si -= 1;
        const o = stack.items[si];
        const msg = switch (o.ch) {
            '(' => "unclosed '('",
            '[' => "unclosed '['",
            '{' => "unclosed '{'",
            else => "unclosed delimiter",
        };
        try pushDiag(allocator, out, .err, o.line, o.col, msg);
        reported += 1;
    }
}

fn pushDiag(
    allocator: std.mem.Allocator,
    out: *DiagList,
    severity: Severity,
    line: u32,
    col: u32,
    msg: []const u8,
) !void {
    const copy = try allocator.dupe(u8, msg);
    try out.items.append(allocator, .{
        .severity = severity,
        .line = line,
        .col = col,
        .message = copy,
    });
}

/// Parse `zig ast-check path` stderr into diagnostics (best-effort).
/// Uses Zig 0.16 `std.process.run`. Skips quietly if zig is unavailable.
pub fn analyzeZigAstCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *DiagList,
) !void {
    // Skip non-existent paths (scratch / not yet saved).
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "ast-check", path },
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(4096),
        .timeout = .none,
    }) catch return; // zig missing / spawn failed — skip
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Lines like: path:line:col: error: message
    var it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (it.next()) |raw| {
        const line_s = std.mem.trim(u8, raw, " \t\r");
        if (line_s.len == 0) continue;
        if (std.mem.indexOf(u8, line_s, " error:") == null and
            std.mem.indexOf(u8, line_s, "error:") == null)
            continue;

        // Prefer pattern after last path separator (Windows paths may contain ':').
        const base_start = if (std.mem.lastIndexOfAny(u8, line_s, "/\\")) |p| p + 1 else 0;
        var colon1: ?usize = null;
        var colon2: ?usize = null;
        var colon3: ?usize = null;
        var j = base_start;
        while (j < line_s.len) : (j += 1) {
            if (line_s[j] == ':') {
                if (colon1 == null) colon1 = j else if (colon2 == null) colon2 = j else if (colon3 == null) {
                    colon3 = j;
                    break;
                }
            }
        }
        if (colon1 == null or colon2 == null or colon3 == null) {
            try pushDiag(allocator, out, .err, 0, 0, line_s);
            continue;
        }
        const line_str = line_s[colon1.? + 1 .. colon2.?];
        const col_str = line_s[colon2.? + 1 .. colon3.?];
        const rest = line_s[colon3.? + 1 ..];
        const line_num = std.fmt.parseInt(u32, line_str, 10) catch 1;
        const col_num = std.fmt.parseInt(u32, col_str, 10) catch 1;
        var msg = rest;
        if (std.mem.startsWith(u8, msg, " error:")) msg = msg[" error:".len..];
        if (std.mem.startsWith(u8, msg, "error:")) msg = msg["error:".len..];
        msg = std.mem.trim(u8, msg, " \t");
        try pushDiag(
            allocator,
            out,
            .err,
            if (line_num > 0) line_num - 1 else 0,
            if (col_num > 0) col_num - 1 else 0,
            msg,
        );
    }
}

test "structure detects unclosed brace" {
    var list: DiagList = .{};
    defer list.deinit(std.testing.allocator);
    try analyzeStructure(std.testing.allocator, "fn main() {\n  const x = 1;\n", &list);
    try std.testing.expect(list.items.items.len >= 1);
}

test "structure detects unclosed string" {
    var list: DiagList = .{};
    defer list.deinit(std.testing.allocator);
    try analyzeStructure(std.testing.allocator, "const s = \"hello\n", &list);
    try std.testing.expect(list.items.items.len >= 1);
}

test "structure clean code has no diags" {
    var list: DiagList = .{};
    defer list.deinit(std.testing.allocator);
    try analyzeStructure(std.testing.allocator, "fn main() void {\n  const x = 1;\n}\n", &list);
    try std.testing.expectEqual(@as(usize, 0), list.items.items.len);
}

test "DiagStore range filter" {
    var store = DiagStore.init(std.testing.allocator);
    defer store.deinit();

    var list: DiagList = .{};
    try pushDiag(std.testing.allocator, &list, .err, 2, 0, "a");
    try pushDiag(std.testing.allocator, &list, .err, 5, 0, "b");
    try pushDiag(std.testing.allocator, &list, .err, 10, 0, "c");
    try store.set(1, list);

    try std.testing.expectEqual(@as(usize, 1), store.countInRange(1, 0, 5));
    try std.testing.expectEqual(@as(usize, 2), store.countInRange(1, 2, 6));
    try std.testing.expectEqual(@as(usize, 0), store.countInRange(1, 6, 9));
}
