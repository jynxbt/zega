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
const pills = @import("pills.zig");
const spacer = @import("spacer.zig");
const term_mod = @import("term/session.zig");
const project_mod = @import("project.zig");

pub const DocumentStore = doc_mod.DocumentStore;
pub const Canvas = canvas_mod.Canvas;
pub const TermStore = term_mod.TermStore;

pub const OpenLimits = struct {
    max_files: u32 = 40,
    max_bubbles: u32 = 200,
    max_folders: u32 = 40,
};

/// Layout constants (world units).
const origin_x: f32 = 40;
const origin_y: f32 = 56; // leave a little room under the top bar in world framing
const gap_x: f32 = 28;
const gap_y: f32 = 24;
/// Gap between file clusters so file-halos stay visually separate.
const file_cluster_gap_x: f32 = 64;
const folder_col_w: f32 = 140;
const folder_card_w: f32 = 120;
const folder_card_h: f32 = 72;
/// Wide enough for typical Zig signatures without harsh mid-expression wraps.
const bubble_w: f32 = 440;
const min_bubble_h: f32 = 72;
/// Soft cap — prefer fitting content; only clamp pathological giants.
const max_bubble_h: f32 = 1400;

/// Open only the immediate children of `dir_abs` (no recursive walk).
/// Folders → folder-icon bubbles; supported source files → outline bubbles in per-file clusters.
pub fn openFolderLevel(
    store: *DocumentStore,
    canvas: *Canvas,
    dir_abs: []const u8,
    limits: OpenLimits,
) !void {
    const io = store.io;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true });
    defer dir.close(io);

    var folder_names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (folder_names.items) |n| store.allocator.free(n);
        folder_names.deinit(store.allocator);
    }
    var file_names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (file_names.items) |n| store.allocator.free(n);
        file_names.deinit(store.allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (project_mod.shouldSkipDirName(entry.name) and entry.kind == .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        switch (entry.kind) {
            .directory => {
                if (project_mod.shouldSkipDirName(entry.name)) continue;
                if (folder_names.items.len >= limits.max_folders) continue;
                try folder_names.append(store.allocator, try store.allocator.dupe(u8, entry.name));
            },
            .file => {
                if (!detect.isSupported(entry.name)) continue;
                if (file_names.items.len >= limits.max_files) continue;
                try file_names.append(store.allocator, try store.allocator.dupe(u8, entry.name));
            },
            else => {},
        }
    }

    // Stable order for deterministic layout.
    std.mem.sort([]u8, folder_names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.less);
    std.mem.sort([]u8, file_names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.less);

    var bubble_count: u32 = 0;

    // Folder icons: left column.
    var folder_y = origin_y;
    for (folder_names.items) |name| {
        if (bubble_count >= limits.max_bubbles) break;
        try placeFolderBubble(canvas, name, origin_x, folder_y);
        folder_y += folder_card_h + gap_y;
        bubble_count += 1;
    }

    // Files: clusters to the right of the folder column.
    const files_origin_x = origin_x + if (folder_names.items.len > 0) folder_col_w + gap_x else 0;
    var file_x = files_origin_x;

    for (file_names.items) |name| {
        if (bubble_count >= limits.max_bubbles) break;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_abs, name });
        const before = canvas.bubbles.items.len;
        try openFileAt(store, canvas, path, limits, &bubble_count, file_x, origin_y);
        // Advance cluster x by width of this file's bubbles + gap.
        var cluster_right = file_x;
        for (canvas.bubbles.items[before..]) |b| {
            cluster_right = @max(cluster_right, b.bounds.right());
        }
        file_x = cluster_right + file_cluster_gap_x;
    }
}

fn placeFolderBubble(canvas: *Canvas, name: []const u8, x: f32, y: f32) !void {
    const id = try canvas.addBubble(.folder, .{
        .x = x,
        .y = y,
        .w = folder_card_w,
        .h = folder_card_h,
    });
    const b = canvas.findBubble(id).?;
    b.pad_x = 8;
    b.pad_y = 22;
    try b.setTitleOwned(canvas.allocator, name);
    // Store folder name for navigation (relative child name).
    try b.setFragmentKeyOwned(canvas.allocator, name);
}

pub fn openFile(
    store: *DocumentStore,
    canvas: *Canvas,
    path: []const u8,
    limits: OpenLimits,
    bubble_count: *u32,
) !void {
    try openFileAt(store, canvas, path, limits, bubble_count, origin_x, origin_y);
}

fn openFileAt(
    store: *DocumentStore,
    canvas: *Canvas,
    path: []const u8,
    limits: OpenLimits,
    bubble_count: *u32,
    cluster_x: f32,
    cluster_y: f32,
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
    var local_y = cluster_y;

    // Outline items only (imports, functions, types). No whole-file preview bubble.
    for (items.items) |item| {
        if (bubble_count.* >= limits.max_bubbles) break;
        // Skip outline item that is already the whole file.
        if (item.start_line == 0 and item.end_line >= doc.lineCount() and std.mem.eql(u8, item.name, base))
            continue;
        const h = try placeBubble(store, canvas, doc_id, base, item, bubble_count, cluster_x, local_y);
        local_y += h + gap_y;
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

// --- imports bubble: pills when unfocused, code when focused ---

fn bubbleLang(store: *const DocumentStore, b: *const bubble_mod.Bubble) detect.Language {
    const f = b.fragment() orelse return .unknown;
    const d = store.getConst(f.doc) orelse return .unknown;
    return d.lang;
}

/// Imports stay compact so they read as chrome rather than a method.
/// `min_bubble_h` (72) already exceeds the old 56 floor and 220 is far below `max_bubble_h`,
/// so this is the whole range — chaining the general clamp first would just be noise.
fn clampImportsHeight(h: f32) f32 {
    return std.math.clamp(h, min_bubble_h, imports_max_h);
}

/// Cap on an imports bubble. Focused blocks longer than ~11 lines clip against this: there is
/// no scrolling, and `drawCodeContent` simply stops at the content edge.
const imports_max_h: f32 = 220;

/// Height an import block needs to show its pills — from `pills.layoutHeight`, the same walker
/// the renderer draws with. Sizing from anything else lets the bubble clip pills it drew.
///
/// Null when the block has no pills (Rust `use`, `usingnamespace`): the renderer falls back to
/// code for those, so the height must too, or the bubble is sized for a view it never draws.
fn pillsHeightFor(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: detect.Language,
    w: f32,
    pad_x: f32,
    pad_y: f32,
) ?f32 {
    var list: std.ArrayListUnmanaged(pills.Import) = .empty;
    defer list.deinit(allocator);
    pills.parse(allocator, source, lang, &list) catch return null;
    if (!pills.hasPills(list.items)) return null;
    // The walker only reads x/w for wrapping; height is its output, not its input.
    const content = geom.BoundingBox{ .x = 0, .y = 0, .w = @max(0, w - pad_x * 2), .h = 0 };
    return pad_y + pills.layoutHeight(list.items, content) + pad_x;
}

/// Height the same block needs as editable code.
fn codeHeightFor(source: []const u8, w: f32, pad_x: f32, pad_y: f32) f32 {
    const max_cols = text_mod.maxColsForWidth(@max(0, w - pad_x * 2));
    const n = text_mod.reflowCount(source, max_cols);
    return pad_y + pad_x + @as(f32, @floatFromInt(n + 1)) * font_mod.Font.charH();
}

/// Height for an imports bubble in whatever view it is currently showing.
///
/// Pills are shorter than the code they replace, so focusing has to grow the bubble — otherwise
/// the code it just switched to is clipped.
pub fn importsHeight(store: *DocumentStore, b: *const bubble_mod.Bubble) f32 {
    const src = b.displayText(store);
    const code_h = codeHeightFor(src, b.bounds.w, b.pad_x, b.pad_y);
    if (b.focused) return clampImportsHeight(code_h);
    const pill_h = pillsHeightFor(store.allocator, src, bubbleLang(store, b), b.bounds.w, b.pad_x, b.pad_y);
    return clampImportsHeight(pill_h orelse code_h);
}

/// Place one outline bubble at (x, y). Returns its height for vertical stacking.
fn placeBubble(
    store: *DocumentStore,
    canvas: *Canvas,
    doc_id: doc_mod.DocId,
    file_base: []const u8,
    item: outline_mod.OutlineItem,
    bubble_count: *u32,
    x: f32,
    y: f32,
) !f32 {
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
        // Imports open unfocused, which means pills — shorter than the code they replace.
        const body = if (store.getConst(doc_id)) |d| d.rangeSlice(item.start_line, item.end_line) else "";
        const lang = if (store.getConst(doc_id)) |d| d.lang else .unknown;
        // No pills (Rust `use`) → it renders as code, so size it as code.
        h = clampImportsHeight(pillsHeightFor(store.allocator, body, lang, w, pad_x, pad_y) orelse h);
    }

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
    return h;
}

/// Compact terminal bubble size from monospaced font metrics + padding.
pub fn terminalBounds(world: geom.Vec2) geom.BoundingBox {
    const cols: f32 = @floatFromInt(term_mod.default_cols);
    const rows: f32 = @floatFromInt(term_mod.default_rows);
    const cw = font_mod.Font.charW();
    const ch = font_mod.Font.charH();
    const pad_x: f32 = 8;
    const pad_y: f32 = 22; // title strip
    return .{
        .x = world.x,
        .y = world.y,
        .w = pad_x * 2 + cols * cw,
        .h = pad_y + pad_x + rows * ch,
    };
}

/// Spawn a mini terminal (zsh PTY) bubble near `world`.
pub fn createTerminal(
    terms: *TermStore,
    canvas: *Canvas,
    world: geom.Vec2,
) !bubble_mod.BubbleId {
    const term_id = try terms.create();
    errdefer terms.destroy(term_id);

    const bounds = terminalBounds(world);
    const id = try canvas.addBubble(.terminal, bounds);
    const b = canvas.findBubble(id) orelse {
        terms.destroy(term_id);
        return error.UnknownBubble;
    };
    b.term_id = term_id;
    b.pad_x = 8;
    b.pad_y = 22;
    b.line_height = font_mod.Font.charH();
    if (terms.find(term_id)) |sess| {
        b.setTitleOwned(canvas.allocator, sess.title) catch {
            b.title = "zsh";
            b.title_owned = false;
        };
    } else {
        b.title = "zsh";
    }

    _ = try spacer.resolveDefault(canvas, id);
    try spacer.recomputeWorkingSets(canvas);
    return id;
}

/// Create a new on-disk source file near `world` and open it as bubble(s).
/// `dir_abs` is the directory to create in (usually the current project folder).
pub fn createNewFile(
    store: *DocumentStore,
    canvas: *Canvas,
    world: geom.Vec2,
    lang: detect.Language,
    dir_abs: []const u8,
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

    var name_buf: [64]u8 = undefined;
    const name = try uniqueUntitledName(store, &name_buf, ext, dir_abs);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_abs, name });

    // Write file to disk.
    {
        const file = try std.Io.Dir.cwd().createFile(store.io, path, .{ .exclusive = true });
        defer file.close(store.io);
        try file.writeStreamingAll(store.io, template);
    }

    const before = canvas.bubbles.items.len;
    var count: u32 = @intCast(before);
    try openFileAt(store, canvas, path, .{}, &count, world.x, world.y);

    // Move newly added bubbles near the click position (openFileAt already uses world).
    if (canvas.bubbles.items.len > before) {
        const first = &canvas.bubbles.items[before];
        // Settle overlaps from the first new bubble.
        _ = try spacer.resolveDefault(canvas, first.id);
        try spacer.recomputeWorkingSets(canvas);
    }
}

fn uniqueUntitledName(store: *DocumentStore, buf: []u8, ext: []const u8, dir_abs: []const u8) ![]const u8 {
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

        var full: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&full, "{s}/{s}", .{ dir_abs, name }) catch continue;
        const st = std.Io.Dir.cwd().statFile(store.io, path, .{}) catch |err| switch (err) {
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

fn openScratchDoc(
    store: *DocumentStore,
    canvas: *Canvas,
    doc_id: doc_mod.DocId,
    bubble_count: *u32,
    cluster_x: f32,
    cluster_y: f32,
) !void {
    const doc = store.get(doc_id) orelse return;
    var items: std.ArrayListUnmanaged(outline_mod.OutlineItem) = .empty;
    defer items.deinit(store.allocator);
    try outline_mod.outline(store.allocator, doc.bytes.items, doc.lang, &items);
    const base = std.fs.path.basename(doc.path);
    const start_count = bubble_count.*;
    var local_y = cluster_y;

    // Outline items only (imports, functions, types). No whole-file preview bubble.
    for (items.items) |item| {
        if (item.start_line == 0 and item.end_line >= doc.lineCount() and std.mem.eql(u8, item.name, base))
            continue;
        const h = try placeBubble(store, canvas, doc_id, base, item, bubble_count, cluster_x, local_y);
        local_y += h + gap_y;
    }
    try seedCallLinks(canvas, store, start_count);
}
