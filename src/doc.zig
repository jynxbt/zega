//! Document model — shared source of truth for fragment bubbles.
//! Pattern borrowed from flow's Buffer.Manager (path-keyed open).

const std = @import("std");
const detect = @import("lang/detect.zig");

pub const Language = detect.Language;
pub const DocId = u32;
pub const INVALID_DOC: DocId = std.math.maxInt(DocId);

pub const max_file_bytes: usize = 16 * 1024 * 1024;

pub const EolMode = enum { lf, crlf };

pub const Document = struct {
    id: DocId,
    /// Absolute or project-relative path (owned).
    path: []u8,
    lang: Language,
    /// Full source bytes (owned). Always uses `\n` internally; `eol` for save.
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    /// Byte offset of the start of each line. Length == line count.
    line_starts: std.ArrayListUnmanaged(u32) = .empty,
    dirty: bool = false,
    eol: EolMode = .lf,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.bytes.deinit(allocator);
        self.line_starts.deinit(allocator);
        self.* = undefined;
    }

    pub fn lineCount(self: *const Document) u32 {
        return @intCast(self.line_starts.items.len);
    }

    pub fn rebuildLineIndex(self: *Document, allocator: std.mem.Allocator) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(allocator, 0);
        const src = self.bytes.items;
        var i: u32 = 0;
        while (i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                try self.line_starts.append(allocator, i + 1);
            }
        }
        // If file ends with newline, last entry points past end — still valid empty line.
        // If last char isn't newline, last line is covered by last start.
    }

    /// Byte offset of line start. Line must be < lineCount().
    pub fn lineStartOffset(self: *const Document, line: u32) u32 {
        return self.line_starts.items[line];
    }

    /// Slice of a single line without trailing `\n`.
    pub fn lineSlice(self: *const Document, line: u32) []const u8 {
        if (line >= self.lineCount()) return &.{};
        const start = self.line_starts.items[line];
        const end: u32 = if (line + 1 < self.lineCount())
            self.line_starts.items[line + 1]
        else
            @intCast(self.bytes.items.len);
        var s = self.bytes.items[start..end];
        if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
        if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
        return s;
    }

    /// Half-open line range [start_line, end_line) as contiguous bytes (includes newlines between).
    pub fn rangeSlice(self: *const Document, start_line: u32, end_line: u32) []const u8 {
        const lc = self.lineCount();
        if (start_line >= lc or start_line >= end_line) return &.{};
        const end_l = @min(end_line, lc);
        const start = self.line_starts.items[start_line];
        const end_off: u32 = if (end_l < lc)
            self.line_starts.items[end_l]
        else
            @intCast(self.bytes.items.len);
        return self.bytes.items[start..end_off];
    }

    /// Byte offset for (line, col) within document. col is char index into line (ASCII).
    pub fn offsetAt(self: *const Document, line: u32, col: u32) u32 {
        if (line >= self.lineCount()) return @intCast(self.bytes.items.len);
        const line_bytes = self.lineSlice(line);
        const c = @min(col, @as(u32, @intCast(line_bytes.len)));
        return self.line_starts.items[line] + c;
    }

    /// Convert byte offset to (line, col).
    pub fn lineColAt(self: *const Document, offset: u32) struct { line: u32, col: u32 } {
        const starts = self.line_starts.items;
        if (starts.len == 0) return .{ .line = 0, .col = 0 };
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (starts[mid] <= offset) lo = mid else hi = mid;
        }
        const line: u32 = @intCast(lo);
        const col = offset -% starts[lo];
        return .{ .line = line, .col = col };
    }

    pub fn insert(self: *Document, allocator: std.mem.Allocator, offset: u32, text: []const u8) !void {
        const off: usize = @min(@as(usize, offset), self.bytes.items.len);
        try self.bytes.insertSlice(allocator, off, text);
        try self.rebuildLineIndex(allocator);
        self.dirty = true;
    }

    pub fn delete(self: *Document, allocator: std.mem.Allocator, offset: u32, len: u32) !void {
        const start: usize = @min(@as(usize, offset), self.bytes.items.len);
        const end: usize = @min(start + @as(usize, len), self.bytes.items.len);
        if (end <= start) return;
        try self.bytes.replaceRange(allocator, start, end - start, &.{});
        try self.rebuildLineIndex(allocator);
        self.dirty = true;
    }

    /// Write full buffer to `path` (absolute or cwd-relative) and clear dirty.
    pub fn save(self: *Document, io: std.Io) !void {
        if (self.path.len == 0) return error.EmptyPath;

        // Prefer an absolute path so saves don't depend on process cwd after launch.
        var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const write_path: []const u8 = blk: {
            // If already absolute, use as-is.
            if (self.path.len > 0 and self.path[0] == '/') break :blk self.path;
            // Resolve relative path against cwd when possible.
            if (std.Io.Dir.cwd().realPathFile(io, self.path, &abs_buf)) |n| {
                break :blk abs_buf[0..n];
            } else |_| {
                break :blk self.path;
            }
        };

        const file = try std.Io.Dir.cwd().createFile(io, write_path, .{
            .truncate = true,
        });
        errdefer file.close(io);

        if (self.eol == .lf) {
            try file.writeStreamingAll(io, self.bytes.items);
        } else {
            var i: usize = 0;
            while (i < self.bytes.items.len) : (i += 1) {
                if (self.bytes.items[i] == '\n') {
                    try file.writeStreamingAll(io, "\r\n");
                } else {
                    try file.writeStreamingAll(io, self.bytes.items[i .. i + 1]);
                }
            }
        }
        // Force data to disk before we claim success.
        file.sync(io) catch {};
        file.close(io);

        self.dirty = false;
    }
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    docs: std.ArrayListUnmanaged(Document) = .empty,
    /// path → index in docs
    by_path: std.StringHashMapUnmanaged(DocId) = .empty,
    next_id: DocId = 1,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) DocumentStore {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *DocumentStore) void {
        for (self.docs.items) |*d| d.deinit(self.allocator);
        self.docs.deinit(self.allocator);
        // keys owned as doc.path — don't free twice; only free map structure
        self.by_path.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *DocumentStore, id: DocId) ?*Document {
        for (self.docs.items) |*d| {
            if (d.id == id) return d;
        }
        return null;
    }

    pub fn getConst(self: *const DocumentStore, id: DocId) ?*const Document {
        for (self.docs.items) |*d| {
            if (d.id == id) return d;
        }
        return null;
    }

    pub fn openFile(self: *DocumentStore, path: []const u8) !DocId {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs: []const u8 = blk: {
            const n = std.Io.Dir.cwd().realPathFile(self.io, path, &path_buf) catch break :blk path;
            break :blk path_buf[0..n];
        };

        if (self.by_path.get(abs)) |id| return id;

        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const st = try file.stat(self.io);
        if (st.size > max_file_bytes) return error.FileTooLarge;

        const raw = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(raw);
        const nread = try file.readPositionalAll(self.io, raw, 0);
        const raw_slice = raw[0..nread];

        var eol: EolMode = .lf;
        if (std.mem.indexOf(u8, raw_slice, "\r\n") != null) eol = .crlf;

        // Normalize to LF in memory.
        var normalized: std.ArrayListUnmanaged(u8) = .empty;
        errdefer normalized.deinit(self.allocator);
        try normalized.ensureTotalCapacity(self.allocator, raw_slice.len);
        var i: usize = 0;
        while (i < raw_slice.len) {
            if (raw_slice[i] == '\r' and i + 1 < raw_slice.len and raw_slice[i + 1] == '\n') {
                try normalized.append(self.allocator, '\n');
                i += 2;
            } else if (raw_slice[i] == '\r') {
                try normalized.append(self.allocator, '\n');
                i += 1;
            } else {
                try normalized.append(self.allocator, raw_slice[i]);
                i += 1;
            }
        }

        const id = self.next_id;
        self.next_id += 1;
        const path_owned = try self.allocator.dupe(u8, abs);

        var doc = Document{
            .id = id,
            .path = path_owned,
            .lang = detect.fromPath(path),
            .bytes = normalized,
            .eol = eol,
        };
        try doc.rebuildLineIndex(self.allocator);
        try self.docs.append(self.allocator, doc);
        try self.by_path.put(self.allocator, path_owned, id);
        return id;
    }

    /// Open from in-memory content with a save path (relative or absolute).
    /// Does not read existing disk files (unlike openFile) — used for tests and embeds.
    pub fn openScratch(self: *DocumentStore, path: []const u8, content: []const u8, lang: Language) !DocId {
        if (self.by_path.get(path)) |id| return id;

        const id = self.next_id;
        self.next_id += 1;
        const path_owned = try self.allocator.dupe(u8, path);

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        try bytes.appendSlice(self.allocator, content);

        var doc = Document{
            .id = id,
            .path = path_owned,
            .lang = lang,
            .bytes = bytes,
            .eol = .lf,
        };
        try doc.rebuildLineIndex(self.allocator);
        try self.docs.append(self.allocator, doc);
        try self.by_path.put(self.allocator, path_owned, id);
        return id;
    }

    /// Write `content` to `path` if missing, then openFile (absolute path, durable saves).
    pub fn openOrCreate(self: *DocumentStore, path: []const u8, content: []const u8) !DocId {
        if (self.openFile(path)) |id| return id else |_| {}
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = content,
            .flags = .{ .truncate = true },
        });
        return try self.openFile(path);
    }

    pub fn saveAll(self: *DocumentStore) !void {
        for (self.docs.items) |*d| {
            if (d.dirty) try d.save(self.io);
        }
    }

    pub fn saveDoc(self: *DocumentStore, id: DocId) !void {
        const d = self.get(id) orelse return error.UnknownDocument;
        try d.save(self.io);
    }
};

test "save roundtrip writes full buffer" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const path = "src/testdata/_zega_save_roundtrip.zig";
    const original = "pub fn hello() void {\n    // full file\n}\n";
    const id = try store.openOrCreate(path, original);
    const d = store.get(id).?;
    try d.insert(std.testing.allocator, 0, "// edited\n");
    try std.testing.expect(d.dirty);
    try d.save(std.testing.io);
    try std.testing.expect(!d.dirty);

    // Re-open from disk and check content.
    var store2 = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store2.deinit();
    const id2 = try store2.openFile(path);
    const d2 = store2.get(id2).?;
    try std.testing.expect(std.mem.startsWith(u8, d2.bytes.items, "// edited\n"));
    try std.testing.expect(std.mem.indexOf(u8, d2.bytes.items, "full file") != null);

    // Cleanup probe file.
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "document line index and range" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const id = try store.openScratch("t.zig", "line0\nline1\nline2\n", .zig);
    const d = store.get(id).?;
    try std.testing.expectEqual(@as(u32, 4), d.lineCount()); // trailing empty after final \n
    try std.testing.expectEqualStrings("line0", d.lineSlice(0));
    try std.testing.expectEqualStrings("line1", d.lineSlice(1));
    const r = d.rangeSlice(0, 2);
    try std.testing.expect(std.mem.eql(u8, r, "line0\nline1\n") or std.mem.startsWith(u8, r, "line0\nline1"));
}

test "insert and delete" {
    var store = DocumentStore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const id = try store.openScratch("t.zig", "abc\n", .zig);
    const d = store.get(id).?;
    try d.insert(std.testing.allocator, 1, "X");
    try std.testing.expectEqualStrings("aXbc", d.lineSlice(0));
    try d.delete(std.testing.allocator, 1, 1);
    try std.testing.expectEqualStrings("abc", d.lineSlice(0));
}
