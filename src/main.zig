//! zega — Code Bubbles editor for Zig & Rust.
//!
//! Usage:  zega [project-dir]
//!         zega                 # opens current working directory as project
//!
//! Controls:
//!   Middle-drag / Alt+left-drag — pan
//!   Right-click blank          — context menu (new file / new terminal)
//!   Right-drag                 — pan
//!   Click folder icon          — enter folder
//!   Top bar breadcrumb         — navigate up
//!   W A S D (unfocused)        — pan canvas
//!   Scroll                     — zoom (or pan tall focused bubble)
//!   Cmd+Scroll                 — always zoom
//!   Left-click bubble          — focus (center + zoom)
//!   Left-click blank           — clear focus
//!   Left-drag title bar        — move bubble (spacer)
//!   Type / Backspace           — edit focused fragment
//!   Ctrl/Cmd+Space             — Zig completion
//!   Tab/Enter (popup)          — accept completion
//!   Arrows                     — move caret (or completion)
//!   Opt+←/→                    — word jump
//!   Cmd+←/→ or Home/End        — line start/end
//!   Cmd+↑/↓                    — bubble top/bottom
//!   Opt+Backspace / Opt+Delete — delete word
//!   Cmd+Backspace              — delete to line start
//!   Cmd+Shift+K                — delete line
//!   Cmd+Shift+D                — duplicate line
//!   Opt+↑/↓                    — move line
//!   Cmd+A                      — select all in bubble
//!   Ctrl/Cmd+S                 — save focused bubble's file
//!   Ctrl/Cmd+Shift+S           — save all dirty documents
//!   Ctrl/Cmd+Z / Shift+Z       — undo / redo
//!   Esc                        — close menu / quit

const std = @import("std");
const sokol = @import("sokol");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sgl = sokol.gl;
const sglue = sokol.glue;

const geom = @import("geom.zig");
const bubble_mod = @import("bubble.zig");
const canvas_mod = @import("canvas.zig");
const spacer = @import("spacer.zig");
const render_mod = @import("render.zig");
const doc_mod = @import("doc.zig");
const edit_mod = @import("edit.zig");
const layout = @import("layout.zig");
const pills = @import("pills.zig");
const diag_mod = @import("diag.zig");
const brackets_mod = @import("lang/brackets.zig");
const complete_mod = @import("lang/complete.zig");
const font_mod = @import("font.zig");
const text_mod = @import("text.zig");
const term_mod = @import("term/session.zig");
const project_mod = @import("project.zig");

const Canvas = canvas_mod.Canvas;
const BubbleId = bubble_mod.BubbleId;
const ConnectionId = bubble_mod.ConnectionId;
const Renderer = render_mod.Renderer;
const DocumentStore = doc_mod.DocumentStore;
const Editor = edit_mod.Editor;
const DiagStore = diag_mod.DiagStore;
const BracketStore = brackets_mod.BracketStore;
const TermStore = term_mod.TermStore;
const Project = project_mod.Project;

const Gpa = std.heap.DebugAllocator(.{});

const DragKind = enum {
    none,
    pan,
    /// Left button down on a bubble; waiting for movement threshold before dragging.
    pending_bubble,
    bubble,
};

/// Animated camera fly-to when focusing a bubble.
const CamAnim = struct {
    active: bool = false,
    from_pan: geom.Vec2 = .{},
    from_zoom: f32 = 1,
    to_pan: geom.Vec2 = .{},
    to_zoom: f32 = 1,
    /// 0..1 progress.
    t: f32 = 0,
    duration: f32 = 0.22,
};

/// Screen-pixel movement before a bubble press becomes a drag (not a click-focus).
const bubble_drag_threshold_px: f32 = 6.0;
/// Preferred reading zoom when focusing a bubble (logical points).
const focus_preferred_zoom: f32 = 1.45;
const focus_min_zoom: f32 = 0.35;
const focus_max_zoom: f32 = 2.5;
/// Absolute scroll zoom floor/ceiling when nothing is focused.
const canvas_min_zoom: f32 = 0.15;
const canvas_max_zoom: f32 = 4.0;
/// When focused, bubble width may fill at most this fraction of the viewport.
const focused_bubble_max_width_frac: f32 = 0.92;
/// World units per second for WASD pan when nothing is focused.
const wasd_pan_speed: f32 = 720.0;

const state = struct {
    var gpa: Gpa = .{};
    var canvas: Canvas = undefined;
    var store: DocumentStore = undefined;
    var diags: DiagStore = undefined;
    var brackets: BracketStore = undefined;
    var editor: Editor = undefined;
    var terms: TermStore = undefined;
    var project: Project = undefined;
    var renderer: Renderer = .{};
    var ready: bool = false;
    var io: std.Io = undefined;
    /// True while left-dragging a selection inside a terminal body.
    var term_selecting: bool = false;
    /// Doc under cursor while dragging a code bubble (file-halo drop target).
    var drop_target_doc: doc_mod.DocId = doc_mod.INVALID_DOC;
    var top_bar_hover: i32 = -1;
    /// Stable breadcrumb segment views (point into project-owned strings).
    var crumb_segs: [16][]const u8 = .{""} ** 16;
    var crumb_count: u32 = 0;

    var mouse: geom.Vec2 = .{};
    var drag: DragKind = .none;
    var drag_bubble: BubbleId = bubble_mod.INVALID_BUBBLE;
    var grab_offset: geom.Vec2 = .{};
    /// Screen position at left-press (for drag threshold).
    var press_screen: geom.Vec2 = .{};
    var focused: BubbleId = bubble_mod.INVALID_BUBBLE;
    /// Bubble under the cursor (hit-test; for cursor / logic).
    var hovered: BubbleId = bubble_mod.INVALID_BUBBLE;
    /// Bubble that owns the hover-scale animation (kept during out transition).
    var hover_anim_id: BubbleId = bubble_mod.INVALID_BUBBLE;
    /// Smoothed 0..1 hover amount for scale animation.
    var hover_amount: f32 = 0;
    /// Connection arrow under the cursor (highlights call site + endpoints).
    var hovered_conn: ConnectionId = std.math.maxInt(ConnectionId);

    /// Camera animation toward a focused bubble.
    var cam_anim: CamAnim = .{};

    /// Right-click context menu (blank canvas only).
    var ctx_menu: render_mod.ContextMenuView = .{};
    /// World position where the menu was opened (for placing new files).
    var ctx_menu_world: geom.Vec2 = .{};
    var right_down: bool = false;
    var right_down_pos: geom.Vec2 = .{};
    var right_dragged: bool = false;

    /// Held WASD keys for canvas pan when unfocused.
    var key_w: bool = false;
    var key_a: bool = false;
    var key_s: bool = false;
    var key_d: bool = false;

    /// Delete-bubble confirmation modal.
    var confirm_open: bool = false;
    var confirm_bubble: BubbleId = bubble_mod.INVALID_BUBBLE;
    var confirm_hover_btn: i32 = -1;

    /// Zig completion popup (local completer).
    var completion_open: bool = false;
    var completion_selected: i32 = 0;
    var completion_hover: i32 = -1;
    var completion_x: f32 = 0;
    var completion_y: f32 = 0;
    var completion_prefix_len: u32 = 0;
    var completion_items: std.ArrayListUnmanaged(complete_mod.Candidate) = .empty;
    /// Owned label copies for stable popup lifetime (symbols point into docs otherwise).
    var completion_labels: std.ArrayListUnmanaged([]u8) = .empty;
    var completion_kind_tags: [complete_mod.max_results][]const u8 = .{""} ** complete_mod.max_results;
    var completion_label_views: [complete_mod.max_results][]const u8 = .{""} ** complete_mod.max_results;

    var cli_paths: []const []const u8 = &.{};
};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    sgl.setup(.{
        .logger = .{ .func = slog.func },
        .max_vertices = 256 * 1024,
        .max_commands = 32 * 1024,
    });

    const alloc = state.gpa.allocator();
    state.renderer.init(alloc);
    state.canvas = Canvas.init(alloc);
    state.store = DocumentStore.init(alloc, state.io);
    state.diags = DiagStore.init(alloc);
    state.brackets = BracketStore.init(alloc);
    state.editor = Editor.init(alloc);
    state.terms = TermStore.init(alloc);
    state.project = Project.init(alloc);
    // Fixed cwd for every new mini terminal = process launch directory.
    {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |_| {
            const cwd = std.mem.sliceTo(cwd_buf[0..], 0);
            state.terms.setLaunchCwd(cwd) catch {};
        }
    }

    // Viewport size must be known before framing the camera on open.
    syncViewportSize();

    openWorkspace() catch |err| {
        std.log.err("failed to open workspace: {}", .{err});
    };
    refreshAllDiags(true);

    syncViewportSize();
    // Re-focus first bubble with real framebuffer size (open may have used defaults).
    if (state.focused != bubble_mod.INVALID_BUBBLE) {
        if (state.canvas.findBubble(state.focused)) |b| {
            startFocusCameraOnBubble(b, null, true);
        }
    }
    state.ready = true;

    std.log.info("zega: backend {s} · dpi={d:.2} · fb={d:.0}x{d:.0} · bubbles={d} docs={d}", .{
        @tagName(sg.queryBackend()),
        state.canvas.viewport.dpi,
        state.canvas.viewport.screen_w,
        state.canvas.viewport.screen_h,
        state.canvas.bubbles.items.len,
        state.store.docs.items.len,
    });
    std.log.info("right-click blank: menu · type to edit · Cmd+S save bubble · Cmd+Shift+S save all · Esc quit", .{});
}

/// Save only the focused bubble's fragment into the file (other dirty bubbles stay unsaved).
fn saveFocusedBubble() void {
    if (state.focused == bubble_mod.INVALID_BUBBLE) {
        std.log.warn("save: click a bubble first (nothing focused)", .{});
        return;
    }
    const bid = state.focused;
    const b = state.canvas.findBubble(bid) orelse {
        std.log.warn("save: focused bubble missing", .{});
        return;
    };
    const f = b.fragment() orelse {
        std.log.warn("save: bubble is a note (no file path)", .{});
        return;
    };
    const doc_id = f.doc;

    state.editor.saveBubble(&state.store, &state.canvas, bid) catch |err| {
        std.log.err("save bubble failed: {}", .{err});
        return;
    };

    // Only this bubble loses its star — siblings keep * until they are saved.
    if (state.canvas.findBubble(bid)) |bub| bub.dirty = false;

    if (state.store.get(doc_id)) |doc| {
        const title = if (state.canvas.findBubble(bid)) |bub| bub.title else "?";
        std.log.info("saved ONLY bubble '{s}' → {s} ({d} bytes). Other * bubbles stay unsaved.", .{
            title,
            doc.path,
            doc.bytes.items.len,
        });
    }
    refreshDocDiags(doc_id, true);
}

/// Merge every dirty fragment into its document, then write files.
/// (Unlike store.saveAll alone — that only flushes docs already marked dirty,
/// and would drop unmerged bubble locals if we only cleared stars.)
fn saveAllDirtyBubbles() void {
    var saved: u32 = 0;
    // Snapshot ids first — saveBubble may reshuffle fragment ranges.
    var ids: std.ArrayListUnmanaged(BubbleId) = .empty;
    defer ids.deinit(state.gpa.allocator());
    for (state.canvas.bubbles.items) |bub| {
        if (bub.dirty) ids.append(state.gpa.allocator(), bub.id) catch {};
    }
    // Save smaller (non-[full]) bubbles first so a whole-file save does not
    // discard sibling locals that we still intend to merge.
    for (ids.items) |bid| {
        const b = state.canvas.findBubble(bid) orelse continue;
        if (!b.dirty) continue;
        if (std.mem.startsWith(u8, b.title, "[full]")) continue;
        state.editor.saveBubble(&state.store, &state.canvas, bid) catch |err| {
            std.log.err("save-all bubble failed: {}", .{err});
            continue;
        };
        saved += 1;
    }
    for (ids.items) |bid| {
        const b = state.canvas.findBubble(bid) orelse continue;
        if (!b.dirty) continue;
        state.editor.saveBubble(&state.store, &state.canvas, bid) catch |err| {
            std.log.err("save-all bubble failed: {}", .{err});
            continue;
        };
        saved += 1;
    }
    // Flush any docs that were dirty without bubble locals.
    state.store.saveAll() catch |err| {
        std.log.err("save all docs failed: {}", .{err});
    };
    refreshAllDiags(true);
    std.log.info("saved all dirty bubbles ({d} merges)", .{saved});
}

fn isSaveKey(e: *const sapp.Event) bool {
    if (!isMod(e)) return false;
    // Letter S (sokol key codes are uppercase Latin).
    if (e.key_code == .S) return true;
    // Some backends only deliver CHAR for modified letters.
    if (e.char_code == 's' or e.char_code == 'S') return true;
    return false;
}

fn openWorkspace() !void {
    const io = state.io;

    // Resolve project root: 0 args → cwd; 1 arg → must be directory; else error.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs: []const u8 = blk: {
        if (state.cli_paths.len == 0) {
            if (std.c.getcwd(&root_buf, root_buf.len)) |_| {
                break :blk std.mem.sliceTo(root_buf[0..], 0);
            }
            return error.NoCwd;
        }
        if (state.cli_paths.len > 1) {
            std.log.err("zega expects a single project directory (got {d} paths)", .{state.cli_paths.len});
            return error.TooManyArgs;
        }
        const p = state.cli_paths[0];
        const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch |err| {
            std.log.err("cannot open '{s}': {}", .{ p, err });
            return err;
        };
        if (st.kind != .directory) {
            std.log.err("zega expects a project directory (got file '{s}')", .{p});
            return error.NotADirectory;
        }
        const n = std.Io.Dir.cwd().realPathFile(io, p, &root_buf) catch {
            break :blk p;
        };
        break :blk root_buf[0..n];
    };

    try state.project.setRoot(root_abs);
    try navigateToFolder("");

    std.log.info("project root: {s}", .{state.project.root_abs});
}

/// Navigate to a relative path under the project root ("" = root). Rebuilds canvas bubbles.
fn navigateToFolder(rel: []const u8) !void {
    try state.project.setCwdRel(rel);
    clearFocus();
    state.drop_target_doc = doc_mod.INVALID_DOC;

    // Free terminal sessions owned by bubbles we're about to clear.
    for (state.canvas.bubbles.items) |b| {
        if (b.kind == .terminal and b.term_id != bubble_mod.INVALID_TERM) {
            state.terms.destroy(b.term_id);
        }
    }
    state.canvas.clearBubbles();

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs = try state.project.absCurrent(&abs_buf);
    try layout.openFolderLevel(&state.store, &state.canvas, dir_abs, .{});
    try layout.finalizeLayout(&state.canvas);
    refreshAllDiags(true);

    if (state.canvas.bubbles.items.len > 0) {
        // Prefer focusing first code bubble, else first bubble.
        var focused = false;
        for (state.canvas.bubbles.items) |b| {
            if (b.kind == .code or b.kind == .imports) {
                focusBubble(b.id);
                focused = true;
                break;
            }
        }
        if (!focused) focusBubble(state.canvas.bubbles.items[0].id);
    }
    refreshBreadcrumb();
}

fn refreshBreadcrumb() void {
    state.crumb_count = @intCast(state.project.breadcrumb(&state.crumb_segs));
}

fn topBarView() render_mod.TopBarView {
    return .{
        .open = state.project.root_abs.len != 0,
        .segment_count = state.crumb_count,
        .segments = state.crumb_segs[0..state.crumb_count],
        .hover_seg = state.top_bar_hover,
    };
}

fn focusBubble(id: BubbleId) void {
    focusBubbleOpts(id, true);
}

/// Clear keyboard/edit focus (e.g. click on blank canvas).
/// Map a world point back to `bubble_id`'s unscaled layout.
///
/// `drawBubbles` lifts a hovered bubble by up to `render.hover_scale_max` about its centre —
/// a screen-space effect only; the bounds never move. Anything hit-testing a lifted bubble's
/// *contents* has to come back through here first, or it is comparing drawn pixels against
/// undrawn coordinates. A pill is ~40 world wide and the lift shifts by ~10 at the edges, so
/// skipping this reliably selects the neighbouring pill.
fn unscaleHover(bubble_id: BubbleId, world: geom.Vec2) geom.Vec2 {
    if (state.hovered != bubble_id or state.hover_amount <= 0.001) return world;
    const b = state.canvas.findBubble(bubble_id) orelse return world;
    const scale = 1.0 + (render_mod.hover_scale_max - 1.0) * std.math.clamp(state.hover_amount, 0, 1);
    if (scale <= 1.001) return world;
    const c = b.bounds.center();
    return .{
        .x = c.x + (world.x - c.x) / scale,
        .y = c.y + (world.y - c.y) / scale,
    };
}

/// Resize an imports bubble to match the view it is showing, and re-space only if it grew.
///
/// Pills are shorter than the code they replace, so focusing must grow the bubble or the code
/// is clipped. Shrinking cannot create an overlap, so blur never needs the spacer.
fn syncImportsHeight(bubble_id: BubbleId) void {
    const b = state.canvas.findBubble(bubble_id) orelse return;
    if (b.kind != .imports) return;

    const old_h = b.bounds.h;
    b.bounds.h = layout.importsHeight(&state.store, b);
    if (b.bounds.h <= old_h + 0.5) return;

    // Pin through the resolve: the spacer's global settle would otherwise drift the seed.
    const was_pinned = b.pinned;
    b.pinned = true;
    _ = spacer.resolveDefault(&state.canvas, bubble_id) catch {};
    if (state.canvas.findBubble(bubble_id)) |bb| bb.pinned = was_pinned;
    spacer.recomputeWorkingSets(&state.canvas) catch {};
}

/// Click on an import pill or the `+`, while the bubble is showing pills.
///
/// Returns true when the click was consumed. Must run *before* anything focuses `id`: focus
/// swaps the bubble to code, and the pills the user clicked would no longer be there.
fn importPillClick(id: BubbleId, world: geom.Vec2) bool {
    const b = state.canvas.findBubble(id) orelse return false;
    if (b.kind != .imports or b.focused) return false; // already code — normal caret handling

    const src = b.displayText(&state.store);
    const lang = blk: {
        const f = b.fragment() orelse break :blk pills.Language.unknown;
        const d = state.store.getConst(f.doc) orelse break :blk pills.Language.unknown;
        break :blk d.lang;
    };

    var list: std.ArrayListUnmanaged(pills.Import) = .empty;
    defer list.deinit(state.gpa.allocator());
    pills.parse(state.gpa.allocator(), src, lang, &list) catch return false;

    // Same walk the renderer made, so the rects are the ones that were drawn.
    var w = pills.Walker.init(b.contentBounds());
    for (list.items) |imp| {
        if (w.next(imp.name.len).containsPoint(world)) {
            focusBubbleOpts(id, false);
            if (state.canvas.findBubble(id)) |fb| {
                fb.caret = .{ .line = imp.line, .col = 0 };
                edit_mod.Editor.clampCaret(&state.store, fb);
            }
            syncImportsHeight(id);
            return true;
        }
    }
    if (w.plus().containsPoint(world)) {
        addImport(id);
        return true;
    }
    return false;
}

/// `+` — append a template import and drop the caret in the name slot.
/// Goes through `Editor.insertText`, so it detaches and records undo like any other edit.
fn addImport(id: BubbleId) void {
    // Focus *first*: `focusBubbleOpts` clamps the caret, so any position set before it is
    // silently overwritten. Then let `moveBubbleEnd` find the end of the body — computing it
    // from `lineCountOf(displayText)` is off by one, because a fragment's `rangeSlice` carries
    // the trailing newline of its last line and `clampCaret` measures against `FragmentView`.
    // That mismatch welded the template onto the last import instead of appending a line.
    focusBubbleOpts(id, false);
    edit_mod.Editor.moveBubbleEnd(&state.store, &state.canvas, id);

    const b = state.canvas.findBubble(id) orelse return;
    // A trailing newline leaves the caret on an empty last line — start the import there
    // rather than opening a second blank one.
    const on_blank = bubble_mod.lineSliceOf(b.displayText(&state.store), b.caret.line).len == 0;
    const template = if (on_blank) "const  = @import(\"\");" else "\nconst  = @import(\"\");";
    state.editor.insertText(&state.store, &state.canvas, id, template) catch return;

    if (state.canvas.findBubble(id)) |fb| {
        // `insertText` already left the caret on the new line — only the column moves, so
        // there is no line arithmetic left to get wrong.
        fb.caret.col = "const ".len; // between `const ` and ` =`, where the name goes
        edit_mod.Editor.clampCaret(&state.store, fb);
    }
    syncImportsHeight(id);
    refreshFocusedDiags();
}

fn clearFocus() void {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return;
    const was = state.focused;
    if (state.canvas.findBubble(state.focused)) |b| {
        b.focused = false;
        b.selection.clear();
    }
    state.focused = bubble_mod.INVALID_BUBBLE;
    // Blur returns an imports bubble to pills, which are shorter.
    syncImportsHeight(was);
    closeCompletion();
    cancelFocusCamera();
}

fn closeCompletion() void {
    state.completion_open = false;
    state.completion_selected = 0;
    state.completion_hover = -1;
    state.completion_prefix_len = 0;
    state.completion_items.clearRetainingCapacity();
    freeCompletionLabels();
}

fn confirmModalView() render_mod.ConfirmModalView {
    return .{
        .open = state.confirm_open,
        .hover_btn = state.confirm_hover_btn,
        .message = "Are you sure about deleting this bubble?",
    };
}

fn openDeleteConfirm(id: BubbleId) void {
    closeCompletion();
    closeContextMenu();
    state.confirm_open = true;
    state.confirm_bubble = id;
    state.confirm_hover_btn = -1;
    state.drag = .none;
}

fn closeDeleteConfirm() void {
    state.confirm_open = false;
    state.confirm_bubble = bubble_mod.INVALID_BUBBLE;
    state.confirm_hover_btn = -1;
}

fn confirmDeleteBubble() void {
    const id = state.confirm_bubble;
    closeDeleteConfirm();
    if (id == bubble_mod.INVALID_BUBBLE) return;
    if (state.focused == id) clearFocus();
    if (state.hovered == id) state.hovered = bubble_mod.INVALID_BUBBLE;
    if (state.hover_anim_id == id) {
        state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
        state.hover_amount = 0;
    }
    if (state.drag_bubble == id) {
        state.drag = .none;
        state.drag_bubble = bubble_mod.INVALID_BUBBLE;
    }
    // Kill PTY before removing the bubble.
    if (state.canvas.findBubble(id)) |b| {
        if (b.kind == .terminal and b.term_id != bubble_mod.INVALID_TERM) {
            state.terms.destroy(b.term_id);
            b.term_id = bubble_mod.INVALID_TERM;
        }
    }
    state.term_selecting = false;
    state.canvas.removeBubble(id);
    // Working-set halos may change after membership drop.
    spacer.recomputeWorkingSets(&state.canvas) catch {};
}

fn focusedIsTerminal() bool {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return false;
    const b = state.canvas.findBubble(state.focused) orelse return false;
    return b.kind == .terminal;
}

fn focusedTermSession() ?*term_mod.Session {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return null;
    const b = state.canvas.findBubble(state.focused) orelse return null;
    if (b.kind != .terminal or b.term_id == bubble_mod.INVALID_TERM) return null;
    return state.terms.find(b.term_id);
}

/// Map a world point inside a terminal bubble body to cell row/col.
fn termCellAt(b: *const bubble_mod.Bubble, sess: *const term_mod.Session, world: geom.Vec2) struct { row: u16, col: u16 } {
    const content = b.contentBounds();
    const cw = font_mod.Font.charW();
    const ch = font_mod.Font.charH();
    var col_f = (world.x - content.x) / cw;
    var row_f = (world.y - content.y) / ch;
    if (col_f < 0) col_f = 0;
    if (row_f < 0) row_f = 0;
    var col: u16 = @intFromFloat(@floor(col_f));
    var row: u16 = @intFromFloat(@floor(row_f));
    if (col >= sess.screen.cols) col = sess.screen.cols -| 1;
    if (row >= sess.screen.rows) row = sess.screen.rows -| 1;
    return .{ .row = row, .col = col };
}

fn freeCompletionLabels() void {
    const a = state.gpa.allocator();
    for (state.completion_labels.items) |s| a.free(s);
    state.completion_labels.clearRetainingCapacity();
}

fn completionPopupView() render_mod.CompletionPopupView {
    const n = @min(state.completion_items.items.len, complete_mod.max_results);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        state.completion_label_views[i] = state.completion_labels.items[i];
        state.completion_kind_tags[i] = complete_mod.kindTag(state.completion_items.items[i].kind);
    }
    return .{
        .open = state.completion_open,
        .x = state.completion_x,
        .y = state.completion_y,
        .selected = state.completion_selected,
        .hover_item = state.completion_hover,
        .count = @intCast(n),
        .labels = state.completion_label_views[0..n],
        .kinds = state.completion_kind_tags[0..n],
    };
}

/// Rebuild completion list for the focused Zig bubble at the caret.
fn refreshCompletion(force_open: bool) void {
    if (state.focused == bubble_mod.INVALID_BUBBLE) {
        closeCompletion();
        return;
    }
    const b = state.canvas.findBubble(state.focused) orelse {
        closeCompletion();
        return;
    };
    const f = b.fragment() orelse {
        closeCompletion();
        return;
    };
    const doc = state.store.getConst(f.doc) orelse {
        closeCompletion();
        return;
    };
    if (doc.lang != .zig) {
        closeCompletion();
        return;
    }

    const source_body = b.displayText(&state.store);
    const line_bytes = bubble_mod.lineSliceOf(source_body, b.caret.line);
    const pre = complete_mod.prefixAt(line_bytes, b.caret.col);

    // Auto-close when no prefix and not forced / not after dot.
    if (!force_open and pre.prefix.len == 0 and !pre.after_dot and !state.completion_open) {
        closeCompletion();
        return;
    }
    if (!force_open and pre.prefix.len == 0 and !pre.after_dot and state.completion_open) {
        // Keep open only if we forced empty list? Close when prefix empty unless after_dot.
        closeCompletion();
        return;
    }

    // Collect open-doc sources for working-set symbols.
    var sources: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sources.deinit(state.gpa.allocator());
    sources.append(state.gpa.allocator(), source_body) catch {};
    for (state.store.docs.items) |*d| {
        if (d.id == f.doc) {
            // Prefer full document for neighbors when not fully covered by local body.
            if (b.local_text == null) {
                // already have display body == full frag or range
            } else {
                sources.append(state.gpa.allocator(), d.bytes.items) catch {};
            }
        } else {
            sources.append(state.gpa.allocator(), d.bytes.items) catch {};
        }
    }

    var raw: std.ArrayListUnmanaged(complete_mod.Candidate) = .empty;
    defer raw.deinit(state.gpa.allocator());
    complete_mod.suggest(state.gpa.allocator(), .{
        .prefix = pre.prefix,
        .after_dot = pre.after_dot,
        .sources = sources.items,
    }, &raw) catch {
        closeCompletion();
        return;
    };

    freeCompletionLabels();
    state.completion_items.clearRetainingCapacity();
    const a = state.gpa.allocator();
    for (raw.items) |c| {
        const dup = a.dupe(u8, c.label) catch continue;
        state.completion_labels.append(a, dup) catch {
            a.free(dup);
            continue;
        };
        state.completion_items.append(a, .{
            .label = state.completion_labels.items[state.completion_labels.items.len - 1],
            .kind = c.kind,
            .score = c.score,
        }) catch {};
    }

    if (state.completion_items.items.len == 0) {
        closeCompletion();
        return;
    }

    state.completion_prefix_len = @intCast(pre.prefix.len);
    state.completion_selected = 0;
    state.completion_hover = -1;
    state.completion_open = true;

    // Anchor under caret in screen space.
    const anchor = bubbleCaretAnchor(b);
    const sc = state.canvas.viewport.worldToScreen(anchor);
    const scale = @max(state.canvas.viewport.dpi, 1.0);
    state.completion_x = sc.x;
    state.completion_y = sc.y + font_mod.Font.charH() * scale + 2;
}

fn acceptCompletion() void {
    if (!state.completion_open) return;
    if (state.focused == bubble_mod.INVALID_BUBBLE) {
        closeCompletion();
        return;
    }
    const n = state.completion_items.items.len;
    if (n == 0) {
        closeCompletion();
        return;
    }
    var sel = state.completion_selected;
    if (sel < 0) sel = 0;
    if (sel >= @as(i32, @intCast(n))) sel = @intCast(n - 1);
    const label = state.completion_items.items[@intCast(sel)].label;
    const prefix_len = state.completion_prefix_len;
    // Copy label before close frees storage.
    const a = state.gpa.allocator();
    const insert = a.dupe(u8, label) catch {
        closeCompletion();
        return;
    };
    defer a.free(insert);

    closeCompletion();
    state.editor.replacePrefix(
        &state.store,
        &state.canvas,
        state.focused,
        prefix_len,
        insert,
    ) catch {};
    if (state.canvas.findBubble(state.focused)) |b| edit_mod.Editor.clampCaret(&state.store, b);
    refreshFocusedDiags();
    afterCaretMoved();
}

fn focusBubbleOpts(id: BubbleId, fly_camera: bool) void {
    var blurred: BubbleId = bubble_mod.INVALID_BUBBLE;
    if (state.focused != bubble_mod.INVALID_BUBBLE and state.focused != id) {
        if (state.canvas.findBubble(state.focused)) |b| {
            b.focused = false;
            // Drop selection when leaving a bubble so it cannot "eat" the next edit.
            b.selection.clear();
        }
        blurred = state.focused;
    }
    state.focused = id;
    if (state.canvas.findBubble(id)) |b| {
        b.focused = true;
        b.z = @intCast(state.canvas.bubbles.items.len);
        edit_mod.Editor.clampCaret(&state.store, b);
    }
    // Focusing elsewhere blurs this one, which returns an imports bubble to pills. Only
    // `clearFocus` used to do this, so switching straight to another bubble left the old one
    // stuck at code height, showing pills in a box sized for text.
    if (blurred != bubble_mod.INVALID_BUBBLE) syncImportsHeight(blurred);
    if (state.canvas.findBubble(id)) |b| {
        // Every intentional focus click re-frames (even if already focused).
        if (fly_camera) startFocusCameraOnBubble(b, null, false);
    }
}

/// World-space point of the caret (reflow-aware display row when possible).
fn bubbleCaretAnchor(b: *const bubble_mod.Bubble) geom.Vec2 {
    const content = b.contentBounds();
    const ch = font_mod.Font.charH();
    const cw = font_mod.Font.charW();
    const source = b.displayText(&state.store);
    const max_cols = text_mod.maxColsForWidth(content.w);

    var lines: std.ArrayListUnmanaged(text_mod.DisplayLine) = .empty;
    defer lines.deinit(state.gpa.allocator());
    _ = text_mod.reflow(state.gpa.allocator(), source, max_cols, &lines) catch {
        // Fallback: unwrapped logical line/col.
        return .{
            .x = content.x + @as(f32, @floatFromInt(b.caret.col)) * cw + cw * 0.5,
            .y = content.y + @as(f32, @floatFromInt(b.caret.line)) * ch + ch * 0.5,
        };
    };

    const line = b.caret.line;
    const col = b.caret.col;
    var disp_row: usize = 0;
    var col_in_row: u32 = col;
    var found = false;
    for (lines.items, 0..) |dl, i| {
        if (dl.logical_line != line) continue;
        const row_len: u32 = @intCast(dl.bytes.len);
        const start = dl.col_offset;
        const end = start + row_len;
        if (col >= start and (col < end or (col == end and (i + 1 >= lines.items.len or lines.items[i + 1].logical_line != line)))) {
            disp_row = i;
            col_in_row = col - start;
            found = true;
            break;
        }
        if (col >= end) {
            disp_row = i;
            col_in_row = row_len;
            found = true;
        }
    }
    if (!found and lines.items.len > 0) {
        disp_row = lines.items.len - 1;
        col_in_row = @intCast(lines.items[disp_row].bytes.len);
    }
    return .{
        .x = content.x + @as(f32, @floatFromInt(col_in_row)) * cw + cw * 0.5,
        .y = content.y + @as(f32, @floatFromInt(disp_row)) * ch + ch * 0.5,
    };
}

/// World-space point to frame when focusing (caret; bubble center X for balance).
fn bubbleReadingAnchor(b: *const bubble_mod.Bubble) geom.Vec2 {
    const a = bubbleCaretAnchor(b);
    const content = b.contentBounds();
    return .{ .x = content.x + content.w * 0.5, .y = a.y };
}

/// Keep the caret on-screen in a tall/wide focused bubble (pan only; zoom unchanged).
fn followCaretCamera(instant: bool) void {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return;
    if (state.drag != .none) return;
    const b = state.canvas.findBubble(state.focused) orelse return;

    syncViewportSize();
    const vp = state.canvas.viewport;
    if (vp.screen_w < 1 or vp.screen_h < 1) return;
    const s = vp.pixelScale();
    if (s < 0.001) return;
    const view_w = vp.screen_w / s;
    const view_h = vp.screen_h / s;

    const tall = b.bounds.h > view_h * 0.92;
    const wide = b.bounds.w > view_w * 0.98;
    if (!tall and !wide) return;

    const anchor = bubbleCaretAnchor(b);
    // Keep caret in the comfortable reading band (slightly above center).
    const anchor_frac_y: f32 = 0.42;
    var pan_x = vp.pan.x;
    var pan_y = vp.pan.y;
    if (tall) {
        pan_y = anchor.y - view_h * anchor_frac_y;
        const margin_h = view_h * 0.08;
        const pan_top = b.bounds.y - margin_h;
        const pan_bot = b.bounds.bottom() - view_h + margin_h;
        const lo = @min(pan_top, pan_bot);
        const hi = @max(pan_top, pan_bot);
        pan_y = std.math.clamp(pan_y, lo, hi);
    }
    if (wide) {
        pan_x = anchor.x - view_w * 0.5;
        const margin_w = view_w * 0.08;
        const pan_left = b.bounds.x - margin_w;
        const pan_right = b.bounds.right() - view_w + margin_w;
        const lo = @min(pan_left, pan_right);
        const hi = @max(pan_left, pan_right);
        pan_x = std.math.clamp(pan_x, lo, hi);
    }

    const to_pan = geom.Vec2{ .x = pan_x, .y = pan_y };
    const pan_d = geom.Vec2.sub(to_pan, vp.pan).length();
    if (pan_d < 1.5) return; // already tracking

    if (instant) {
        state.canvas.viewport.pan = to_pan;
        state.cam_anim.active = false;
        return;
    }

    state.cam_anim = .{
        .active = true,
        .from_pan = vp.pan,
        .from_zoom = vp.zoom,
        .to_pan = to_pan,
        .to_zoom = vp.zoom, // never change zoom while following caret
        .t = 0,
        .duration = 0.12,
    };
}

/// Call after any caret move / edit in the focused bubble.
fn afterCaretMoved() void {
    followCaretCamera(false);
}

/// Begin ease-out pan/zoom for reading.
/// Tall bubbles stay at preferred zoom and frame `anchor` (click/caret), not the full body.
/// `instant` snaps without animation (used after layout when size is known).
fn startFocusCameraOnBubble(b: *const bubble_mod.Bubble, anchor_opt: ?geom.Vec2, instant: bool) void {
    syncViewportSize();
    const vp = state.canvas.viewport;
    if (vp.screen_w < 1 or vp.screen_h < 1) return;

    const anchor = anchor_opt orelse bubbleReadingAnchor(b);
    // Light pad so the border/title aren't flush with the window edge.
    const padded = b.bounds.expanded(12);
    // Focus fly-to also respects size-based max zoom-in.
    const size_max = maxZoomForFocusedBubble();
    const target = vp.focusTarget(
        padded,
        anchor,
        0.10,
        focus_preferred_zoom,
        focus_min_zoom,
        @min(focus_max_zoom, size_max),
    );

    if (instant) {
        state.canvas.viewport.pan = target.pan;
        state.canvas.viewport.zoom = target.zoom;
        state.cam_anim.active = false;
        return;
    }

    // Already looking at this target — skip.
    const pan_d = geom.Vec2.sub(target.pan, vp.pan).length();
    const zoom_d = @abs(target.zoom - vp.zoom);
    if (pan_d < 2.0 and zoom_d < 0.02) {
        state.cam_anim.active = false;
        return;
    }

    state.cam_anim = .{
        .active = true,
        .from_pan = vp.pan,
        .from_zoom = vp.zoom,
        .to_pan = target.pan,
        .to_zoom = target.zoom,
        .t = 0,
        .duration = 0.22,
    };
}

fn startFocusCamera(bounds: geom.BoundingBox, instant: bool) void {
    // Back-compat path: treat center of bounds as anchor.
    syncViewportSize();
    const vp = state.canvas.viewport;
    if (vp.screen_w < 1 or vp.screen_h < 1) return;
    const padded = bounds.expanded(12);
    const target = vp.focusTarget(
        padded,
        bounds.center(),
        0.10,
        focus_preferred_zoom,
        focus_min_zoom,
        focus_max_zoom,
    );
    if (instant) {
        state.canvas.viewport.pan = target.pan;
        state.canvas.viewport.zoom = target.zoom;
        state.cam_anim.active = false;
        return;
    }
    state.cam_anim = .{
        .active = true,
        .from_pan = vp.pan,
        .from_zoom = vp.zoom,
        .to_pan = target.pan,
        .to_zoom = target.zoom,
        .t = 0,
        .duration = 0.22,
    };
}

fn cancelFocusCamera() void {
    state.cam_anim.active = false;
}

fn updateFocusCamera() void {
    if (!state.cam_anim.active) return;

    const dt: f32 = @floatCast(sapp.frameDuration());
    const dur = @max(state.cam_anim.duration, 0.001);
    state.cam_anim.t = @min(1.0, state.cam_anim.t + dt / dur);

    // Ease-out cubic: 1 - (1-t)^3
    const u = state.cam_anim.t;
    const e = 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u);
    const a = state.cam_anim;
    state.canvas.viewport.pan = .{
        .x = a.from_pan.x + (a.to_pan.x - a.from_pan.x) * e,
        .y = a.from_pan.y + (a.to_pan.y - a.from_pan.y) * e,
    };
    state.canvas.viewport.zoom = a.from_zoom + (a.to_zoom - a.from_zoom) * e;

    if (state.cam_anim.t >= 1.0) {
        state.canvas.viewport.pan = a.to_pan;
        state.canvas.viewport.zoom = a.to_zoom;
        state.cam_anim.active = false;
    }
}

/// Recompute diagnostics for every open document.
/// `zig_ast` enables `zig ast-check` (slower; use on open/save).
fn refreshAllDiags(zig_ast: bool) void {
    for (state.store.docs.items) |*d| {
        state.diags.refresh(
            state.io,
            d.id,
            d.path,
            d.lang,
            d.bytes.items,
            .{ .zig_ast_check = zig_ast and d.lang == .zig },
        ) catch |err| {
            std.log.warn("diag refresh '{s}': {}", .{ d.path, err });
        };
        state.brackets.refresh(d.id, d.bytes.items) catch |err| {
            std.log.warn("bracket refresh '{s}': {}", .{ d.path, err });
        };
    }
}

fn refreshDocDiags(doc_id: doc_mod.DocId, zig_ast: bool) void {
    const d = state.store.get(doc_id) orelse return;
    state.diags.refresh(
        state.io,
        d.id,
        d.path,
        d.lang,
        d.bytes.items,
        .{ .zig_ast_check = zig_ast and d.lang == .zig },
    ) catch |err| {
        std.log.warn("diag refresh '{s}': {}", .{ d.path, err });
    };
    state.brackets.refresh(d.id, d.bytes.items) catch |err| {
        std.log.warn("bracket refresh '{s}': {}", .{ d.path, err });
    };
}

/// After an edit in a focused bubble, refresh that document's structural diags + brackets.
fn refreshFocusedDiags() void {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return;
    const b = state.canvas.findBubble(state.focused) orelse return;
    const f = b.fragment() orelse return;
    refreshDocDiags(f.doc, false);
}

fn syncViewportSize() void {
    // With high_dpi=true, width/height are framebuffer pixels.
    state.canvas.viewport.screen_w = sapp.widthf();
    state.canvas.viewport.screen_h = sapp.heightf();
    state.canvas.viewport.dpi = @max(sapp.dpiScale(), 1.0);
}

fn updateHover() void {
    const world = state.canvas.viewport.screenToWorld(state.mouse);
    // Hit-test arrows first (wider threshold in world units).
    const conn_thresh: f32 = 10.0 / @max(state.canvas.viewport.zoom, 0.2);

    if (state.drag == .bubble or state.drag == .pending_bubble) {
        // No hover-scale while dragging — scaled draw would desync from grab math.
        state.hovered = bubble_mod.INVALID_BUBBLE;
        state.hovered_conn = std.math.maxInt(ConnectionId);
    } else if (state.drag == .pan) {
        state.hovered = bubble_mod.INVALID_BUBBLE;
        state.hovered_conn = std.math.maxInt(ConnectionId);
    } else if (state.canvas.hitTestConnection(world, conn_thresh)) |cid| {
        state.hovered_conn = cid;
        // Don't scale bubbles while inspecting a link.
        state.hovered = bubble_mod.INVALID_BUBBLE;
    } else {
        state.hovered_conn = std.math.maxInt(ConnectionId);
        state.hovered = state.canvas.hitTest(world) orelse bubble_mod.INVALID_BUBBLE;
    }

    // Snap hover scale off immediately when dragging so the bubble sits under the cursor.
    const dragging = state.drag == .bubble or state.drag == .pending_bubble;
    if (dragging) {
        state.hover_amount = 0;
        state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
        return;
    }

    // Hover scale/chrome only for unfocused bubbles — no effect while editing the same one.
    const hover_fx: BubbleId = if (state.hovered != bubble_mod.INVALID_BUBBLE and
        state.hovered != state.focused)
        state.hovered
    else
        bubble_mod.INVALID_BUBBLE;

    // Track which bubble receives the scale. Keep the last id while amount eases out
    // so leaving a bubble doesn't snap to 1.0 (render used to key only on hovered id).
    const target: f32 = if (hover_fx != bubble_mod.INVALID_BUBBLE) 1.0 else 0.0;
    if (hover_fx != bubble_mod.INVALID_BUBBLE) {
        state.hover_anim_id = hover_fx;
    } else if (state.hover_anim_id == state.focused) {
        // Focused this bubble: drop any leftover hover anim immediately.
        state.hover_amount = 0;
        state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
        return;
    }

    const dt: f32 = @floatCast(sapp.frameDuration());
    // Asymmetric ease: snappy in, softer out.
    const rate: f32 = if (target > state.hover_amount) 16.0 else 9.0;
    const k = 1.0 - @exp(-rate * dt);
    state.hover_amount += (target - state.hover_amount) * k;
    if (@abs(state.hover_amount - target) < 0.001) state.hover_amount = target;

    if (state.hover_amount <= 0.001 and target == 0.0) {
        state.hover_amount = 0;
        state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
    }
}

/// Drag/move cursor while dragging a bubble; hand when hovering the title bar.
fn updateMouseCursor() void {
    const cursor: sapp.MouseCursor = switch (state.drag) {
        // RESIZE_ALL is sokol’s multi-arrow “move / drag” cursor.
        .bubble, .pending_bubble => .RESIZE_ALL,
        .pan => .RESIZE_ALL,
        .none => blk: {
            if (state.ctx_menu.open) break :blk .DEFAULT;
            const world = state.canvas.viewport.screenToWorld(state.mouse);
            // Title bar: show move cursor so it’s clear the strip is draggable.
            if (state.canvas.hitTestTitleBar(world) != null) break :blk .RESIZE_ALL;
            break :blk .DEFAULT;
        },
    };
    if (sapp.getMouseCursor() != cursor) {
        sapp.setMouseCursor(cursor);
    }
}

/// World-space offset from bubble top-left to the cursor (keeps grab point under mouse).
fn captureGrabOffset(bubble_id: BubbleId, screen: geom.Vec2) void {
    const world = state.canvas.viewport.screenToWorld(screen);
    if (state.canvas.findBubble(bubble_id)) |b| {
        state.grab_offset = geom.Vec2.sub(world, b.pos());
    }
}

fn applyGrabToBubble(bubble_id: BubbleId, screen: geom.Vec2) void {
    const world = state.canvas.viewport.screenToWorld(screen);
    if (state.canvas.findBubble(bubble_id)) |b| {
        b.pinned = true;
        b.setPos(geom.Vec2.sub(world, state.grab_offset));
    }
}

fn currentLinkHighlight() ?render_mod.LinkHighlight {
    if (state.hovered_conn == std.math.maxInt(ConnectionId)) return null;
    const conn = state.canvas.findConnection(state.hovered_conn) orelse return null;
    return .{
        .conn_id = conn.id,
        .from_bubble = conn.from.bubble,
        .to_bubble = conn.to.bubble,
        .call_line = conn.from.line,
        .call_col_start = conn.call_col_start,
        .call_col_end = conn.call_col_end,
    };
}

export fn frame() void {
    if (!state.ready) return;

    syncViewportSize();
    // Drain PTY output before drawing so the frame shows fresh cells.
    state.terms.pollAll();
    // Keep bubble titles in sync with session titles (e.g. exited).
    for (state.canvas.bubbles.items) |*b| {
        if (b.kind != .terminal or b.term_id == bubble_mod.INVALID_TERM) continue;
        if (state.terms.find(b.term_id)) |sess| {
            if (!std.mem.eql(u8, b.title, sess.title)) {
                b.setTitleOwned(state.gpa.allocator(), sess.title) catch {};
            }
        }
    }
    updateFocusCamera();
    updateWasdPan();
    updateHover();
    updateMouseCursor();

    const active: ?BubbleId = if (state.drag == .bubble or state.drag == .pending_bubble)
        state.drag_bubble
    else
        null;
    const focused: ?BubbleId = if (state.focused != bubble_mod.INVALID_BUBBLE) state.focused else null;
    // Prefer anim id so scale eases out after the pointer leaves the bubble.
    const hover_for_draw: BubbleId = if (state.hover_anim_id != bubble_mod.INVALID_BUBBLE)
        state.hover_anim_id
    else
        state.hovered;
    const hovered: ?BubbleId = if (hover_for_draw != bubble_mod.INVALID_BUBBLE) hover_for_draw else null;

    // Update menu hover highlight.
    if (state.ctx_menu.open) {
        state.ctx_menu.hover_item = if (render_mod.contextMenuHit(
            state.ctx_menu,
            state.mouse.x,
            state.mouse.y,
            state.canvas.viewport.dpi,
        )) |idx|
            @intCast(idx)
        else
            -1;
    }
    if (state.completion_open) {
        state.completion_hover = if (render_mod.completionHit(
            completionPopupView(),
            state.mouse.x,
            state.mouse.y,
            state.canvas.viewport.dpi,
        )) |idx|
            @intCast(idx)
        else
            -1;
    }
    if (state.confirm_open) {
        state.confirm_hover_btn = render_mod.confirmModalHit(
            confirmModalView(),
            state.mouse.x,
            state.mouse.y,
            state.canvas.viewport.screen_w,
            state.canvas.viewport.screen_h,
            state.canvas.viewport.dpi,
        ) orelse -1;
    }

    // Top bar hover.
    if (state.project.root_abs.len != 0) {
        state.top_bar_hover = if (render_mod.topBarHit(
            topBarView(),
            state.mouse.x,
            state.mouse.y,
            state.canvas.viewport.dpi,
        )) |idx|
            @intCast(idx)
        else
            -1;
    }

    // File-halo drop target while dragging a code bubble.
    if (state.drag == .bubble) {
        if (state.canvas.findBubble(state.drag_bubble)) |b| {
            if (b.kind == .code or b.kind == .imports) {
                const world = state.canvas.viewport.screenToWorld(state.mouse);
                const hit = state.canvas.hitTestFileGroup(world, render_mod.halo_pad);
                const src_doc = if (b.fragment()) |f| f.doc else doc_mod.INVALID_DOC;
                state.drop_target_doc = if (hit) |d| (if (d != src_doc) d else doc_mod.INVALID_DOC) else doc_mod.INVALID_DOC;
            } else {
                state.drop_target_doc = doc_mod.INVALID_DOC;
            }
        }
    } else if (state.drag != .pending_bubble) {
        state.drop_target_doc = doc_mod.INVALID_DOC;
    }

    state.renderer.draw(
        &state.canvas,
        &state.store,
        &state.diags,
        &state.brackets,
        &state.terms,
        active,
        focused,
        hovered,
        state.hover_amount,
        currentLinkHighlight(),
        state.ctx_menu,
        completionPopupView(),
        confirmModalView(),
        topBarView(),
        state.drop_target_doc,
    );

    sg.beginPass(.{
        .action = state.renderer.passAction(),
        .swapchain = sglue.swapchain(),
    });
    sgl.draw();
    sg.endPass();
    sg.commit();
}

export fn event(ev: ?*const sapp.Event) void {
    const e = ev orelse return;
    if (!state.ready) return;

    switch (e.type) {
        .MOUSE_MOVE => {
            state.mouse = .{ .x = e.mouse_x, .y = e.mouse_y };
            handleMouseMove(e);
        },
        .MOUSE_DOWN => handleMouseDown(e),
        .MOUSE_UP => handleMouseUp(e),
        .MOUSE_SCROLL => handleScroll(e),
        .KEY_DOWN => handleKeyDown(e),
        .KEY_UP => handleKeyUp(e),
        .CHAR => handleChar(e),
        .RESIZED => {
            // Prefer live framebuffer size + dpi (may change when moving monitors).
            syncViewportSize();
        },
        else => {},
    }
}

fn closeContextMenu() void {
    state.ctx_menu.open = false;
    state.ctx_menu.hover_item = -1;
}

fn openContextMenu(screen: geom.Vec2, world: geom.Vec2) void {
    state.ctx_menu = .{
        .open = true,
        .x = screen.x,
        .y = screen.y,
        .hover_item = -1,
    };
    state.ctx_menu_world = world;
}

fn handleMouseDown(e: *const sapp.Event) void {
    state.mouse = .{ .x = e.mouse_x, .y = e.mouse_y };

    switch (e.mouse_button) {
        .MIDDLE => {
            closeContextMenu();
            state.drag = .pan;
        },
        .RIGHT => {
            state.right_down = true;
            state.right_down_pos = state.mouse;
            state.right_dragged = false;
            // Don't pan yet — short right-click opens the menu on blank space.
        },
        .LEFT => {
            // Top bar breadcrumb first (screen space).
            if (state.project.root_abs.len != 0) {
                if (render_mod.topBarHit(
                    topBarView(),
                    state.mouse.x,
                    state.mouse.y,
                    state.canvas.viewport.dpi,
                )) |seg_idx| {
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const rel = state.project.pathForBreadcrumbIndex(seg_idx, &path_buf) catch "";
                    navigateToFolder(rel) catch |err| {
                        std.log.err("navigate breadcrumb failed: {}", .{err});
                    };
                    return;
                }
            }

            // Delete confirmation modal first.
            if (state.confirm_open) {
                if (render_mod.confirmModalHit(
                    confirmModalView(),
                    state.mouse.x,
                    state.mouse.y,
                    state.canvas.viewport.screen_w,
                    state.canvas.viewport.screen_h,
                    state.canvas.viewport.dpi,
                )) |btn| {
                    if (btn == 0) confirmDeleteBubble() else closeDeleteConfirm();
                } else if (!render_mod.confirmModalPanelHit(
                    confirmModalView(),
                    state.mouse.x,
                    state.mouse.y,
                    state.canvas.viewport.screen_w,
                    state.canvas.viewport.screen_h,
                    state.canvas.viewport.dpi,
                )) {
                    // Click scrim → cancel.
                    closeDeleteConfirm();
                }
                return;
            }

            // Context menu click handling.
            if (state.ctx_menu.open) {
                if (render_mod.contextMenuHit(
                    state.ctx_menu,
                    state.mouse.x,
                    state.mouse.y,
                    state.canvas.viewport.dpi,
                )) |idx| {
                    activateContextMenuItem(idx);
                }
                closeContextMenu();
                return;
            }

            if ((e.modifiers & sapp.modifier_alt) != 0) {
                cancelFocusCamera();
                state.drag = .pan;
                return;
            }
            const world = state.canvas.viewport.screenToWorld(state.mouse);
            if (state.canvas.hitTest(world)) |id| {
                // Folder icon → navigate into that child.
                if (state.canvas.findBubble(id)) |fb| {
                    if (fb.kind == .folder) {
                        const child = fb.fragment_key;
                        if (child.len > 0) {
                            const joined = state.project.joinRel(child) catch null;
                            if (joined) |rel| {
                                defer state.gpa.allocator().free(rel);
                                navigateToFolder(rel) catch |err| {
                                    std.log.err("enter folder '{s}': {}", .{ child, err });
                                };
                            }
                        }
                        return;
                    }
                }
                // Close button on title bar → confirm delete (do not start drag).
                // The × only renders on the focused bubble, so only honor hits there.
                if (state.focused == id) {
                    if (state.canvas.findBubble(id)) |b| {
                        if (b.hitCloseButton(world)) {
                            openDeleteConfirm(id);
                            return;
                        }
                    }
                }
                // Import pills, before anything focuses. Focus swaps the bubble to code, so a
                // click resolved after that would be measured against text rows that weren't
                // on screen when it happened.
                if (state.canvas.hitTestTitleBar(world) != id and importPillClick(id, unscaleHover(id, world))) return;

                // Click body or title → focus. Drag only from the title bar.
                if (state.canvas.hitTestTitleBar(world) == id) {
                    // Title bar: capture grab under cursor *before* any camera fly-to,
                    // cancel hover scale, and pin for collision.
                    cancelFocusCamera();
                    state.hover_amount = 0;
                    state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
                    state.hovered = bubble_mod.INVALID_BUBBLE;
                    focusBubbleOpts(id, false); // focus without camera so grab stays accurate
                    if (state.canvas.findBubble(id)) |b| b.selection.clear();
                    state.drag = .pending_bubble;
                    state.drag_bubble = id;
                    state.press_screen = state.mouse;
                    captureGrabOffset(id, state.mouse);
                    if (state.canvas.findBubble(id)) |b| {
                        b.pinned = true;
                    }
                } else {
                    // Body click: focus, place caret under the mouse, clear selection.
                    // Hover scale is screen-space only — unproject the click back to the
                    // unscaled bubble layout, then snap scale off so draw matches.
                    const hit = unscaleHover(id, world);
                    state.hover_amount = 0;
                    state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
                    state.hovered = bubble_mod.INVALID_BUBBLE;
                    // Place caret first, then fly camera to the click (not the whole tall body).
                    focusBubbleOpts(id, false);
                    if (state.canvas.findBubble(id)) |b| {
                        if (b.kind == .terminal) {
                            // Start text selection in terminal cells; no editor caret.
                            if (state.terms.find(b.term_id)) |sess| {
                                const cell = termCellAt(b, sess, hit);
                                sess.selection = .{
                                    .active = true,
                                    .a_row = cell.row,
                                    .a_col = cell.col,
                                    .b_row = cell.row,
                                    .b_col = cell.col,
                                };
                                state.term_selecting = true;
                            }
                            startFocusCameraOnBubble(b, hit, false);
                        } else {
                            state.editor.placeCaretAtWorld(&state.store, b, hit);
                            startFocusCameraOnBubble(b, hit, false);
                        }
                    }
                }
            } else {
                // Blank canvas: drop focus so typing doesn't hit a hidden bubble.
                clearFocus();
                state.drag = .pan;
            }
        },
        else => {},
    }
}

fn activateContextMenuItem(idx: usize) void {
    if (idx == 0) {
        // Create new file in the current project folder.
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = state.project.absCurrent(&dir_buf) catch ".";
        layout.createNewFile(
            &state.store,
            &state.canvas,
            state.ctx_menu_world,
            .zig,
            dir,
        ) catch |err| {
            std.log.err("create new file failed: {}", .{err});
            return;
        };
        // Focus the newest bubble.
        if (state.canvas.bubbles.items.len > 0) {
            const last = state.canvas.bubbles.items[state.canvas.bubbles.items.len - 1];
            focusBubble(last.id);
            if (last.fragment()) |f| refreshDocDiags(f.doc, true);
        }
        std.log.info("created new file", .{});
    } else if (idx == 1) {
        // New terminal
        const id = layout.createTerminal(
            &state.terms,
            &state.canvas,
            state.ctx_menu_world,
        ) catch |err| {
            std.log.err("create terminal failed: {}", .{err});
            return;
        };
        focusBubble(id);
        std.log.info("created mini terminal", .{});
    }
}

fn handleMouseUp(e: *const sapp.Event) void {
    if (e.mouse_button == .RIGHT and state.right_down) {
        state.right_down = false;
        if (!state.right_dragged) {
            // Click (no drag): open menu on blank canvas only.
            const world = state.canvas.viewport.screenToWorld(state.mouse);
            if (state.canvas.hitTest(world) == null) {
                openContextMenu(state.mouse, world);
            } else {
                closeContextMenu();
            }
        } else {
            // Was panning with right-drag.
            if (state.drag == .pan) state.drag = .none;
        }
        state.right_dragged = false;
        return;
    }

    if (e.mouse_button == .LEFT) {
        state.term_selecting = false;
        if (state.drag == .bubble) {
            if (state.canvas.findBubble(state.drag_bubble)) |b| {
                b.pinned = false;
            }
            // Cross-file move: drop onto another file's halo.
            tryMoveDraggedBubbleToDropTarget();
            // Final collision settle after drop.
            _ = spacer.resolveDefault(&state.canvas, state.drag_bubble) catch |err| {
                std.log.warn("spacer: {}", .{err});
            };
            _ = spacer.resolveAllDefault(&state.canvas);
            spacer.recomputeWorkingSets(&state.canvas) catch {};
            state.drag_bubble = bubble_mod.INVALID_BUBBLE;
            state.drop_target_doc = doc_mod.INVALID_DOC;
        } else if (state.drag == .pending_bubble) {
            // Pure click — leave camera anim running; unpin.
            if (state.canvas.findBubble(state.drag_bubble)) |b| {
                b.pinned = false;
            }
            state.drag_bubble = bubble_mod.INVALID_BUBBLE;
        }
        state.drag = .none;
    } else if (e.mouse_button == .MIDDLE) {
        if (state.drag == .pan) state.drag = .none;
    }
}

fn tryMoveDraggedBubbleToDropTarget() void {
    const target = state.drop_target_doc;
    if (target == doc_mod.INVALID_DOC) return;
    const bid = state.drag_bubble;
    if (bid == bubble_mod.INVALID_BUBBLE) return;
    const b = state.canvas.findBubble(bid) orelse return;
    if (b.kind != .code and b.kind != .imports) return;
    const src = b.fragment() orelse return;
    if (src.doc == target) return;

    edit_mod.moveFragmentToDoc(&state.editor, &state.store, &state.canvas, bid, target) catch |err| {
        std.log.err("move bubble to file failed: {}", .{err});
        return;
    };
    spacer.recomputeWorkingSets(&state.canvas) catch {};
    refreshAllDiags(true);
    std.log.info("moved bubble into another file", .{});
}

fn handleMouseMove(e: *const sapp.Event) void {
    const dx = e.mouse_dx;
    const dy = e.mouse_dy;

    // Right-button drag → pan (threshold so clicks still open the menu).
    if (state.right_down) {
        const dist = @sqrt(dx * dx + dy * dy);
        const moved = @abs(state.mouse.x - state.right_down_pos.x) + @abs(state.mouse.y - state.right_down_pos.y);
        if (moved > 6 or dist > 0) {
            // Accumulate: once past threshold from start, pan.
            if (@abs(state.mouse.x - state.right_down_pos.x) + @abs(state.mouse.y - state.right_down_pos.y) > 6) {
                state.right_dragged = true;
                state.drag = .pan;
                closeContextMenu();
            }
        }
    }

    // Terminal text selection drag.
    if (state.term_selecting) {
        if (state.canvas.findBubble(state.focused)) |b| {
            if (b.kind == .terminal) {
                if (state.terms.find(b.term_id)) |sess| {
                    const world = state.canvas.viewport.screenToWorld(state.mouse);
                    const cell = termCellAt(b, sess, world);
                    sess.selection.b_row = cell.row;
                    sess.selection.b_col = cell.col;
                    sess.selection.active = true;
                }
            }
        }
        return;
    }

    switch (state.drag) {
        .pan => {
            cancelFocusCamera();
            const s = state.canvas.viewport.pixelScale();
            state.canvas.viewport.pan.x -= dx / s;
            state.canvas.viewport.pan.y -= dy / s;
        },
        .pending_bubble => {
            const ddx = state.mouse.x - state.press_screen.x;
            const ddy = state.mouse.y - state.press_screen.y;
            if (@sqrt(ddx * ddx + ddy * ddy) >= bubble_drag_threshold_px) {
                // Promote to a real drag; keep grab offset from the original press.
                cancelFocusCamera();
                state.hover_amount = 0;
                state.hover_anim_id = bubble_mod.INVALID_BUBBLE;
                state.drag = .bubble;
                applyGrabToBubble(state.drag_bubble, state.mouse);
                _ = spacer.resolveDefault(&state.canvas, state.drag_bubble) catch spacer.SpacerStats{};
            }
        },
        .bubble => {
            applyGrabToBubble(state.drag_bubble, state.mouse);
            // Live collision: push other bubbles out of the way (seed stays put).
            _ = spacer.resolveDefault(&state.canvas, state.drag_bubble) catch spacer.SpacerStats{};
        },
        .none => {},
    }
}

fn handleScroll(e: *const sapp.Event) void {
    const sy = e.scroll_y;
    const sx = e.scroll_x;
    if (sy == 0 and sx == 0) return;

    // Cmd/Ctrl+scroll always zooms (reading mode can pan with plain two-finger swipe).
    if (isMod(e)) {
        cancelFocusCamera();
        zoomByScroll(sy);
        return;
    }

    // Focused terminal: scrollback (positive sy = look at older lines).
    if (focusedIsTerminal()) {
        if (focusedTermSession()) |sess| {
            // Trackpad: scroll_y is often small fractional; accumulate as lines.
            const lines: i32 = if (@abs(sy) < 1.0)
                if (sy > 0) @as(i32, 1) else if (sy < 0) @as(i32, -1) else 0
            else
                @intFromFloat(@round(sy));
            if (lines != 0) sess.scroll(lines * 3);
            return;
        }
    }

    // Focused tall bubble: two-finger vertical (Magic Mouse / trackpad) pans to read.
    if (scrollFocusedReading(sy, sx)) return;

    // Default: scroll zooms the canvas.
    if (sy != 0) {
        cancelFocusCamera();
        zoomByScroll(sy);
    }
}

/// Max zoom-in while a bubble is focused, based on that bubble's size.
/// Larger bubbles get a lower ceiling so they don't blow past the screen;
/// small bubbles can still zoom in more (up to `canvas_max_zoom`).
fn maxZoomForFocusedBubble() f32 {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return canvas_max_zoom;
    const b = state.canvas.findBubble(state.focused) orelse return canvas_max_zoom;
    syncViewportSize();
    const vp = state.canvas.viewport;
    const dpi = @max(vp.dpi, 1.0);
    const bw = @max(b.bounds.w, 32.0);
    const bh = @max(b.bounds.h, 24.0);
    // Width: bubble should not exceed `focused_bubble_max_width_frac` of the screen.
    const z_w = (vp.screen_w * focused_bubble_max_width_frac) / (bw * dpi);
    // Height: for short bubbles, also cap so the whole bubble isn't > ~95% of view height
    // when fully visible (tall bubbles already pan; only clamp huge short+wide ones).
    const z_h = (vp.screen_h * 0.95) / (bh * dpi);
    // Use the tighter of width/height caps for short bubbles; for tall ones width dominates
    // (height fit would force an unusably small max zoom).
    const tall = bh * focus_preferred_zoom * dpi > vp.screen_h * 0.92;
    const size_cap = if (tall) z_w else @min(z_w, z_h);
    // Never below preferred reading zoom (allow at least that), never above canvas max.
    return std.math.clamp(size_cap, focus_preferred_zoom, canvas_max_zoom);
}

fn zoomByScroll(ticks: f32) void {
    if (ticks == 0) return;
    const factor: f32 = if (ticks > 0) 1.1 else 1.0 / 1.1;
    const min_z = canvas_min_zoom;
    const max_z = maxZoomForFocusedBubble();
    const n: i32 = @intFromFloat(@min(5.0, @abs(ticks)));
    var i: i32 = 0;
    while (i < @max(1, n)) : (i += 1) {
        state.canvas.viewport.zoomAt(state.mouse, factor, min_z, max_z);
    }
}

/// When a tall bubble is focused, pan the camera so two-finger scroll reads its body
/// instead of zooming out. Returns true if the scroll was consumed.
fn scrollFocusedReading(scroll_y: f32, scroll_x: f32) bool {
    if (state.focused == bubble_mod.INVALID_BUBBLE) return false;
    if (state.drag != .none) return false;
    const b = state.canvas.findBubble(state.focused) orelse return false;

    const vp = &state.canvas.viewport;
    const s = vp.pixelScale();
    if (s < 0.001) return false;
    const view_w = vp.screen_w / s;
    const view_h = vp.screen_h / s;

    // Only take over scroll when the bubble is taller than the viewport
    // (otherwise plain scroll keeps zooming as before).
    const tall = b.bounds.h > view_h * 0.92;
    const wide = b.bounds.w > view_w * 0.98;
    if (!tall and !wide) return false;
    if (scroll_y == 0 and !(wide and scroll_x != 0)) return false;

    cancelFocusCamera();

    // World units per scroll tick (scale a bit with zoom so feel stays similar).
    const speed = 36.0 / @max(vp.zoom, 0.25);
    // Match pan-drag polarity: positive scroll_y → look toward smaller world-y (up).
    if (tall and scroll_y != 0) {
        vp.pan.y -= scroll_y * speed;
    }
    if (wide and scroll_x != 0) {
        vp.pan.x -= scroll_x * speed;
    }

    // Keep the bubble in frame so you don't scroll into empty canvas.
    const margin_h = view_h * 0.08;
    const margin_w = view_w * 0.08;
    if (tall) {
        const pan_top = b.bounds.y - margin_h;
        const pan_bot = b.bounds.bottom() - view_h + margin_h;
        const lo = @min(pan_top, pan_bot);
        const hi = @max(pan_top, pan_bot);
        vp.pan.y = std.math.clamp(vp.pan.y, lo, hi);
    }
    if (wide) {
        const pan_left = b.bounds.x - margin_w;
        const pan_right = b.bounds.right() - view_w + margin_w;
        const lo = @min(pan_left, pan_right);
        const hi = @max(pan_left, pan_right);
        vp.pan.x = std.math.clamp(vp.pan.x, lo, hi);
    }
    return true;
}

fn isMod(e: *const sapp.Event) bool {
    return (e.modifiers & (sapp.modifier_ctrl | sapp.modifier_super)) != 0;
}

fn isAlt(e: *const sapp.Event) bool {
    return (e.modifiers & sapp.modifier_alt) != 0;
}

fn isShift(e: *const sapp.Event) bool {
    return (e.modifiers & sapp.modifier_shift) != 0;
}

fn setWasdKey(code: sapp.Keycode, down: bool) bool {
    switch (code) {
        .W => state.key_w = down,
        .A => state.key_a = down,
        .S => state.key_s = down,
        .D => state.key_d = down,
        else => return false,
    }
    return true;
}

fn handleKeyUp(e: *const sapp.Event) void {
    _ = setWasdKey(e.key_code, false);
}

/// Continuous canvas pan with WASD while no bubble is focused.
fn updateWasdPan() void {
    if (state.focused != bubble_mod.INVALID_BUBBLE) return;
    if (state.ctx_menu.open) return;
    if (state.drag != .none) return;
    if (!state.key_w and !state.key_a and !state.key_s and !state.key_d) return;

    const dt: f32 = @floatCast(sapp.frameDuration());
    // Keep speed roughly constant on screen: more world units when zoomed out.
    const speed = wasd_pan_speed / @max(state.canvas.viewport.zoom, 0.2);
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (state.key_a) dx -= 1;
    if (state.key_d) dx += 1;
    if (state.key_w) dy -= 1;
    if (state.key_s) dy += 1;
    if (dx == 0 and dy == 0) return;
    // Normalize diagonal so W+D isn't faster.
    const len = @sqrt(dx * dx + dy * dy);
    dx /= len;
    dy /= len;
    cancelFocusCamera();
    state.canvas.viewport.pan.x += dx * speed * dt;
    state.canvas.viewport.pan.y += dy * speed * dt;
}

fn handleKeyDown(e: *const sapp.Event) void {
    if (e.key_code == .ESCAPE) {
        if (state.confirm_open) {
            closeDeleteConfirm();
            return;
        }
        if (state.completion_open) {
            closeCompletion();
            return;
        }
        if (state.ctx_menu.open) {
            closeContextMenu();
            return;
        }
        sapp.requestQuit();
        return;
    }

    // Enter on delete modal confirms; no other typing while open.
    if (state.confirm_open) {
        if (e.key_code == .ENTER) {
            confirmDeleteBubble();
            return;
        }
        return;
    }

    // Completion navigation / accept (before edit keys).
    if (state.completion_open and state.focused != bubble_mod.INVALID_BUBBLE and !focusedIsTerminal()) {
        if (e.key_code == .UP) {
            if (state.completion_selected > 0) state.completion_selected -= 1;
            return;
        }
        if (e.key_code == .DOWN) {
            const max_i: i32 = @intCast(@max(state.completion_items.items.len, 1) - 1);
            if (state.completion_selected < max_i) state.completion_selected += 1;
            return;
        }
        if (e.key_code == .TAB or e.key_code == .ENTER) {
            acceptCompletion();
            return;
        }
    }

    // Track WASD always so key-up stays in sync; pan only applies when unfocused.
    if (!isMod(e) and !isAlt(e) and setWasdKey(e.key_code, true)) {
        if (state.focused == bubble_mod.INVALID_BUBBLE) return; // don't type WASD into a bubble if unfocused
        // Focused: fall through so W/A/S/D can still insert via CHAR (held flags ignored while focused).
    }

    // ── Mini terminal input (before editor shortcuts) ──────────────────
    if (focusedIsTerminal()) {
        handleTerminalKeyDown(e);
        return;
    }

    // Ctrl/Cmd+Space → force completion.
    if (isMod(e) and !isShift(e) and e.key_code == .SPACE) {
        refreshCompletion(true);
        return;
    }

    if (isSaveKey(e)) {
        if (isShift(e)) {
            saveAllDirtyBubbles();
        } else {
            saveFocusedBubble();
        }
        return;
    }
    if (isMod(e) and e.key_code == .Z) {
        if (isShift(e)) {
            state.editor.redo(&state.store, &state.canvas) catch {};
        } else {
            state.editor.undo(&state.store, &state.canvas) catch {};
        }
        refreshFocusedDiags();
        afterCaretMoved();
        return;
    }
    if (isMod(e) and e.key_code == .Y) {
        state.editor.redo(&state.store, &state.canvas) catch {};
        refreshFocusedDiags();
        afterCaretMoved();
        return;
    }

    if (state.focused == bubble_mod.INVALID_BUBBLE) return;
    if (state.drag == .pan or state.drag == .bubble) return;

    const id = state.focused;
    var edited = false;

    // Cmd/Ctrl + Shift combos
    if (isMod(e) and isShift(e)) {
        switch (e.key_code) {
            .K => {
                state.editor.deleteLine(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            .D => {
                state.editor.duplicateLine(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            else => {},
        }
        if (edited) {
            if (state.canvas.findBubble(id)) |b| edit_mod.Editor.clampCaret(&state.store, b);
            refreshFocusedDiags();
            afterCaretMoved();
            return;
        }
    }

    // Cmd/Ctrl alone
    if (isMod(e) and !isAlt(e)) {
        var moved = false;
        switch (e.key_code) {
            .A => {
                edit_mod.Editor.selectAll(&state.store, &state.canvas, id);
            },
            .LEFT => {
                edit_mod.Editor.moveLineStart(&state.canvas, id);
                moved = true;
            },
            .RIGHT => {
                edit_mod.Editor.moveLineEnd(&state.store, &state.canvas, id);
                moved = true;
            },
            .UP => {
                edit_mod.Editor.moveBubbleStart(&state.canvas, id);
                moved = true;
            },
            .DOWN => {
                edit_mod.Editor.moveBubbleEnd(&state.store, &state.canvas, id);
                moved = true;
            },
            .BACKSPACE => {
                state.editor.deleteToLineStart(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            else => {},
        }
        if (state.canvas.findBubble(id)) |b| edit_mod.Editor.clampCaret(&state.store, b);
        if (edited) refreshFocusedDiags();
        if (moved or edited) afterCaretMoved();
        // Consumed mod key even if no-op (avoid falling through to char-ish handling).
        if (e.key_code == .A or e.key_code == .LEFT or e.key_code == .RIGHT or
            e.key_code == .UP or e.key_code == .DOWN or e.key_code == .BACKSPACE)
            return;
    }

    // Opt/Alt alone
    if (isAlt(e) and !isMod(e)) {
        var moved = false;
        switch (e.key_code) {
            .LEFT => {
                edit_mod.Editor.moveWordLeft(&state.store, &state.canvas, id);
                moved = true;
            },
            .RIGHT => {
                edit_mod.Editor.moveWordRight(&state.store, &state.canvas, id);
                moved = true;
            },
            .UP => {
                state.editor.moveLineUp(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            .DOWN => {
                state.editor.moveLineDown(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            .BACKSPACE => {
                state.editor.deleteWordBackward(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            .DELETE => {
                state.editor.deleteWordForward(&state.store, &state.canvas, id) catch {};
                edited = true;
            },
            else => {},
        }
        if (state.canvas.findBubble(id)) |b| edit_mod.Editor.clampCaret(&state.store, b);
        if (edited) refreshFocusedDiags();
        if (moved or edited) afterCaretMoved();
        if (e.key_code == .LEFT or e.key_code == .RIGHT or e.key_code == .UP or e.key_code == .DOWN or
            e.key_code == .BACKSPACE or e.key_code == .DELETE)
            return;
    }

    var moved = false;
    switch (e.key_code) {
        .BACKSPACE => {
            state.editor.backspace(&state.store, &state.canvas, id) catch {};
            if (state.canvas.findBubble(id)) |b| edit_mod.Editor.clampCaret(&state.store, b);
            edited = true;
        },
        .ENTER => {
            state.editor.insertText(&state.store, &state.canvas, id, "\n") catch {};
            edited = true;
        },
        .TAB => {
            state.editor.insertText(&state.store, &state.canvas, id, "    ") catch {};
            edited = true;
        },
        .LEFT => {
            edit_mod.Editor.moveLeft(&state.canvas, id);
            moved = true;
        },
        .RIGHT => {
            edit_mod.Editor.moveRight(&state.store, &state.canvas, id);
            moved = true;
        },
        .UP => {
            edit_mod.Editor.moveUp(&state.canvas, id);
            moved = true;
        },
        .DOWN => {
            edit_mod.Editor.moveDown(&state.canvas, id);
            moved = true;
        },
        .HOME => {
            edit_mod.Editor.moveLineStart(&state.canvas, id);
            moved = true;
        },
        .END => {
            edit_mod.Editor.moveLineEnd(&state.store, &state.canvas, id);
            moved = true;
        },
        .DELETE => {
            // Forward delete one char: word-style via selecting next char path
            // Move right then backspace if possible.
            const b0 = state.canvas.findBubble(id);
            if (b0) |b| {
                if (b.selection.active and !b.selection.isEmpty()) {
                    state.editor.deleteSelection(&state.store, &state.canvas, id) catch {};
                } else {
                    const line = b.caret.line;
                    const col = b.caret.col;
                    edit_mod.Editor.moveRight(&state.store, &state.canvas, id);
                    edit_mod.Editor.clampCaret(&state.store, b);
                    if (b.caret.line != line or b.caret.col != col) {
                        state.editor.backspace(&state.store, &state.canvas, id) catch {};
                    }
                }
            }
            edited = true;
        },
        else => {},
    }
    if (state.canvas.findBubble(id)) |b| edit_mod.Editor.clampCaret(&state.store, b);
    if (edited) refreshFocusedDiags();
    if (moved or edited) afterCaretMoved();
    if (edited) {
        if (state.completion_open) refreshCompletion(false) else closeCompletion();
    } else if (moved) {
        closeCompletion();
    }
}

fn handleTerminalKeyDown(e: *const sapp.Event) void {
    const sess = focusedTermSession() orelse return;
    if (state.drag == .pan or state.drag == .bubble) return;

    // Cmd/Ctrl+C → copy selection (not SIGINT). Plain Ctrl+C without Super is interrupt.
    if (isMod(e) and e.key_code == .C and !isAlt(e)) {
        // Super (Cmd) or Ctrl with selection → copy.
        // Prefer Cmd+C for copy; Ctrl+C without selection → interrupt.
        const has_sel = sess.selection.active;
        const use_cmd = (e.modifiers & sapp.modifier_super) != 0;
        if (has_sel or use_cmd) {
            if (has_sel) {
                var buf: [8192]u8 = undefined;
                const text = sess.copySelection(&buf);
                if (text.len > 0) {
                    // Need null-terminated for sokol.
                    var zbuf: [8193]u8 = undefined;
                    const n = @min(text.len, zbuf.len - 1);
                    @memcpy(zbuf[0..n], text[0..n]);
                    zbuf[n] = 0;
                    sapp.setClipboardString(zbuf[0..n :0]);
                }
            }
            return;
        }
        // Ctrl+C → interrupt
        sess.write(&.{0x03});
        return;
    }
    if (isMod(e) and e.key_code == .V and !isAlt(e)) {
        const clip = sapp.getClipboardString();
        if (clip.len > 0) sess.write(clip);
        return;
    }

    // Ctrl+letter → control bytes (when not Super).
    if ((e.modifiers & sapp.modifier_ctrl) != 0 and (e.modifiers & sapp.modifier_super) == 0 and !isAlt(e)) {
        switch (e.key_code) {
            .C => sess.write(&.{0x03}), // already handled above, but keep
            .D => sess.write(&.{0x04}),
            .Z => sess.write(&.{0x1A}),
            .L => sess.write(&.{0x0C}),
            .A => sess.write(&.{0x01}),
            .E => sess.write(&.{0x05}),
            .U => sess.write(&.{0x15}),
            .W => sess.write(&.{0x17}),
            .R => sess.write(&.{0x12}),
            else => {},
        }
        return;
    }

    if (isMod(e)) return; // other cmd shortcuts ignored in terminal

    switch (e.key_code) {
        .ENTER => sess.write("\r"),
        .BACKSPACE => sess.write(&.{0x7F}),
        .TAB => sess.write("\t"),
        .ESCAPE => sess.write("\x1b"),
        .DELETE => sess.write("\x1b[3~"),
        .UP => sess.write("\x1b[A"),
        .DOWN => sess.write("\x1b[B"),
        .RIGHT => sess.write("\x1b[C"),
        .LEFT => sess.write("\x1b[D"),
        .HOME => sess.write("\x1b[H"),
        .END => sess.write("\x1b[F"),
        .PAGE_UP => sess.scroll(8),
        .PAGE_DOWN => sess.scroll(-8),
        else => {},
    }
}

fn handleChar(e: *const sapp.Event) void {
    // Cmd/Ctrl+S sometimes arrives as CHAR on some platforms.
    if (isSaveKey(e) and !focusedIsTerminal()) {
        if (isShift(e)) {
            saveAllDirtyBubbles();
        } else {
            saveFocusedBubble();
        }
        return;
    }

    if (state.focused == bubble_mod.INVALID_BUBBLE) return;
    if (state.drag == .pan or state.drag == .bubble) return;
    if (isMod(e)) return;

    const cp = e.char_code;
    if (cp < 32 or cp > 126) return;
    if (cp == 127) return;

    // Terminal: forward printable to PTY.
    if (focusedIsTerminal()) {
        if (focusedTermSession()) |sess| {
            var buf: [1]u8 = .{@intCast(cp)};
            sess.write(&buf);
        }
        return;
    }

    var buf: [1]u8 = .{@intCast(cp)};
    state.editor.insertText(&state.store, &state.canvas, state.focused, &buf) catch {};
    if (state.canvas.findBubble(state.focused)) |b| edit_mod.Editor.clampCaret(&state.store, b);
    refreshFocusedDiags();
    afterCaretMoved();

    // Auto-trigger completion for identifier chars and '.'.
    const is_id = (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
        (cp >= '0' and cp <= '9') or cp == '_' or cp == '@' or cp == '.';
    if (is_id or state.completion_open) {
        refreshCompletion(cp == '.' or cp == '@');
    } else {
        closeCompletion();
    }
}

export fn cleanup() void {
    if (state.ready) {
        state.ready = false;
        // Do NOT auto-save every dirty bubble on quit — that undoes independent
        // Cmd+S (saving A would still flush B when the app exits).
        var unsaved: u32 = 0;
        for (state.canvas.bubbles.items) |bub| {
            if (bub.dirty) unsaved += 1;
        }
        if (unsaved > 0) {
            std.log.warn("quit: {d} bubble(s) still unsaved (use Cmd+S per bubble)", .{unsaved});
        }

        closeCompletion();
        state.completion_items.deinit(state.gpa.allocator());
        state.completion_labels.deinit(state.gpa.allocator());
        state.editor.deinit();
        // Kill all PTYs before canvas frees bubbles.
        state.terms.deinit();
        state.canvas.deinit();
        state.project.deinit();
        state.brackets.deinit();
        state.diags.deinit();
        state.store.deinit();
        state.renderer.deinit();
    }
    sgl.shutdown();
    sg.shutdown();
    _ = state.gpa.deinit();
}

pub fn main(init_ctx: std.process.Init) void {
    state.io = init_ctx.io;
    const alloc = init_ctx.gpa;

    var arg_it = init_ctx.minimal.args.iterate();
    _ = arg_it.next(); // argv0

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    while (arg_it.next()) |a| {
        const dup = alloc.dupe(u8, a) catch continue;
        paths.append(alloc, dup) catch {
            alloc.free(dup);
        };
    }
    if (paths.items.len > 0) {
        state.cli_paths = paths.items; // leak for process life
    }

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = 1280,
        .height = 720,
        // Full-resolution framebuffer on Retina — without this, macOS
        // upscales a half-res buffer and all text looks soft.
        .high_dpi = true,
        // MSAA softens thin glyph edges; keep off for crisp code text.
        .sample_count = 1,
        .window_title = "ZEGA",
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
        .enable_clipboard = true,
    });
}
