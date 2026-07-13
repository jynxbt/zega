//! Open files → outline → place bubbles on the canvas.

const std = @import("std");
const geom = @import("geom.zig");
const doc_mod = @import("doc.zig");
const bubble_mod = @import("bubble.zig");
const canvas_mod = @import("canvas.zig");
const outline_mod = @import("lang/outline.zig");
const detect = @import("lang/detect.zig");
const font_mod = @import("font.zig");
const text_mod = @import("text.zig");
const spacer = @import("spacer.zig");

pub const DocumentStore = doc_mod.DocumentStore;
pub const Canvas = canvas_mod.Canvas;

pub const OpenLimits = struct {
    max_files: u32 = 20,
    max_bubbles: u32 = 100,
    max_depth: u32 = 6,
};

/// Layout constants (world units).
const origin_x: f32 = 40;
const origin_y: f32 = 40;
const gap_x: f32 = 28;
const gap_y: f32 = 24;
/// Wide enough for typical Zig signatures without harsh mid-expression wraps.
const bubble_w: f32 = 440;
const row_wrap_w: f32 = 1600;
const min_bubble_h: f32 = 72;
/// Soft cap — prefer fitting content; only clamp pathological giants.
const max_bubble_h: f32 = 1400;

pub fn openPath(
    store: *DocumentStore,
    canvas: *Canvas,
    path: []const u8,
    limits: OpenLimits,
    bubble_count: *u32,
) !void {
    const io = store.io;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (st.kind == .directory) {
        try walkDir(store, canvas, path, limits, 0, bubble_count);
    } else {
        try openFile(store, canvas, path, limits, bubble_count);
    }
}

fn walkDir(
    store: *DocumentStore,
    canvas: *Canvas,
    path: []const u8,
    limits: OpenLimits,
    depth: u32,
    bubble_count: *u32,
) !void {
    if (depth > limits.max_depth) return;
    if (bubble_count.* >= limits.max_bubbles) return;

    const io = store.io;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var files_opened: u32 = 0;
    while (try it.next(io)) |entry| {
        if (bubble_count.* >= limits.max_bubbles) break;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "zig-cache") or
            std.mem.eql(u8, entry.name, "zig-out") or
            std.mem.eql(u8, entry.name, "target") or
            std.mem.eql(u8, entry.name, "node_modules") or
            std.mem.eql(u8, entry.name, ".zig-cache"))
            continue;

        var sub_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ path, entry.name });

        switch (entry.kind) {
            .directory => try walkDir(store, canvas, sub, limits, depth + 1, bubble_count),
            .file => {
                if (!detect.isSupported(entry.name)) continue;
                if (files_opened >= limits.max_files) continue;
                try openFile(store, canvas, sub, limits, bubble_count);
                files_opened += 1;
            },
            else => {},
        }
    }
}

pub fn openFile(
    store: *DocumentStore,
    canvas: *Canvas,
    path: []const u8,
    limits: OpenLimits,
    bubble_count: *u32,
) !void {
    if (bubble_count.* >= limits.max_bubbles) return;
    if (!detect.isSupported(path)) return;

    const doc_id = try store.openFile(path);
    const doc = store.get(doc_id) orelse return error.UnknownDocument;

    var items: std.ArrayListUnmanaged(outline_mod.OutlineItem) = .empty;
    defer items.deinit(store.allocator);
    try outline_mod.outline(store.allocator, doc.bytes.items, doc.lang, &items);

    const base = std.fs.path.basename(path);
    const start_count = bubble_count.*;

    // Outline items only (imports, functions, types). No whole-file preview bubble.
    for (items.items) |item| {
        if (bubble_count.* >= limits.max_bubbles) break;
        // Skip outline item that is already the whole file.
        if (item.start_line == 0 and item.end_line >= doc.lineCount() and std.mem.eql(u8, item.name, base))
            continue;
        try placeBubble(store, canvas, doc_id, base, item, bubble_count);
    }

    // Paper 1-M: wire call edges from fragment text (name().
    try seedCallLinks(canvas, store, start_count);
}

/// Seed call edges from fragment text: if bubble A body contains `B(` and B is
/// another outline bubble in this batch, connect A → B. Caps edges to avoid spaghetti.
fn seedCallLinks(canvas: *Canvas, store: *DocumentStore, from_index: u32) !void {
    const start: usize = from_index;
    if (start >= canvas.bubbles.items.len) return;

    const batch = canvas.bubbles.items[start..];
    if (batch.len < 2) return;

    const max_edges: usize = 24;
    var edges: usize = 0;

    // Extract call symbol from title "name - file" or "Type.method - file".
    const nameOf = struct {
        fn go(title: []const u8) []const u8 {
            // Import bubbles are not call targets.
            if (std.mem.startsWith(u8, title, "[import")) return &.{};
            const base = if (std.mem.indexOf(u8, title, " - ")) |i| title[0..i] else title;
            // Methods are titled Type.method — match bare method name in call sites.
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| return base[d + 1 ..];
            return base;
        }
    }.go;

    for (batch) |caller| {
        if (edges >= max_edges) break;
        if (caller.kind == .imports) continue;
        const f = caller.fragment() orelse continue;
        const doc = store.getConst(f.doc) orelse continue;
        const body = doc.rangeSlice(f.start_line, f.end_line);
        const caller_name = nameOf(caller.title);

        for (batch) |callee| {
            if (edges >= max_edges) break;
            if (caller.id == callee.id) continue;
            if (callee.kind == .imports) continue;
            const callee_name = nameOf(callee.title);
            if (callee_name.len < 2) continue;
            if (std.mem.eql(u8, caller_name, callee_name)) continue;

            if (findCall(body, callee_name)) |call| {
                if (!hasConnection(canvas, caller.id, callee.id)) {
                    const abs_line = f.start_line + call.line_in_body;
                    _ = try canvas.connectEx(
                        caller.id,
                        callee.id,
                        abs_line,
                        call.col_start,
                        call.col_end,
                    );
                    edges += 1;
                }
            }
        }
    }
}

fn hasConnection(canvas: *const Canvas, from: bubble_mod.BubbleId, to: bubble_mod.BubbleId) bool {
    for (canvas.connections.items) |c| {
        if (c.from.bubble == from and c.to.bubble == to) return true;
    }
    return false;
}

const CallSite = struct {
    /// 0-based line within the fragment body.
    line_in_body: u32,
    /// Columns of the name within that line [start, end).
    col_start: u32,
    col_end: u32,
};

/// First call-like use of `name` (name followed by '(').
fn findCall(body: []const u8, name: []const u8) ?CallSite {
    var i: usize = 0;
    var line: u32 = 0;
    var line_start: usize = 0;
    while (i + name.len < body.len) : (i += 1) {
        if (body[i] == '\n') {
            line += 1;
            line_start = i + 1;
            continue;
        }
        if (!std.mem.startsWith(u8, body[i..], name)) continue;
        if (i > 0) {
            const p = body[i - 1];
            if (std.ascii.isAlphanumeric(p) or p == '_') continue;
        }
        const after = i + name.len;
        var j = after;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t')) : (j += 1) {}
        if (j < body.len and body[j] == '(') {
            const col_start: u32 = @intCast(i - line_start);
            const col_end: u32 = @intCast(after - line_start);
            return .{ .line_in_body = line, .col_start = col_start, .col_end = col_end };
        }
    }
    return null;
}

fn placeBubble(
    store: *DocumentStore,
    canvas: *Canvas,
    doc_id: doc_mod.DocId,
    file_base: []const u8,
    item: outline_mod.OutlineItem,
    bubble_count: *u32,
) !void {
    const logical_lines: u32 = if (item.end_line > item.start_line) item.end_line - item.start_line else 1;
    const lh = font_mod.Font.charH();
    const pad_x: f32 = 8;
    const pad_y: f32 = 22;

    const bkind: bubble_mod.BubbleKind = if (item.kind == .import) .imports else .code;
    // Import groups stay a bit narrower so they read as chrome, not a method.
    const w: f32 = if (item.kind == .import) @min(bubble_w, 360) else bubble_w;

    // Height must fit *display* lines after soft-wrap, not just logical lines.
    // Otherwise long lines (e.g. App.stats return) overflow and the caret escapes the bubble.
    const content_w = @max(0, w - pad_x * 2);
    const max_cols = text_mod.maxColsForWidth(content_w);
    var display_lines: u32 = logical_lines;
    if (store.getConst(doc_id)) |doc| {
        const body = doc.rangeSlice(item.start_line, item.end_line);
        const n = text_mod.reflowCount(body, max_cols);
        display_lines = @max(logical_lines, @as(u32, @intCast(n)));
    }
    // Title strip + bottom pad + one line of slack so the last row/caret stays inside.
    var h = pad_y + pad_x + @as(f32, @floatFromInt(display_lines + 1)) * lh;
    h = std.math.clamp(h, min_bubble_h, max_bubble_h);
    if (item.kind == .import) {
        h = std.math.clamp(h, 56, 220);
    }

    // Pack left-to-right, wrap. Row step tracks typical bubble height, not the soft max.
    const idx = bubble_count.*;
    const col_w = bubble_w + gap_x;
    const approx_cols = @max(1, @as(u32, @intFromFloat(row_wrap_w / col_w)));
    const col = idx % approx_cols;
    const row = idx / approx_cols;
    const row_step = 220.0 + gap_y;

    const x = origin_x + @as(f32, @floatFromInt(col)) * col_w;
    const y = origin_y + @as(f32, @floatFromInt(row)) * row_step;

    const id = try canvas.addBubble(bkind, .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
    });
    const b = canvas.findBubble(id).?;
    b.line_height = lh;
    b.pad_x = pad_x;
    b.pad_y = pad_y;
    b.setFragment(doc_id, item.start_line, item.end_line);

    var title_buf: [320]u8 = undefined;
    // ASCII separator only (font atlas is printable ASCII).
    const title = if (item.kind == .import) blk: {
        if (std.mem.eql(u8, item.name, "imports"))
            break :blk try std.fmt.bufPrint(&title_buf, "[imports] {s}", .{file_base});
        break :blk try std.fmt.bufPrint(&title_buf, "[import] {s} - {s}", .{ item.name, file_base });
    } else if (item.parent_name) |parent|
        try std.fmt.bufPrint(&title_buf, "{s}.{s} - {s}", .{ parent, item.name, file_base })
    else
        try std.fmt.bufPrint(&title_buf, "{s} - {s}", .{ item.name, file_base });
    try b.setTitleOwned(store.allocator, title);

    var key_buf: [512]u8 = undefined;
    const key = if (item.parent_name) |parent|
        try std.fmt.bufPrint(&key_buf, "{s}:{d}-{d}:{s}.{s}", .{
            file_base,
            item.start_line,
            item.end_line,
            parent,
            item.name,
        })
    else
        try std.fmt.bufPrint(&key_buf, "{s}:{d}-{d}:{s}", .{
            file_base,
            item.start_line,
            item.end_line,
            item.name,
        });
    try b.setFragmentKeyOwned(store.allocator, key);

    bubble_count.* += 1;
}

/// Create a new on-disk source file near `world` and open it as bubble(s).
pub fn createNewFile(
    store: *DocumentStore,
    canvas: *Canvas,
    world: geom.Vec2,
    lang: detect.Language,
) !void {
    const ext: []const u8 = switch (lang) {
        .rust => ".rs",
        else => ".zig",
    };
    const template: []const u8 = switch (lang) {
        .rust =>
        \\fn main() {
        \\    
        \\}
        \\
        ,
        else =>
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    
        \\}
        \\
        ,
    };

    var path_buf: [128]u8 = undefined;
    const path = try uniqueUntitledPath(store, &path_buf, ext);

    // Write file to disk.
    {
        const file = try std.Io.Dir.cwd().createFile(store.io, path, .{ .exclusive = true });
        defer file.close(store.io);
        try file.writeStreamingAll(store.io, template);
    }

    const before = canvas.bubbles.items.len;
    var count: u32 = @intCast(before);
    try openFile(store, canvas, path, .{}, &count);

    // Move newly added bubbles near the click position.
    if (canvas.bubbles.items.len > before) {
        const first = &canvas.bubbles.items[before];
        const dx = world.x - first.bounds.x;
        const dy = world.y - first.bounds.y;
        for (canvas.bubbles.items[before..]) |*b| {
            b.translate(.{ .x = dx, .y = dy });
        }
        // Settle overlaps from the first new bubble.
        _ = try spacer.resolveDefault(canvas, first.id);
        try spacer.recomputeWorkingSets(canvas);
    }
}

fn uniqueUntitledPath(store: *DocumentStore, buf: []u8, ext: []const u8) ![]const u8 {
    // Prefer untitled.zig, then untitled-2.zig, ...
    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const name = if (n == 0)
            try std.fmt.bufPrint(buf, "untitled{s}", .{ext})
        else
            try std.fmt.bufPrint(buf, "untitled-{d}{s}", .{ n, ext });

        // Skip if already open in the store (by basename match) or exists on disk.
        var taken = false;
        for (store.docs.items) |d| {
            if (std.mem.eql(u8, std.fs.path.basename(d.path), name)) {
                taken = true;
                break;
            }
        }
        if (taken) continue;

        const st = std.Io.Dir.cwd().statFile(store.io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => return name,
            else => continue,
        };
        _ = st;
        // Exists on disk — try next.
    }
    return error.TooManyUntitledFiles;
}

/// After placing many bubbles, resolve overlaps and form working sets.
pub fn finalizeLayout(canvas: *Canvas) !void {
    if (canvas.bubbles.items.len == 0) return;
    // Global collision settle (pairwise), then one seed pass per bubble for cascades.
    _ = spacer.resolveAllDefault(canvas);
    for (canvas.bubbles.items) |b| {
        _ = try spacer.resolveDefault(canvas, b.id);
    }
    try spacer.recomputeWorkingSets(canvas);

    // Frame camera on content.
    if (canvas.bubbles.items.len > 0) {
        var box = canvas.bubbles.items[0].bounds;
        for (canvas.bubbles.items[1..]) |b| {
            box = box.unionBox(b.bounds);
        }
        canvas.viewport.pan = .{
            .x = box.x - 40,
            .y = box.y - 40,
        };
        canvas.viewport.zoom = 1.0;
    }
}

/// Load default samples when no CLI paths given.
pub fn openDefaults(store: *DocumentStore, canvas: *Canvas) !void {
    var count: u32 = 0;

    // Canonical project-root paths (testdata/…), NOT src/testdata/.
    // Users/tools often watch testdata/calls.zig — saves used to hit src/testdata/
    // and looked like "Cmd+S does nothing". Embed is only the seed if missing.
    // openOrCreate stores an absolute path so Cmd+S always hits the same file.
    {
        const zig_src = @embedFile("testdata/calls.zig");
        const id = try store.openOrCreate("testdata/calls.zig", zig_src);
        try openScratchDoc(store, canvas, id, &count);
    }
    {
        const zig_src = @embedFile("testdata/sample.zig");
        const id = try store.openOrCreate("testdata/sample.zig", zig_src);
        try openScratchDoc(store, canvas, id, &count);
    }
    try finalizeLayout(canvas);
}

fn openScratchDoc(
    store: *DocumentStore,
    canvas: *Canvas,
    doc_id: doc_mod.DocId,
    bubble_count: *u32,
) !void {
    const doc = store.get(doc_id) orelse return;
    var items: std.ArrayListUnmanaged(outline_mod.OutlineItem) = .empty;
    defer items.deinit(store.allocator);
    try outline_mod.outline(store.allocator, doc.bytes.items, doc.lang, &items);
    const base = std.fs.path.basename(doc.path);
    const start_count = bubble_count.*;

    // Outline items only (imports, functions, types). No whole-file preview bubble.
    for (items.items) |item| {
        if (item.start_line == 0 and item.end_line >= doc.lineCount() and std.mem.eql(u8, item.name, base))
            continue;
        try placeBubble(store, canvas, doc_id, base, item, bubble_count);
    }
    try seedCallLinks(canvas, store, start_count);
}
