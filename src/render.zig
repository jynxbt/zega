//! Immediate-mode 2D drawing for the virtual canvas via sokol-gl.
//! Coordinates: world space → screen via Viewport, then sgl ortho (y-down).

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sapp = sokol.app;

const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");
const bubble_mod = @import("bubble.zig");
const font_mod = @import("font.zig");
const text_mod = @import("text.zig");
const doc_mod = @import("doc.zig");
const highlight = @import("lang/highlight.zig");
const detect = @import("lang/detect.zig");
const connection_mod = @import("connection.zig");
const diag_mod = @import("diag.zig");
const brackets_mod = @import("lang/brackets.zig");
const pills = @import("pills.zig");
const term_mod = @import("term/session.zig");

pub const Canvas = canvas_mod.Canvas;
pub const TermStore = term_mod.TermStore;
pub const Viewport = canvas_mod.Viewport;
pub const BoundingBox = geom.BoundingBox;
pub const BubbleKind = bubble_mod.BubbleKind;
pub const Font = font_mod.Font;
pub const DocumentStore = doc_mod.DocumentStore;
pub const DiagStore = diag_mod.DiagStore;
pub const BracketStore = brackets_mod.BracketStore;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

/// Pastel working-set halo palette (paper §6.3: auto-assigned colored halo).
pub const halo_palette = [_]Color{
    Color.rgba(0.35, 0.55, 0.95, 0.22),
    Color.rgba(0.95, 0.55, 0.35, 0.22),
    Color.rgba(0.40, 0.80, 0.50, 0.22),
    Color.rgba(0.80, 0.45, 0.85, 0.22),
    Color.rgba(0.95, 0.80, 0.30, 0.22),
    Color.rgba(0.40, 0.75, 0.85, 0.22),
};

pub const clear_color = Color.rgb(0.12, 0.13, 0.15);
const grid_color = Color.rgba(1.0, 1.0, 1.0, 0.50);
const grid_major_color = Color.rgba(1.0, 1.0, 1.0, 0.50);

const bubble_fill_code = Color.rgb(0.18, 0.20, 0.24);
const bubble_fill_note = Color.rgb(0.28, 0.24, 0.16);
const bubble_fill_other = Color.rgb(0.20, 0.22, 0.20);
/// Imports: cool teal so dependency chrome is distinct from function bodies.
const bubble_fill_imports = Color.rgb(0.14, 0.22, 0.24);
const bubble_border_imports = Color.rgb(0.40, 0.70, 0.72);
/// Mini terminal: near-black shell chrome.
const bubble_fill_terminal = Color.rgb(0.08, 0.09, 0.10);
const bubble_border_terminal = Color.rgb(0.35, 0.55, 0.45);
const term_selection_bg = Color.rgba(0.25, 0.45, 0.70, 0.45);
/// Folder icon card.
const bubble_fill_folder = Color.rgb(0.22, 0.20, 0.14);
const bubble_border_folder = Color.rgb(0.85, 0.72, 0.35);
const folder_tab = Color.rgb(0.90, 0.78, 0.40);
/// Drop-target file halo highlight.
const halo_drop_tint = Color.rgba(0.95, 0.85, 0.25, 0.28);
const top_bar_bg = Color.rgba(0.10, 0.11, 0.13, 0.94);
const top_bar_border = Color.rgb(0.30, 0.32, 0.36);
const top_bar_text = Color.rgb(0.88, 0.90, 0.92);
const top_bar_hover = Color.rgb(0.28, 0.34, 0.45);
const top_bar_sep = Color.rgb(0.50, 0.52, 0.56);

pub const top_bar_h: f32 = 34;
/// Import pills. The mockup's orange-on-amber is pitched for a white page; on this dark canvas
/// the pill keeps the warm hue and the bubble keeps its own fill behind it.
const pill_fill = Color.rgb(0.84, 0.34, 0.18);
const pill_text = Color.rgb(1.0, 0.95, 0.92);
/// The `+` reads as an affordance, not another import — neutral rather than warm.
const pill_plus_fill = Color.rgb(0.30, 0.34, 0.36);
const pill_corner_r: f32 = 4;
const bubble_border = Color.rgb(0.55, 0.58, 0.65);
const bubble_border_active = Color.rgb(0.85, 0.90, 1.0);
const breadcrumb_fill = Color.rgba(0.0, 0.0, 0.0, 0.25);
/// Corner radius in **world** units (scales with zoom for a stable look).
const bubble_corner_r: f32 = 8.0;
/// Segments per quarter-circle for rounded corners.
const corner_segments: u32 = 8;
const text_body = Color.rgb(0.85, 0.87, 0.90);
const text_title = Color.rgb(0.75, 0.78, 0.85);
const text_note = Color.rgb(0.92, 0.88, 0.75);
/// Solid block caret (no blink) — bright orange like a terminal/editor insert cursor.
const caret_block = Color.rgb(1.0, 0.55, 0.12);
/// Glyph drawn on top of the block (dark on orange).
const caret_glyph = Color.rgb(0.12, 0.08, 0.04);

const error_box_fill = Color.rgba(0.32, 0.10, 0.10, 0.94);
const error_box_border = Color.rgb(0.92, 0.38, 0.38);
const error_box_text = Color.rgb(0.96, 0.78, 0.78);
const bubble_border_error = Color.rgb(0.90, 0.40, 0.40);

/// Halo expand distance in world units.
pub const halo_pad: f32 = 20.0;
/// World-space grid step.
pub const grid_step: f32 = 64.0;
/// Gap between bubble bottom and error panel.
const error_box_gap: f32 = 6.0;
const error_box_pad: f32 = 6.0;
const error_box_max_lines: usize = 5;

pub const Renderer = struct {
    pass_action: sg.PassAction = .{},
    /// Alpha-blended pipeline for halos / soft fills / text.
    pip_blend: sgl.Pipeline = .{},

    atlas_img: sg.Image = .{},
    atlas_view: sg.View = .{},
    atlas_smp: sg.Sampler = .{},

    /// Scratch for reflow display lines (reused each frame).
    reflow_lines: std.ArrayListUnmanaged(text_mod.DisplayLine) = .empty,
    highlight_spans: std.ArrayListUnmanaged(highlight.Span) = .empty,
    /// Full logical line buffer for highlighter when drawing wrap segments.
    logical_line_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Scratch for parsed import pills (reused each frame).
    import_pills: std.ArrayListUnmanaged(pills.Import) = .empty,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *Renderer, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{
                .r = clear_color.r,
                .g = clear_color.g,
                .b = clear_color.b,
                .a = 1.0,
            },
        };
        var pip_desc: sg.PipelineDesc = .{};
        pip_desc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };
        self.pip_blend = sgl.makePipeline(pip_desc);

        // Bake JetBrains Mono atlas and upload.
        var pixels: [font_mod.max_atlas_pixels]u8 = undefined;
        if (!Font.bakeRgba(&pixels)) {
            std.log.err("failed to bake JetBrains Mono font atlas", .{});
        }
        const aw = font_mod.atlas_w;
        const ah = font_mod.atlas_h;
        const byte_len = aw * ah * 4;

        self.atlas_img = sg.makeImage(.{
            .width = @intCast(aw),
            .height = @intCast(ah),
            .pixel_format = .RGBA8,
            .data = init: {
                var data: sg.ImageData = .{};
                data.mip_levels[0] = sg.asRange(pixels[0..byte_len]);
                break :init data;
            },
        });
        self.atlas_view = sg.makeView(.{ .texture = .{ .image = self.atlas_img } });
        // LINEAR on a *supersampled* atlas → sharp downsample on HiDPI.
        // (LINEAR on a 1× atlas looked blurry; the supersample is the fix.)
        self.atlas_smp = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        });
    }

    pub fn deinit(self: *Renderer) void {
        self.reflow_lines.deinit(self.allocator);
        self.highlight_spans.deinit(self.allocator);
        self.logical_line_buf.deinit(self.allocator);
        self.import_pills.deinit(self.allocator);
        // Image/view/sampler destroyed with sg.shutdown if not destroyed here.
        if (self.atlas_view.id != 0) sg.destroyView(self.atlas_view);
        if (self.atlas_smp.id != 0) sg.destroySampler(self.atlas_smp);
        if (self.atlas_img.id != 0) sg.destroyImage(self.atlas_img);
        self.* = .{};
    }

    pub fn draw(
        self: *Renderer,
        canvas: *const Canvas,
        store: *const DocumentStore,
        diags: *const DiagStore,
        brackets: *const BracketStore,
        terms: ?*const TermStore,
        active_id: ?bubble_mod.BubbleId,
        focused_id: ?bubble_mod.BubbleId,
        hover_id: ?bubble_mod.BubbleId,
        hover_amount: f32,
        link_hl: ?LinkHighlight,
        menu: ?ContextMenuView,
        completion: ?CompletionPopupView,
        confirm: ?ConfirmModalView,
        top_bar: ?TopBarView,
        drop_doc: bubble_mod.DocId,
    ) void {
        const vp = canvas.viewport;
        const w = vp.screen_w;
        const h = vp.screen_h;
        if (w <= 0 or h <= 0) return;

        sgl.defaults();
        sgl.matrixModeProjection();
        // Screen space, origin top-left, +y down (matches Viewport).
        sgl.ortho(0, w, h, 0, -1, 1);
        sgl.matrixModeModelview();
        sgl.loadIdentity();

        drawGrid(self, vp);
        drawHalos(self, canvas, drop_doc);
        // Links under bubbles (paper 1-M rectilinear arrows).
        drawConnections(self, canvas, focused_id, hover_id, hover_amount, link_hl);
        drawBubbles(self, canvas, store, diags, brackets, terms, active_id, focused_id, hover_id, hover_amount, link_hl);
        if (menu) |m| {
            if (m.open) drawContextMenu(self, vp, m);
        }
        if (completion) |cp| {
            if (cp.open and cp.count > 0) drawCompletionPopup(self, vp, cp);
        }
        if (confirm) |cm| {
            if (cm.open) drawConfirmModal(self, vp, cm);
        }
        if (top_bar) |tb| {
            if (tb.open) drawTopBar(self, vp, tb);
        }
    }

    pub fn passAction(self: *const Renderer) sg.PassAction {
        return self.pass_action;
    }
};

/// Screen-space context menu (drawn after world content).
pub const ContextMenuView = struct {
    open: bool = false,
    /// Top-left in framebuffer / screen pixels.
    x: f32 = 0,
    y: f32 = 0,
    /// Index of hovered item, or -1.
    hover_item: i32 = -1,
};

/// Screen-space completion list (near caret).
pub const CompletionPopupView = struct {
    open: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    /// Selected row (keyboard).
    selected: i32 = 0,
    /// Hovered row, or -1.
    hover_item: i32 = -1,
    /// Number of valid rows in labels/kinds.
    count: u32 = 0,
    /// Row labels (not owned by renderer).
    labels: []const []const u8 = &.{},
    /// Kind tags: "kw" / "bi" / "sym" (not owned).
    kinds: []const []const u8 = &.{},
};

pub const context_menu_item_h: f32 = 28;
pub const context_menu_w: f32 = 180;
pub const context_menu_pad: f32 = 6;
pub const completion_item_h: f32 = 24;
pub const completion_w: f32 = 240;
pub const completion_pad: f32 = 4;
pub const completion_max_visible: u32 = 12;

/// Centered modal: message + Delete / Cancel.
pub const ConfirmModalView = struct {
    open: bool = false,
    /// Which button is hovered: -1 none, 0 Delete, 1 Cancel.
    hover_btn: i32 = -1,
    message: []const u8 = "Are you sure about deleting this bubble?",
};

/// Screen-space project breadcrumb bar (top of window).
pub const TopBarView = struct {
    open: bool = false,
    segment_count: u32 = 0,
    segments: []const []const u8 = &.{},
    hover_seg: i32 = -1,
};

pub const confirm_modal_w: f32 = 360;
pub const confirm_modal_h: f32 = 140;
pub const confirm_btn_w: f32 = 100;
pub const confirm_btn_h: f32 = 32;
/// Labels for menu rows (extend as needed).
pub const context_menu_labels = [_][]const u8{
    "Create new file",
    "New terminal",
};

pub fn contextMenuItemCount() usize {
    return context_menu_labels.len;
}

pub fn contextMenuHeight() f32 {
    return context_menu_pad * 2 + context_menu_item_h * @as(f32, @floatFromInt(context_menu_labels.len));
}

/// Returns item index under screen point, or null. `dpi` matches draw scaling.
pub fn contextMenuHit(menu: ContextMenuView, sx: f32, sy: f32, dpi: f32) ?usize {
    if (!menu.open) return null;
    const scale = @max(dpi, 1.0);
    const mw = context_menu_w * scale;
    const ih = context_menu_item_h * scale;
    const pad = context_menu_pad * scale;
    const mh = pad * 2 + ih * @as(f32, @floatFromInt(context_menu_labels.len));

    const mx = menu.x;
    const my = menu.y;
    if (sx < mx or sy < my) return null;
    if (sx >= mx + mw or sy >= my + mh) return null;
    const rel_y = sy - my - pad;
    if (rel_y < 0) return null;
    const idx: i32 = @intFromFloat(@floor(rel_y / ih));
    if (idx < 0 or idx >= context_menu_labels.len) return null;
    return @intCast(idx);
}

const menu_bg = Color.rgb(0.16, 0.17, 0.20);
const menu_border = Color.rgb(0.40, 0.42, 0.48);
const menu_hover = Color.rgb(0.28, 0.32, 0.42);
const menu_text = Color.rgb(0.90, 0.91, 0.93);
const modal_scrim = Color.rgba(0.0, 0.0, 0.0, 0.45);
const modal_btn_delete = Color.rgb(0.72, 0.28, 0.28);
const modal_btn_delete_hover = Color.rgb(0.85, 0.35, 0.35);
const modal_btn_cancel = Color.rgb(0.28, 0.30, 0.36);
const modal_btn_cancel_hover = Color.rgb(0.38, 0.40, 0.48);
const close_btn_fg = Color.rgb(0.85, 0.55, 0.55);
const close_btn_fg_hot = Color.rgb(1.0, 0.45, 0.45);

const conn_color = Color.rgba(0.45, 0.72, 0.88, 0.85);
const conn_color_active = Color.rgba(0.55, 0.85, 1.0, 0.95);
/// Neon core when a link is hovered (GlowRays-style bloom + bright spine).
const conn_color_hover = Color.rgba(1.0, 0.88, 0.35, 1.0);
const conn_glow_hover = Color.rgb(1.0, 0.72, 0.15);
const link_bubble_border = Color.rgb(1.0, 0.78, 0.28);
const selection_bg = Color.rgba(0.30, 0.50, 0.85, 0.35);

/// Highlight call site / endpoints when an arrow is hovered.
pub const LinkHighlight = struct {
    conn_id: bubble_mod.ConnectionId,
    from_bubble: bubble_mod.BubbleId,
    to_bubble: bubble_mod.BubbleId,
    /// Absolute document line of the call (0-based).
    call_line: ?u32 = null,
    call_col_start: ?u32 = null,
    call_col_end: ?u32 = null,
};

fn drawContextMenu(r: *Renderer, vp: Viewport, menu: ContextMenuView) void {
    const scale = @max(vp.dpi, 1.0);
    const mw = context_menu_w * scale;
    const ih = context_menu_item_h * scale;
    const pad = context_menu_pad * scale;
    const mh = pad * 2 + ih * @as(f32, @floatFromInt(context_menu_labels.len));

    // Keep menu on-screen.
    var mx = menu.x;
    var my = menu.y;
    if (mx + mw > vp.screen_w) mx = vp.screen_w - mw;
    if (my + mh > vp.screen_h) my = vp.screen_h - mh;
    if (mx < 0) mx = 0;
    if (my < 0) my = 0;

    // Panel
    fillScreenRect(mx, my, mx + mw, my + mh, menu_bg);
    const bt = @max(1.0, scale);
    strokeScreenRect(mx, my, mx + mw, my + mh, menu_border, bt);

    for (context_menu_labels, 0..) |label, i| {
        const iy0 = my + pad + @as(f32, @floatFromInt(i)) * ih;
        const iy1 = iy0 + ih;
        if (menu.hover_item == @as(i32, @intCast(i))) {
            fillScreenRect(mx + 2 * scale, iy0, mx + mw - 2 * scale, iy1, menu_hover);
        }
        // Draw label in screen space: convert screen box back to "fake" world
        // by using emitGlyph with a temporary 1:1 mapping via drawTextScreen.
        drawTextScreen(r, vp, label, mx + pad + 4 * scale, iy0 + (ih - Font.charH() * vp.pixelScale()) * 0.5, menu_text);
    }
}

fn drawCloseButton(vp: Viewport, box: BoundingBox, hot: bool) void {
    const col = if (hot) close_btn_fg_hot else close_btn_fg;
    const tl = vp.worldToScreen(.{ .x = box.x, .y = box.y });
    const br = vp.worldToScreen(.{ .x = box.right(), .y = box.bottom() });
    const pad = @max(2.0, (br.x - tl.x) * 0.28);
    const x0 = tl.x + pad;
    const y0 = tl.y + pad;
    const x1 = br.x - pad;
    const y1 = br.y - pad;
    // Two diagonal strokes as thin quads.
    const t: f32 = @max(1.2, (br.x - tl.x) * 0.12);
    strokeScreenSeg(x0, y0, x1, y1, t, col);
    strokeScreenSeg(x1, y0, x0, y1, t, col);
}

fn strokeScreenSeg(ax: f32, ay: f32, bx: f32, by: f32, thick: f32, c: Color) void {
    var dx = bx - ax;
    var dy = by - ay;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;
    dx /= len;
    dy /= len;
    const half = thick * 0.5;
    const px = -dy * half;
    const py = dx * half;
    sgl.beginQuads();
    sgl.v2fC4f(ax + px, ay + py, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(ax - px, ay - py, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(bx - px, by - py, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(bx + px, by + py, c.r, c.g, c.b, c.a);
    sgl.end();
}

/// Resolved screen-space geometry for the confirm modal. Computed in one place
/// so drawing and hit-testing always agree, and the panel sizes to its content.
const ConfirmModalLayout = struct {
    mx: f32,
    my: f32,
    mw: f32,
    mh: f32,
    delete_x: f32,
    cancel_x: f32,
    by0: f32,
    bw: f32,
    bh: f32,
    gap: f32,
    msg_x: f32,
    msg_y: f32,
};

/// Side padding between the panel edge and its content.
const confirm_modal_pad: f32 = 16;

fn confirmModalLayout(modal: ConfirmModalView, screen_w: f32, screen_h: f32, dpi: f32) ConfirmModalLayout {
    const scale = @max(dpi, 1.0);
    const pad = confirm_modal_pad * scale;
    const bw = confirm_btn_w * scale;
    const bh = confirm_btn_h * scale;
    const gap = 16 * scale;

    // Fit the wider of the message and the button row, then add side padding.
    const msg_w = @as(f32, @floatFromInt(modal.message.len)) * Font.charW() * scale;
    const btn_row_w = bw * 2 + gap;
    const content_w = @max(msg_w, btn_row_w);
    const mw = @max(confirm_modal_w * scale, content_w + pad * 2);
    const mh = confirm_modal_h * scale;

    const mx = (screen_w - mw) * 0.5;
    const my = (screen_h - mh) * 0.5;

    const by0 = my + mh - bh - 20 * scale;
    return .{
        .mx = mx,
        .my = my,
        .mw = mw,
        .mh = mh,
        .delete_x = mx + mw * 0.5 - bw - gap * 0.5,
        .cancel_x = mx + mw * 0.5 + gap * 0.5,
        .by0 = by0,
        .bw = bw,
        .bh = bh,
        .gap = gap,
        .msg_x = mx + pad,
        .msg_y = my + 28 * scale,
    };
}

fn drawConfirmModal(r: *Renderer, vp: Viewport, modal: ConfirmModalView) void {
    const scale = @max(vp.dpi, 1.0);
    // Dim the canvas.
    fillScreenRect(0, 0, vp.screen_w, vp.screen_h, modal_scrim);

    const lyt = confirmModalLayout(modal, vp.screen_w, vp.screen_h, vp.dpi);

    fillScreenRect(lyt.mx, lyt.my, lyt.mx + lyt.mw, lyt.my + lyt.mh, menu_bg);
    strokeScreenRect(lyt.mx, lyt.my, lyt.mx + lyt.mw, lyt.my + lyt.mh, menu_border, @max(1.0, scale));

    // Message (single line; panel width is sized to fit it). Fixed scale so the
    // modal never grows with canvas zoom (it appears after a focus zoom-in).
    drawTextScreenFixed(r, modal.message, lyt.msg_x, lyt.msg_y, scale, menu_text);

    // Buttons: Delete (left), Cancel (right).
    const del_bg = if (modal.hover_btn == 0) modal_btn_delete_hover else modal_btn_delete;
    const can_bg = if (modal.hover_btn == 1) modal_btn_cancel_hover else modal_btn_cancel;
    fillScreenRect(lyt.delete_x, lyt.by0, lyt.delete_x + lyt.bw, lyt.by0 + lyt.bh, del_bg);
    fillScreenRect(lyt.cancel_x, lyt.by0, lyt.cancel_x + lyt.bw, lyt.by0 + lyt.bh, can_bg);

    const ty = lyt.by0 + (lyt.bh - Font.charH() * scale) * 0.5;
    // Center labels roughly inside buttons.
    const del_label = "Delete";
    const can_label = "Cancel";
    const del_tx = lyt.delete_x + (lyt.bw - @as(f32, @floatFromInt(del_label.len)) * Font.charW() * scale) * 0.5;
    const can_tx = lyt.cancel_x + (lyt.bw - @as(f32, @floatFromInt(can_label.len)) * Font.charW() * scale) * 0.5;
    drawTextScreenFixed(r, del_label, del_tx, ty, scale, menu_text);
    drawTextScreenFixed(r, can_label, can_tx, ty, scale, menu_text);
}

/// Hit-test confirm modal buttons. Returns 0=Delete, 1=Cancel, null=elsewhere (including scrim).
pub fn confirmModalHit(modal: ConfirmModalView, sx: f32, sy: f32, screen_w: f32, screen_h: f32, dpi: f32) ?i32 {
    if (!modal.open) return null;
    const lyt = confirmModalLayout(modal, screen_w, screen_h, dpi);
    if (sx >= lyt.delete_x and sx < lyt.delete_x + lyt.bw and sy >= lyt.by0 and sy < lyt.by0 + lyt.bh) return 0;
    if (sx >= lyt.cancel_x and sx < lyt.cancel_x + lyt.bw and sy >= lyt.by0 and sy < lyt.by0 + lyt.bh) return 1;
    return null;
}

/// True if point is inside the modal panel (not scrim).
pub fn confirmModalPanelHit(modal: ConfirmModalView, sx: f32, sy: f32, screen_w: f32, screen_h: f32, dpi: f32) bool {
    if (!modal.open) return false;
    const lyt = confirmModalLayout(modal, screen_w, screen_h, dpi);
    return sx >= lyt.mx and sx < lyt.mx + lyt.mw and sy >= lyt.my and sy < lyt.my + lyt.mh;
}

fn drawCompletionPopup(r: *Renderer, vp: Viewport, popup: CompletionPopupView) void {
    const scale = @max(vp.dpi, 1.0);
    const mw = completion_w * scale;
    const ih = completion_item_h * scale;
    const pad = completion_pad * scale;
    const n = @min(popup.count, completion_max_visible);
    if (n == 0) return;
    const mh = pad * 2 + ih * @as(f32, @floatFromInt(n));

    var mx = popup.x;
    var my = popup.y;
    if (mx + mw > vp.screen_w) mx = @max(0, vp.screen_w - mw);
    if (my + mh > vp.screen_h) my = @max(0, popup.y - mh - Font.charH() * scale); // above caret
    if (mx < 0) mx = 0;
    if (my < 0) my = 0;

    fillScreenRect(mx, my, mx + mw, my + mh, menu_bg);
    const bt = @max(1.0, scale);
    strokeScreenRect(mx, my, mx + mw, my + mh, menu_border, bt);

    const kind_col = Color.rgb(0.55, 0.70, 0.85);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const iy0 = my + pad + @as(f32, @floatFromInt(i)) * ih;
        const iy1 = iy0 + ih;
        const selected = popup.selected == @as(i32, @intCast(i));
        const hovered = popup.hover_item == @as(i32, @intCast(i));
        if (selected or hovered) {
            fillScreenRect(mx + 2 * scale, iy0, mx + mw - 2 * scale, iy1, menu_hover);
        }
        const label = if (i < popup.labels.len) popup.labels[i] else "";
        const kind = if (i < popup.kinds.len) popup.kinds[i] else "";
        const ty = iy0 + (ih - Font.charH() * scale) * 0.5;
        drawTextScreen(r, vp, label, mx + pad + 4 * scale, ty, menu_text);
        // Kind tag right-aligned-ish
        const kind_x = mx + mw - pad - 4 * scale - @as(f32, @floatFromInt(kind.len)) * Font.charW() * scale;
        drawTextScreen(r, vp, kind, kind_x, ty, kind_col);
    }
}

/// Hit-test completion row under screen point.
pub fn completionHit(popup: CompletionPopupView, sx: f32, sy: f32, dpi: f32) ?usize {
    if (!popup.open or popup.count == 0) return null;
    const scale = @max(dpi, 1.0);
    const mw = completion_w * scale;
    const ih = completion_item_h * scale;
    const pad = completion_pad * scale;
    const n = @min(popup.count, completion_max_visible);
    const mx = popup.x;
    const my = popup.y;
    if (sx < mx or sy < my) return null;
    if (sx >= mx + mw) return null;
    const rel_y = sy - my - pad;
    if (rel_y < 0) return null;
    const idx: i32 = @intFromFloat(@floor(rel_y / ih));
    if (idx < 0 or idx >= @as(i32, @intCast(n))) return null;
    return @intCast(idx);
}

/// Draw text starting at screen-pixel position (for UI chrome).
fn drawTextScreen(r: *Renderer, vp: Viewport, bytes: []const u8, sx: f32, sy: f32, color: Color) void {
    // Inverse of worldToScreen at pan=0 so emitGlyph lands at sx,sy.
    // world = screen / pixelScale + pan; with pan 0: world = screen / pixelScale
    const s = vp.pixelScale();
    if (s <= 0) return;
    const world_y = sy / s; // assuming pan handled... emitGlyph uses full viewport pan.
    // Compensate pan so worldToScreen(world) ≈ screen:
    // (world - pan) * s = screen => world = screen/s + pan
    const wx0 = sx / s + vp.pan.x;
    const wy0 = world_y + vp.pan.y;

    sgl.loadPipeline(r.pip_blend);
    sgl.enableTexture();
    sgl.texture(r.atlas_view, r.atlas_smp);
    sgl.beginQuads();
    const cw = Font.charW();
    var x = wx0;
    for (bytes) |c| {
        if (c >= 32 and c < 127) {
            emitGlyph(vp, x, wy0, c, color);
        }
        x += cw;
    }
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

/// Draw text in raw screen space at a fixed pixel scale, independent of canvas zoom.
/// Overlays (modals, menus) must keep a constant on-screen size even while the
/// canvas is zoomed, so they can't go through `drawTextScreen` (which scales glyphs
/// by `pixelScale = zoom * dpi`). `scale` is pixels-per-logical-unit, e.g. max(dpi, 1).
fn drawTextScreenFixed(r: *Renderer, bytes: []const u8, sx: f32, sy: f32, scale: f32, color: Color) void {
    const cw = Font.charW() * scale;
    const ch = Font.charH() * scale;
    const w = @max(@as(f32, 1), @round(cw));
    const h = @max(@as(f32, 1), @round(ch));
    sgl.loadPipeline(r.pip_blend);
    sgl.enableTexture();
    sgl.texture(r.atlas_view, r.atlas_smp);
    sgl.beginQuads();
    var x = sx;
    for (bytes) |c| {
        if (c >= 32 and c < 127) {
            const uv = Font.glyphUv(c);
            const x0 = @floor(x + 0.5);
            const y0 = @floor(sy + 0.5);
            const x1 = x0 + w;
            const y1 = y0 + h;
            sgl.v2fT2fC4f(x0, y0, uv.u_min, uv.v_min, color.r, color.g, color.b, color.a);
            sgl.v2fT2fC4f(x1, y0, uv.u_max, uv.v_min, color.r, color.g, color.b, color.a);
            sgl.v2fT2fC4f(x1, y1, uv.u_max, uv.v_max, color.r, color.g, color.b, color.a);
            sgl.v2fT2fC4f(x0, y1, uv.u_min, uv.v_max, color.r, color.g, color.b, color.a);
        }
        x += cw;
    }
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn drawGrid(r: *Renderer, vp: Viewport) void {
    const visible = vp.visibleWorldBounds();
    const step = grid_step;
    const start_x = @floor(visible.x / step) * step;
    const start_y = @floor(visible.y / step) * step;
    const end_x = visible.right();
    const end_y = visible.bottom();

    // Alpha only works with the blended pipeline.
    sgl.loadPipeline(r.pip_blend);
    sgl.beginLines();
    var x = start_x;
    while (x <= end_x) : (x += step) {
        const major = @mod(@abs(x / step), 4) < 0.5;
        const c = if (major) grid_major_color else grid_color;
        const a = vp.worldToScreen(.{ .x = x, .y = visible.y });
        const b = vp.worldToScreen(.{ .x = x, .y = end_y });
        sgl.v2fC4f(a.x, a.y, c.r, c.g, c.b, c.a);
        sgl.v2fC4f(b.x, b.y, c.r, c.g, c.b, c.a);
    }
    var y = start_y;
    while (y <= end_y) : (y += step) {
        const major = @mod(@abs(y / step), 4) < 0.5;
        const c = if (major) grid_major_color else grid_color;
        const a = vp.worldToScreen(.{ .x = visible.x, .y = y });
        const b = vp.worldToScreen(.{ .x = end_x, .y = y });
        sgl.v2fC4f(a.x, a.y, c.r, c.g, c.b, c.a);
        sgl.v2fC4f(b.x, b.y, c.r, c.g, c.b, c.a);
    }
    sgl.end();
    sgl.loadDefaultPipeline();
}

fn drawHalos(r: *Renderer, canvas: *const Canvas, drop_doc: bubble_mod.DocId) void {
    if (canvas.groups.items.len == 0) return;

    sgl.loadPipeline(r.pip_blend);
    for (canvas.groups.items) |group| {
        const world_box = canvas.groupBounds(group.id) orelse continue;
        const padded = world_box.expanded(halo_pad);
        var c = halo_palette[group.color_index % halo_palette.len];
        if (drop_doc != bubble_mod.INVALID_DOC and group.doc == drop_doc) {
            // Brighten drop target.
            c = halo_drop_tint;
        }
        fillWorldRect(canvas.viewport, padded, c);
    }
    sgl.loadDefaultPipeline();
}

fn drawTopBar(r: *Renderer, vp: Viewport, bar: TopBarView) void {
    const scale = @max(vp.dpi, 1.0);
    const h = top_bar_h * scale;
    fillScreenRect(0, 0, vp.screen_w, h, top_bar_bg);
    strokeScreenRect(0, 0, vp.screen_w, h, top_bar_border, @max(1.0, scale));

    var x: f32 = 12 * scale;
    const ty = (h - Font.charH() * scale) * 0.5;
    const pad_x = 6 * scale;
    const pad_y = 4 * scale;

    var i: u32 = 0;
    while (i < bar.segment_count) : (i += 1) {
        const seg = if (i < bar.segments.len) bar.segments[i] else "";
        const tw = @as(f32, @floatFromInt(seg.len)) * Font.charW() * scale;
        const bx0 = x - pad_x;
        const bx1 = x + tw + pad_x;
        if (bar.hover_seg == @as(i32, @intCast(i))) {
            fillScreenRect(bx0, pad_y, bx1, h - pad_y, top_bar_hover);
        }
        drawTextScreenFixed(r, seg, x, ty, scale, top_bar_text);
        x = bx1 + 4 * scale;
        if (i + 1 < bar.segment_count) {
            drawTextScreenFixed(r, "/", x, ty, scale, top_bar_sep);
            x += Font.charW() * scale + 4 * scale;
        }
    }
}

/// Hit-test breadcrumb segment under screen point. Returns segment index or null.
pub fn topBarHit(bar: TopBarView, sx: f32, sy: f32, dpi: f32) ?usize {
    if (!bar.open or bar.segment_count == 0) return null;
    const scale = @max(dpi, 1.0);
    const h = top_bar_h * scale;
    if (sy < 0 or sy >= h) return null;

    var x: f32 = 12 * scale;
    const pad_x = 6 * scale;
    var i: u32 = 0;
    while (i < bar.segment_count) : (i += 1) {
        const seg = if (i < bar.segments.len) bar.segments[i] else "";
        const tw = @as(f32, @floatFromInt(seg.len)) * Font.charW() * scale;
        const bx0 = x - pad_x;
        const bx1 = x + tw + pad_x;
        if (sx >= bx0 and sx < bx1) return i;
        x = bx1 + 4 * scale;
        if (i + 1 < bar.segment_count) {
            x += Font.charW() * scale + 4 * scale;
        }
    }
    return null;
}

fn drawConnections(
    r: *Renderer,
    canvas: *const Canvas,
    focused_id: ?bubble_mod.BubbleId,
    hover_id: ?bubble_mod.BubbleId,
    hover_amount: f32,
    link_hl: ?LinkHighlight,
) void {
    if (canvas.connections.items.len == 0) return;

    const vp = canvas.viewport;
    const base_thick = 2.5 / @max(vp.pixelScale(), 1.0);
    const arrow_size = 12.0;
    const hover_scale = 1.0 + (hover_scale_max - 1.0) * std.math.clamp(hover_amount, 0, 1);

    sgl.loadPipeline(r.pip_blend);

    for (canvas.connections.items) |conn| {
        const from_b = canvas.findBubbleConst(conn.from.bubble) orelse continue;
        const to_b = canvas.findBubbleConst(conn.to.bubble) orelse continue;

        var from_box = from_b.bounds;
        var to_box = to_b.bounds;
        if (hover_id != null and hover_amount > 0.001) {
            if (hover_id.? == from_b.id) from_box = scaledBox(from_box, hover_scale);
            if (hover_id.? == to_b.id) to_box = scaledBox(to_box, hover_scale);
        }

        const on_link = link_hl != null and link_hl.?.conn_id == conn.id;
        const active = on_link or
            (focused_id != null and (focused_id.? == from_b.id or focused_id.? == to_b.id)) or
            (hover_id != null and (hover_id.? == from_b.id or hover_id.? == to_b.id));
        const col = if (on_link) conn_color_hover else if (active) conn_color_active else conn_color;
        const thick = if (on_link) base_thick * 1.8 else if (active) base_thick * 1.25 else base_thick;

        const pl = connection_mod.routeRectilinear(from_box, to_box);
        if (pl.len < 2) continue;

        // Neon bloom under the spine when this link is highlighted (GlowRays-style).
        if (on_link) {
            strokePolylineGlow(vp, pl, thick, conn_glow_hover);
        }

        var i: u8 = 1;
        while (i < pl.len) : (i += 1) {
            strokeWorldSegment(vp, pl.points[i - 1], pl.points[i], thick, col);
        }

        if (connection_mod.arrowHead(pl, if (on_link) arrow_size * 1.35 else arrow_size)) |ah| {
            if (on_link) fillWorldTriangleGlow(vp, ah.tip, ah.left, ah.right, conn_glow_hover);
            fillWorldTriangle(vp, ah.tip, ah.left, ah.right, col);
        }
    }

    sgl.loadDefaultPipeline();
}

fn scaledBox(b: BoundingBox, scale: f32) BoundingBox {
    if (@abs(scale - 1.0) < 0.001) return b;
    const c = b.center();
    const nw = b.w * scale;
    const nh = b.h * scale;
    return .{
        .x = c.x - nw * 0.5,
        .y = c.y - nh * 0.5,
        .w = nw,
        .h = nh,
    };
}

fn strokeWorldSegment(vp: Viewport, a: geom.Vec2, b: geom.Vec2, thick: f32, c: Color) void {
    const sa = vp.worldToScreen(a);
    const sb = vp.worldToScreen(b);
    var dx = sb.x - sa.x;
    var dy = sb.y - sa.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;
    dx /= len;
    dy /= len;
    // Screen-space thickness
    const t = thick * vp.pixelScale() * 0.5;
    const px = -dy * t;
    const py = dx * t;
    // Quad along segment
    sgl.beginQuads();
    sgl.v2fC4f(sa.x + px, sa.y + py, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(sa.x - px, sa.y - py, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(sb.x - px, sb.y - py, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(sb.x + px, sb.y + py, c.r, c.g, c.b, c.a);
    sgl.end();
}

/// Multi-layer soft bloom along a polyline (outer → inner, additive neon haze).
fn strokePolylineGlow(vp: Viewport, pl: connection_mod.Polyline, core_thick: f32, tint: Color) void {
    const layers: u32 = 10;
    var li: i32 = @intCast(layers);
    while (li >= 1) : (li -= 1) {
        const t = @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(layers));
        // Wide outer haze → tighter mid glow (more steps = smoother falloff).
        const thick = core_thick * (1.0 + t * 9.0);
        const fall = 1.0 - t;
        const a = 0.32 * fall * fall * fall + 0.02 * fall;
        const col = Color.rgba(tint.r, tint.g, tint.b, a);
        var i: u8 = 1;
        while (i < pl.len) : (i += 1) {
            strokeWorldSegment(vp, pl.points[i - 1], pl.points[i], thick, col);
        }
    }
}

/// Soft expanded triangle bloom under a bright arrowhead.
fn fillWorldTriangleGlow(vp: Viewport, a: geom.Vec2, b: geom.Vec2, c: geom.Vec2, tint: Color) void {
    const sa = vp.worldToScreen(a);
    const sb = vp.worldToScreen(b);
    const sc = vp.worldToScreen(c);
    const cx = (sa.x + sb.x + sc.x) / 3.0;
    const cy = (sa.y + sb.y + sc.y) / 3.0;
    const layers: u32 = 4;
    var li: u32 = layers;
    while (li >= 1) : (li -= 1) {
        const t = @as(f32, @floatFromInt(li)) / @as(f32, @floatFromInt(layers));
        const scale = 1.0 + t * 1.4;
        const a_alpha = 0.22 * (1.0 - t) * (1.0 - t);
        const col = Color.rgba(tint.r, tint.g, tint.b, a_alpha);
        const ax = cx + (sa.x - cx) * scale;
        const ay = cy + (sa.y - cy) * scale;
        const bx = cx + (sb.x - cx) * scale;
        const by = cy + (sb.y - cy) * scale;
        const cx2 = cx + (sc.x - cx) * scale;
        const cy2 = cy + (sc.y - cy) * scale;
        sgl.beginTriangles();
        sgl.v2fC4f(ax, ay, col.r, col.g, col.b, col.a);
        sgl.v2fC4f(bx, by, col.r, col.g, col.b, col.a);
        sgl.v2fC4f(cx2, cy2, col.r, col.g, col.b, col.a);
        sgl.end();
    }
}

fn fillWorldTriangle(vp: Viewport, a: geom.Vec2, b: geom.Vec2, c: geom.Vec2, col: Color) void {
    const sa = vp.worldToScreen(a);
    const sb = vp.worldToScreen(b);
    const sc = vp.worldToScreen(c);
    sgl.beginTriangles();
    sgl.v2fC4f(sa.x, sa.y, col.r, col.g, col.b, col.a);
    sgl.v2fC4f(sb.x, sb.y, col.r, col.g, col.b, col.a);
    sgl.v2fC4f(sc.x, sc.y, col.r, col.g, col.b, col.a);
    sgl.end();
}

/// Peak scale when fully hovered (1.0 = no change).
/// Hover lift. Screen-space only — `main.unscaleHover` maps clicks back through it.
pub const hover_scale_max: f32 = 1.07;

/// Per-line bracket coloring context (absolute document offsets).
const BracketDrawCtx = struct {
    index: *const brackets_mod.BracketIndex,
    /// Absolute byte offset of the start of the current logical line.
    line_abs_start: u32,
    active_open: ?u32 = null,
    active_close: ?u32 = null,
};

fn drawBubbles(
    r: *Renderer,
    canvas: *const Canvas,
    store: *const DocumentStore,
    diags: *const DiagStore,
    brackets: *const BracketStore,
    terms: ?*const TermStore,
    active_id: ?bubble_mod.BubbleId,
    focused_id: ?bubble_mod.BubbleId,
    hover_id: ?bubble_mod.BubbleId,
    hover_amount: f32,
    link_hl: ?LinkHighlight,
) void {
    const vp = canvas.viewport;

    // Draw non-hovered first, then hovered on top so scale sits above neighbors.
    var pass: u32 = 0;
    while (pass < 2) : (pass += 1) {
        for (canvas.bubbles.items) |b| {
            const is_focused_b = focused_id != null and focused_id.? == b.id;
            // No hover chrome/scale on the bubble you're already editing.
            const is_hover = hover_id != null and hover_id.? == b.id and hover_amount > 0.001 and !is_focused_b;
            const on_link = link_hl != null and (link_hl.?.from_bubble == b.id or link_hl.?.to_bubble == b.id);
            if (pass == 0 and (is_hover or on_link)) continue;
            if (pass == 1 and !(is_hover or on_link)) continue;

            const scale: f32 = if (is_hover)
                1.0 + (hover_scale_max - 1.0) * std.math.clamp(hover_amount, 0, 1)
            else
                1.0;

            if (scale != 1.0) {
                const c = b.bounds.center();
                const sc = vp.worldToScreen(c);
                sgl.matrixModeModelview();
                sgl.pushMatrix();
                sgl.translate(sc.x, sc.y, 0);
                sgl.scale(scale, scale, 1);
                sgl.translate(-sc.x, -sc.y, 0);
            }

            drawOneBubble(r, vp, store, diags, brackets, terms, &b, active_id, focused_id, is_hover, link_hl);

            if (scale != 1.0) {
                sgl.matrixModeModelview();
                sgl.popMatrix();
            }
        }
    }
}

fn drawOneBubble(
    r: *Renderer,
    vp: Viewport,
    store: *const DocumentStore,
    diags: *const DiagStore,
    brackets: *const BracketStore,
    terms: ?*const TermStore,
    b: *const bubble_mod.Bubble,
    active_id: ?bubble_mod.BubbleId,
    focused_id: ?bubble_mod.BubbleId,
    is_hover: bool,
    link_hl: ?LinkHighlight,
) void {
    const fill = switch (b.kind) {
        .code => bubble_fill_code,
        .note => bubble_fill_note,
        .imports => bubble_fill_imports,
        .terminal => bubble_fill_terminal,
        .folder => bubble_fill_folder,
        else => bubble_fill_other,
    };
    const is_active = (active_id != null and active_id.? == b.id) or
        (focused_id != null and focused_id.? == b.id);
    const on_link = link_hl != null and (link_hl.?.from_bubble == b.id or link_hl.?.to_bubble == b.id);
    const has_errors = b.kind != .terminal and bubbleHasErrors(diags, b);
    const border = if (on_link)
        link_bubble_border
    else if (has_errors)
        bubble_border_error
    else if (is_active or is_hover)
        bubble_border_active
    else if (b.kind == .imports)
        bubble_border_imports
    else if (b.kind == .terminal)
        bubble_border_terminal
    else if (b.kind == .folder)
        bubble_border_folder
    else
        bubble_border;
    // Linked bubbles: clear but not a thick yellow frame that fights the code.
    const border_w: f32 = if (on_link) 2.0 else if (has_errors) 2.5 else if (is_hover) 2.5 else if (is_active) 2.0 else 1.5;

    fillWorldRoundRect(vp, b.bounds, bubble_corner_r, fill);

    const crumb_h = @min(b.pad_y, b.bounds.h * 0.35);
    if (crumb_h > 1) {
        // Title strip with matching top corners so it doesn't square off the bubble.
        const crumb = BoundingBox{
            .x = b.bounds.x,
            .y = b.bounds.y,
            .w = b.bounds.w,
            .h = crumb_h,
        };
        fillWorldRoundTopRect(vp, crumb, bubble_corner_r, breadcrumb_fill);
    }

    strokeWorldRoundRect(vp, b.bounds, bubble_corner_r, border, border_w);

    // Folder tab accent (simple folder silhouette).
    if (b.kind == .folder) {
        const tab = BoundingBox{
            .x = b.bounds.x + 10,
            .y = b.bounds.y + crumb_h * 0.35,
            .w = 28,
            .h = 10,
        };
        fillWorldRoundRect(vp, tab, 3, folder_tab);
        const body = BoundingBox{
            .x = b.bounds.x + 8,
            .y = b.bounds.y + crumb_h * 0.35 + 8,
            .w = b.bounds.w - 16,
            .h = b.bounds.h - crumb_h * 0.35 - 16,
        };
        fillWorldRoundRect(vp, body, 4, folder_tab);
    }

    // Terminal titles come from the live session (drawn in the terminal body path).
    if (b.kind != .terminal and b.title.len != 0 and crumb_h > 4) {
        var title_buf: [320]u8 = undefined;
        var title_slice: []const u8 = b.title;
        // Per-bubble dirty star (not whole-document — many bubbles share one file).
        if (b.dirty) {
            title_slice = std.fmt.bufPrint(&title_buf, "* {s}", .{b.title}) catch b.title;
        }
        // Leave room for the close button on the right.
        const close_reserve = bubble_mod.Bubble.close_btn_size + bubble_mod.Bubble.close_btn_pad * 2;
        const title_box = BoundingBox{
            .x = b.bounds.x + b.pad_x,
            .y = b.bounds.y + 3,
            .w = @max(0, b.bounds.w - b.pad_x * 2 - close_reserve),
            .h = crumb_h - 4,
        };
        drawTextLineClipped(r, vp, title_slice, title_box, text_title, null, 0, null, null);
    }

    // Title-bar remove control (×) — only on the focused bubble.
    const show_close = focused_id != null and focused_id.? == b.id;
    if (crumb_h > 8 and show_close) {
        drawCloseButton(vp, b.closeButtonBounds(), is_hover or is_active);
    }

    const is_focused = focused_id != null and focused_id.? == b.id;

    if (b.kind == .terminal) {
        if (terms) |ts| {
            if (b.term_id != bubble_mod.INVALID_TERM) {
                if (ts.findConst(b.term_id)) |sess| {
                    // Prefer live session title (e.g. exited suffix).
                    if (sess.title.len != 0 and crumb_h > 4) {
                        const close_reserve = bubble_mod.Bubble.close_btn_size + bubble_mod.Bubble.close_btn_pad * 2;
                        const title_box = BoundingBox{
                            .x = b.bounds.x + b.pad_x,
                            .y = b.bounds.y + 3,
                            .w = @max(0, b.bounds.w - b.pad_x * 2 - close_reserve),
                            .h = crumb_h - 4,
                        };
                        // Overwrite the static bubble title with session title.
                        drawTextLineClipped(r, vp, sess.title, title_box, text_title, null, 0, null, null);
                    }
                    drawTerminalContent(r, vp, b, sess, is_focused);
                }
            }
        }
    } else {
        const body = b.displayText(store);
        if (body.len != 0 or b.kind == .code) {
            const content = b.contentBounds();
            var lang: detect.Language = .unknown;
            if (b.fragment()) |f| {
                if (store.getConst(f.doc)) |d| lang = d.lang;
            }
            // An import block is eight lines of near-identical boilerplate; unfocused, the set of
            // names is all a reader wants. Focus swaps back to real code so it stays editable.
            // `drawImportPills` reports false when the block has no pills to show (Rust `use`,
            // `usingnamespace`) — those fall through to code rather than rendering an empty box.
            const drew_pills = b.kind == .imports and !is_focused and drawImportPills(r, vp, body, content, lang);
            if (!drew_pills) {
                drawCodeContent(r, vp, store, brackets, body, content, lang, b.kind == .note, b, link_hl, is_focused);
            }
        }

        if (is_focused) {
            drawCaret(r, vp, store, b);
        }

        if (has_errors) {
            drawErrorBox(r, vp, diags, b);
        }
    }
}

/// ANSI 16-color palette for terminal cells (sRGB-ish on dark bg).
const term_palette = [_]Color{
    Color.rgb(0.12, 0.12, 0.12), // black
    Color.rgb(0.80, 0.28, 0.28), // red
    Color.rgb(0.35, 0.75, 0.40), // green
    Color.rgb(0.85, 0.75, 0.30), // yellow
    Color.rgb(0.35, 0.50, 0.90), // blue
    Color.rgb(0.75, 0.40, 0.80), // magenta
    Color.rgb(0.35, 0.78, 0.80), // cyan
    Color.rgb(0.85, 0.87, 0.90), // white
    Color.rgb(0.40, 0.42, 0.45), // bright black
    Color.rgb(1.00, 0.45, 0.45), // bright red
    Color.rgb(0.50, 0.95, 0.55), // bright green
    Color.rgb(1.00, 0.92, 0.45), // bright yellow
    Color.rgb(0.50, 0.70, 1.00), // bright blue
    Color.rgb(0.95, 0.55, 1.00), // bright magenta
    Color.rgb(0.50, 0.95, 0.95), // bright cyan
    Color.rgb(1.00, 1.00, 1.00), // bright white
};

const term_default_fg = Color.rgb(0.85, 0.88, 0.90);
const term_default_bg = Color.rgb(0.08, 0.09, 0.10);

fn termColor(idx: term_mod.ColorIdx, is_fg: bool) Color {
    if (idx == .default) return if (is_fg) term_default_fg else term_default_bg;
    const i: u8 = @intFromEnum(idx);
    if (i < term_palette.len) return term_palette[i];
    return if (is_fg) term_default_fg else term_default_bg;
}

fn drawTerminalContent(
    r: *Renderer,
    vp: Viewport,
    b: *const bubble_mod.Bubble,
    sess: *const term_mod.Session,
    is_focused: bool,
) void {
    const content = b.contentBounds();
    if (content.w < 1 or content.h < 1) return;
    const cw = Font.charW();
    const ch = Font.charH();
    const cols = sess.screen.cols;
    const rows = sess.screen.rows;

    // Pass 1: cell backgrounds + selection + cursor block (untextured).
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const cell = sess.screen.viewCell(row, col);
            const x0 = content.x + @as(f32, @floatFromInt(col)) * cw;
            const y0 = content.y + @as(f32, @floatFromInt(row)) * ch;
            if (x0 >= content.right() or y0 >= content.bottom()) continue;

            var bg = termColor(cell.bg, false);
            if (cell.attr.reverse) bg = termColor(cell.fg, true);

            const selected = sess.selection.contains(row, col);
            const on_cursor = is_focused and sess.screen.cursorOnView(row, col);

            if (selected) {
                fillWorldRect(vp, .{ .x = x0, .y = y0, .w = cw, .h = ch }, term_selection_bg);
            } else if (cell.bg != .default or cell.attr.reverse) {
                fillWorldRect(vp, .{ .x = x0, .y = y0, .w = cw, .h = ch }, bg);
            }
            if (on_cursor) {
                fillWorldRect(vp, .{ .x = x0, .y = y0, .w = cw, .h = ch }, caret_block);
            }
        }
    }

    // Pass 2: glyphs in one textured batch.
    sgl.loadPipeline(r.pip_blend);
    sgl.enableTexture();
    sgl.texture(r.atlas_view, r.atlas_smp);
    sgl.beginQuads();
    row = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const cell = sess.screen.viewCell(row, col);
            const x0 = content.x + @as(f32, @floatFromInt(col)) * cw;
            const y0 = content.y + @as(f32, @floatFromInt(row)) * ch;
            if (x0 >= content.right() or y0 >= content.bottom()) continue;

            var fg = termColor(cell.fg, true);
            var bg = termColor(cell.bg, false);
            if (cell.attr.reverse) {
                const tmp = fg;
                fg = bg;
                bg = tmp;
            }
            if (cell.attr.dim) {
                fg = Color.rgb(fg.r * 0.65, fg.g * 0.65, fg.b * 0.65);
            }
            if (cell.attr.bold and cell.fg != .default) {
                fg = Color.rgb(@min(fg.r * 1.1, 1), @min(fg.g * 1.1, 1), @min(fg.b * 1.1, 1));
            }

            const on_cursor = is_focused and sess.screen.cursorOnView(row, col);
            const ch_byte: u8 = if (cell.ch >= 32 and cell.ch < 127) cell.ch else if (cell.ch != 0) '?' else ' ';
            if (ch_byte != ' ' or on_cursor) {
                const glyph_col = if (on_cursor) caret_glyph else fg;
                emitGlyph(vp, x0, y0, if (ch_byte == ' ' and on_cursor) ' ' else ch_byte, glyph_col);
            }
        }
    }
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

/// An import block drawn as a wrapped grid of name pills, plus a `+` control.
///
/// Walks the same `pills.Walker` sequence the height and the hit-test walk. Nothing about the
/// layout is stored, so the three cannot drift — the walker is the single source.
///
/// Returns false when there is nothing to draw, so the caller can fall back to code rather
/// than leaving an empty box.
fn drawImportPills(
    r: *Renderer,
    vp: Viewport,
    source: []const u8,
    content: BoundingBox,
    lang: detect.Language,
) bool {
    if (content.w < 1 or content.h < 1) return false;
    pills.parse(r.allocator, source, lang, &r.import_pills) catch return false;
    if (!pills.hasPills(r.import_pills.items)) return false;

    var w = pills.Walker.init(content);
    for (r.import_pills.items) |imp| {
        const box = w.next(imp.name.len);
        if (box.bottom() > content.bottom() + 0.5) return true; // ran past the bubble; drop the rest
        drawPill(r, vp, box, imp.name, pill_fill);
    }
    const p = w.plus();
    if (p.bottom() <= content.bottom() + 0.5) drawPill(r, vp, p, "+", pill_plus_fill);
    return true;
}

fn drawPill(r: *Renderer, vp: Viewport, box: BoundingBox, label: []const u8, fill: Color) void {
    fillWorldRoundRect(vp, box, pill_corner_r, fill);
    // Centre the label: pills are sized from it, but `+` sits in a square.
    const text_w = @as(f32, @floatFromInt(label.len)) * Font.charW();
    drawTextLineClipped(r, vp, label, .{
        .x = box.x + @max(pills.pill_pad_x, (box.w - text_w) * 0.5),
        .y = box.y + pills.pill_pad_y,
        .w = box.w - pills.pill_pad_x,
        .h = box.h - pills.pill_pad_y * 2,
    }, pill_text, null, 0, null, null);
}

fn bubbleHasErrors(diags: *const DiagStore, b: *const bubble_mod.Bubble) bool {
    const f = b.fragment() orelse return false;
    return diags.countInRange(f.doc, f.start_line, f.end_line) > 0;
}

/// Extra panel under the bubble listing fragment-local diagnostics.
fn drawErrorBox(
    r: *Renderer,
    vp: Viewport,
    diags: *const DiagStore,
    b: *const bubble_mod.Bubble,
) void {
    const f = b.fragment() orelse return;
    const all = diags.get(f.doc);
    if (all.len == 0) return;

    // Collect matching lines (capped).
    var msgs: [error_box_max_lines]struct { line: u32, msg: []const u8 } = undefined;
    var n: usize = 0;
    var total: usize = 0;
    for (all) |d| {
        if (d.line < f.start_line or d.line >= f.end_line) continue;
        total += 1;
        if (n < error_box_max_lines) {
            msgs[n] = .{ .line = d.line, .msg = d.message };
            n += 1;
        }
    }
    if (n == 0) return;

    const ch = Font.charH();
    const line_h = ch + 2;
    const header_h = line_h;
    const box_h = error_box_pad * 2 + header_h + @as(f32, @floatFromInt(n)) * line_h +
        if (total > n) line_h else 0;

    const box = BoundingBox{
        .x = b.bounds.x,
        .y = b.bounds.bottom() + error_box_gap,
        .w = b.bounds.w,
        .h = box_h,
    };

    // Soft backdrop so errors read clearly over the grid.
    sgl.loadPipeline(r.pip_blend);
    fillWorldRect(vp, box, error_box_fill);
    strokeWorldRect(vp, box, error_box_border, 1.5);

    var y = box.y + error_box_pad;
    const text_x = box.x + error_box_pad;
    const text_w = @max(0, box.w - error_box_pad * 2);

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "{d} issue{s}",
        .{ total, if (total == 1) "" else "s" },
    ) catch "issues";
    drawTextLineClipped(r, vp, header, .{
        .x = text_x,
        .y = y,
        .w = text_w,
        .h = line_h,
    }, error_box_border, null, 0, null, null);
    y += header_h;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var line_buf: [512]u8 = undefined;
        // 1-based line numbers for display.
        const line = std.fmt.bufPrint(
            &line_buf,
            "L{d}: {s}",
            .{ msgs[i].line + 1, msgs[i].msg },
        ) catch msgs[i].msg;
        drawTextLineClipped(r, vp, line, .{
            .x = text_x,
            .y = y,
            .w = text_w,
            .h = line_h,
        }, error_box_text, null, 0, null, null);
        y += line_h;
    }

    if (total > n) {
        var more_buf: [48]u8 = undefined;
        const more = std.fmt.bufPrint(
            &more_buf,
            "... and {d} more",
            .{total - n},
        ) catch "...";
        drawTextLineClipped(r, vp, more, .{
            .x = text_x,
            .y = y,
            .w = text_w,
            .h = line_h,
        }, error_box_text, null, 0, null, null);
    }
}

fn drawCodeContent(
    r: *Renderer,
    vp: Viewport,
    store: *const DocumentStore,
    brackets: *const BracketStore,
    source: []const u8,
    content: BoundingBox,
    lang: detect.Language,
    is_note: bool,
    b: *const bubble_mod.Bubble,
    link_hl: ?LinkHighlight,
    is_focused: bool,
) void {
    if (content.w < 1 or content.h < 1) return;

    const max_cols = text_mod.maxColsForWidth(content.w);
    r.reflow_lines.clearRetainingCapacity();
    _ = text_mod.reflow(r.allocator, source, max_cols, &r.reflow_lines) catch return;

    const ch = Font.charH();
    const cw = Font.charW();
    var y = content.y;
    var last_logical: u32 = std.math.maxInt(u32);

    // Map absolute call line → local line within this fragment (if any).
    var local_call_line: ?u32 = null;
    var name_cols: ?struct { u32, u32 } = null;
    var highlight_callee_sig = false;
    if (link_hl) |lh| {
        if (b.fragment()) |f| {
            if (lh.from_bubble == b.id) {
                if (lh.call_line) |abs| {
                    if (abs >= f.start_line and abs < f.end_line) {
                        local_call_line = abs - f.start_line;
                        if (lh.call_col_start != null and lh.call_col_end != null) {
                            name_cols = .{ lh.call_col_start.?, lh.call_col_end.? };
                        }
                    }
                }
            }
            if (lh.to_bubble == b.id) {
                highlight_callee_sig = true;
            }
        }
    }

    // Bracket pair index (full document) + caret active pair.
    var bidx: ?*const brackets_mod.BracketIndex = null;
    var frag_start_line: u32 = 0;
    var doc_for_lines: ?*const doc_mod.Document = null;
    var active_open: ?u32 = null;
    var active_close: ?u32 = null;
    if (!is_note) {
        if (b.fragment()) |f| {
            frag_start_line = f.start_line;
            doc_for_lines = store.getConst(f.doc);
            bidx = brackets.get(f.doc);
            if (is_focused) {
                if (bidx) |bi| {
                    if (doc_for_lines) |d| {
                        const abs_line = frag_start_line + b.caret.line;
                        const abs_off = d.offsetAt(abs_line, b.caret.col);
                        if (bi.pairNear(abs_off)) |pair| {
                            if (pair.open != std.math.maxInt(u32)) active_open = pair.open;
                            if (pair.close != std.math.maxInt(u32)) active_close = pair.close;
                        }
                    }
                }
            }
        }
    }

    // Soft background under active matching brackets (before text).
    if (active_open != null or active_close != null) {
        if (doc_for_lines) |d| {
            paintActiveBracketBg(vp, content, d, frag_start_line, source, active_open, active_close, cw, ch);
        }
    }

    // Text selection wash (logical lines; good enough without wrap-aware ranges).
    if (is_focused and b.selection.active and !b.selection.isEmpty()) {
        paintSelection(vp, content, b.selection, cw, ch);
    }

    for (r.reflow_lines.items) |line| {
        if (y + ch > content.bottom() + 0.5) break;

        // Link-hover columns within this display segment (absolute → segment-local).
        var glow_cols: ?struct { u32, u32 } = null; // [start, end) in segment bytes
        if (local_call_line != null and line.logical_line == local_call_line.? and !line.wrap_continuation) {
            if (name_cols) |cols| {
                const seg0 = line.col_offset;
                const seg1 = line.col_offset + @as(u32, @intCast(line.bytes.len));
                const a = @max(cols[0], seg0);
                const b2 = @min(cols[1], seg1);
                if (b2 > a) glow_cols = .{ a - seg0, b2 - seg0 };
            } else {
                glow_cols = .{ 0, @intCast(line.bytes.len) };
            }
        }
        // Callee signature: bloom the whole first line (per-token colors).
        if (highlight_callee_sig and line.logical_line == 0 and !line.wrap_continuation) {
            glow_cols = .{ 0, @intCast(line.bytes.len) };
        }

        if (line.logical_line != last_logical) {
            last_logical = line.logical_line;
            fillLogicalLine(r, source, line.logical_line);
            r.highlight_spans.clearRetainingCapacity();
            if (!is_note) {
                highlight.highlightLine(lang, r.logical_line_buf.items, &r.highlight_spans, r.allocator) catch {};
            }
        }

        const line_box = BoundingBox{
            .x = content.x,
            .y = y,
            .w = content.w,
            .h = ch,
        };
        if (is_note) {
            drawTextLineClipped(r, vp, line.bytes, line_box, text_note, null, 0, null, null);
        } else {
            var bctx: ?BracketDrawCtx = null;
            if (bidx) |bi| {
                var line_abs: u32 = 0;
                if (doc_for_lines) |d| {
                    const abs_line = frag_start_line + line.logical_line;
                    if (abs_line < d.lineCount()) {
                        line_abs = d.lineStartOffset(abs_line);
                    }
                }
                bctx = .{
                    .index = bi,
                    .line_abs_start = line_abs,
                    .active_open = active_open,
                    .active_close = active_close,
                };
            }
            // GlowRays-style: bloom each glyph in its syntax color, then crisp text on top.
            if (glow_cols) |gc| {
                drawTextGlyphBloom(
                    r,
                    vp,
                    line.bytes,
                    line_box,
                    r.highlight_spans.items,
                    line.col_offset,
                    gc[0],
                    gc[1],
                );
            }
            drawTextLineClipped(r, vp, line.bytes, line_box, text_body, r.highlight_spans.items, line.col_offset, bctx, if (glow_cols) |gc|
                GlyphRangeForce{ .col0 = gc[0], .col1 = gc[1], .brighten = true }
            else
                null);
        }
        y += ch;
    }
}

/// Force / brighten glyphs in columns [col0, col1) within a display segment.
const GlyphRangeForce = struct {
    col0: u32,
    col1: u32,
    /// When true, boost syntax color (GlowRays core); else replace with fixed color.
    brighten: bool = false,
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
};

/// Soften a syntax color slightly toward white for the glowing core.
fn neonBrighten(c: Color) Color {
    // Hot core like GlowRays: push toward white without washing out the hue.
    return .{
        .r = @min(1.0, c.r * 1.18 + 0.14),
        .g = @min(1.0, c.g * 1.18 + 0.14),
        .b = @min(1.0, c.b * 1.15 + 0.12),
        .a = 1.0,
    };
}

fn syntaxColorAt(spans: []const highlight.Span, span_base: u32, col: u32, default: Color) Color {
    const kind = highlight.kindAt(spans, span_base + col);
    const rgb = highlight.colorRgb(kind);
    _ = default;
    return Color.rgb(rgb.r, rgb.g, rgb.b);
}

/// GlowRays-style text bloom under crisp glyphs.
///
/// Three passes for a smooth, accurate neon look:
/// 1) Soft elliptical discs (smooth atmospheric haze, no hard edges)
/// 2) Multi-direction offset glyph samples (shape-following soft blur)
/// 3) Slightly enlarged soft glyph copies (tight letter bloom)
fn drawTextGlyphBloom(
    r: *Renderer,
    vp: Viewport,
    bytes: []const u8,
    box: BoundingBox,
    spans: []const highlight.Span,
    span_base: u32,
    col0: u32,
    col1: u32,
) void {
    if (bytes.len == 0 or box.w < 1 or col1 <= col0) return;

    const cw = Font.charW();
    const ch = Font.charH();

    // --- Pass 1: smooth radial haze (untextured discs) ---
    sgl.loadPipeline(r.pip_blend);
    var x = box.x;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (x + cw > box.x + box.w + 0.5) break;
        const c = bytes[i];
        if (c == '\t') {
            x += cw * 4;
            continue;
        }
        if (c < 32) {
            x += cw;
            continue;
        }
        const col: u32 = @intCast(i);
        if (col >= col0 and col < col1 and c > ' ') {
            const base = syntaxColorAt(spans, span_base, col, text_body);
            const cx = x + cw * 0.5;
            const cy = box.y + ch * 0.5;
            // Slightly wider than tall — matches typical glyph mass.
            fillSoftEllipseWorld(vp, cx, cy, cw * 1.55, ch * 1.25, base, 0.20);
        }
        x += cw;
    }

    // --- Pass 2+3: textured soft glyph samples ---
    sgl.enableTexture();
    sgl.texture(r.atlas_view, r.atlas_smp);
    sgl.beginQuads();

    // Multi-direction offsets approximate a gaussian blur of the letter shape.
    // Radii in fractions of the cell size.
    const radii = [_]f32{ 0.22, 0.40, 0.62, 0.88, 1.18 };
    const rad_alpha = [_]f32{ 0.14, 0.11, 0.08, 0.055, 0.035 };
    const n_dir: u32 = 12;
    const two_pi: f32 = std.math.pi * 2.0;

    var ri: usize = 0;
    while (ri < radii.len) : (ri += 1) {
        const rad = radii[ri];
        const a = rad_alpha[ri];
        x = box.x;
        i = 0;
        while (i < bytes.len) : (i += 1) {
            if (x + cw > box.x + box.w + 0.5) break;
            const c = bytes[i];
            if (c == '\t') {
                x += cw * 4;
                continue;
            }
            if (c < 32) {
                x += cw;
                continue;
            }
            const col: u32 = @intCast(i);
            if (col >= col0 and col < col1 and c > ' ') {
                const base = syntaxColorAt(spans, span_base, col, text_body);
                const col_c = Color.rgba(base.r, base.g, base.b, a);
                var d: u32 = 0;
                while (d < n_dir) : (d += 1) {
                    const ang = two_pi * @as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(n_dir));
                    // Add half-step rotation per ring so samples interleave (smoother).
                    const ang2 = ang + (if (ri % 2 == 1) two_pi / @as(f32, @floatFromInt(n_dir * 2)) else 0);
                    const ox = @cos(ang2) * rad * cw;
                    const oy = @sin(ang2) * rad * ch * 0.85;
                    emitGlyphScaled(vp, x + ox, box.y + oy, c, col_c, 1.04);
                }
            }
            x += cw;
        }
    }

    // Tight letter bloom: a few gentle enlargements (low alpha so edges stay soft).
    const tight_scales = [_]f32{ 1.55, 1.32, 1.16 };
    const tight_alpha = [_]f32{ 0.10, 0.14, 0.18 };
    var si: usize = 0;
    while (si < tight_scales.len) : (si += 1) {
        const scale = tight_scales[si];
        const a = tight_alpha[si];
        x = box.x;
        i = 0;
        while (i < bytes.len) : (i += 1) {
            if (x + cw > box.x + box.w + 0.5) break;
            const c = bytes[i];
            if (c == '\t') {
                x += cw * 4;
                continue;
            }
            if (c < 32) {
                x += cw;
                continue;
            }
            const col: u32 = @intCast(i);
            if (col >= col0 and col < col1 and c > ' ') {
                const base = syntaxColorAt(spans, span_base, col, text_body);
                emitGlyphScaled(vp, x, box.y, c, Color.rgba(base.r, base.g, base.b, a), scale);
            }
            x += cw;
        }
    }

    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

/// Soft filled ellipse via concentric triangle-fans (smooth radial falloff).
fn fillSoftEllipseWorld(
    vp: Viewport,
    cx: f32,
    cy: f32,
    rx: f32,
    ry: f32,
    tint: Color,
    peak_alpha: f32,
) void {
    const sc = vp.worldToScreen(.{ .x = cx, .y = cy });
    const s = vp.pixelScale();
    const rx_px = rx * s;
    const ry_px = ry * s;
    if (rx_px < 1 or ry_px < 1) return;

    const rings: u32 = 8;
    const segs: u32 = 16;
    var ring: i32 = @intCast(rings);
    while (ring >= 1) : (ring -= 1) {
        const t = @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));
        // Smooth cubic falloff — outer haze very soft, core a bit stronger.
        const fall = 1.0 - t;
        const a = peak_alpha * fall * fall * fall;
        const rxi = rx_px * t;
        const ryi = ry_px * t;
        const col = Color.rgba(tint.r, tint.g, tint.b, a);
        sgl.beginTriangles();
        var s_i: u32 = 0;
        while (s_i < segs) : (s_i += 1) {
            const a0 = std.math.pi * 2.0 * @as(f32, @floatFromInt(s_i)) / @as(f32, @floatFromInt(segs));
            const a1 = std.math.pi * 2.0 * @as(f32, @floatFromInt(s_i + 1)) / @as(f32, @floatFromInt(segs));
            sgl.v2fC4f(sc.x, sc.y, col.r, col.g, col.b, col.a);
            sgl.v2fC4f(sc.x + @cos(a0) * rxi, sc.y + @sin(a0) * ryi, col.r, col.g, col.b, col.a);
            sgl.v2fC4f(sc.x + @cos(a1) * rxi, sc.y + @sin(a1) * ryi, col.r, col.g, col.b, col.a);
        }
        sgl.end();
    }
}

fn paintSelection(
    vp: Viewport,
    content: BoundingBox,
    sel: bubble_mod.Selection,
    cw: f32,
    ch: f32,
) void {
    const n = sel.normalized();
    var line = n.sl;
    while (line <= n.el) : (line += 1) {
        const y = content.y + @as(f32, @floatFromInt(line)) * ch;
        if (y + ch < content.y or y > content.bottom()) continue;
        const start_col: u32 = if (line == n.sl) n.sc else 0;
        // Full line remainder unless last selected line.
        const end_col: u32 = if (line == n.el) n.ec else 4096;
        if (end_col <= start_col and line == n.el and line == n.sl) continue;
        const x0 = content.x + @as(f32, @floatFromInt(start_col)) * cw;
        const x1 = if (line == n.el)
            content.x + @as(f32, @floatFromInt(end_col)) * cw
        else
            content.x + content.w;
        const w = @max(0, @min(x1, content.right()) - @max(x0, content.x));
        if (w < 1) continue;
        fillWorldRect(vp, .{
            .x = @max(x0, content.x),
            .y = y,
            .w = w,
            .h = ch,
        }, selection_bg);
    }
}

const active_bracket_bg = Color.rgba(1.0, 1.0, 1.0, 0.14);

/// Highlight cells of active open/close brackets inside this bubble's content area.
/// Note: uses unwrapped line columns (good enough when caret pair is on-screen).
fn paintActiveBracketBg(
    vp: Viewport,
    content: BoundingBox,
    doc: *const doc_mod.Document,
    frag_start_line: u32,
    frag_source: []const u8,
    active_open: ?u32,
    active_close: ?u32,
    cw: f32,
    ch: f32,
) void {
    _ = frag_source;
    if (active_open) |o| paintOneActiveBracket(vp, content, doc, frag_start_line, o, cw, ch);
    if (active_close) |c| paintOneActiveBracket(vp, content, doc, frag_start_line, c, cw, ch);
}

fn paintOneActiveBracket(
    vp: Viewport,
    content: BoundingBox,
    doc: *const doc_mod.Document,
    frag_start_line: u32,
    off: u32,
    cw: f32,
    ch: f32,
) void {
    const lc = doc.lineColAt(off);
    if (lc.line < frag_start_line) return;
    const local_line = lc.line - frag_start_line;
    const y = content.y + @as(f32, @floatFromInt(local_line)) * ch;
    if (y + ch < content.y or y > content.bottom()) return;
    const x = content.x + @as(f32, @floatFromInt(lc.col)) * cw;
    if (x + cw < content.x or x > content.right()) return;
    fillWorldRect(vp, .{ .x = x, .y = y, .w = cw, .h = ch }, active_bracket_bg);
}

fn fillLogicalLine(r: *Renderer, source: []const u8, logical_idx: u32) void {
    r.logical_line_buf.clearRetainingCapacity();
    var idx: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        const at_end = i == source.len;
        const at_nl = !at_end and source[i] == '\n';
        if (!at_end and !at_nl) continue;
        if (idx == logical_idx) {
            r.logical_line_buf.appendSlice(r.allocator, source[start..i]) catch {};
            return;
        }
        if (at_end) return;
        start = i + 1;
        idx += 1;
    }
}

fn drawCaret(r: *Renderer, vp: Viewport, store: *const DocumentStore, b: *const bubble_mod.Bubble) void {
    // Steady caret — no blink. Position must match drawCodeContent reflow rows
    // (logical line × charH is wrong once any line soft-wraps).
    const content = b.contentBounds();
    if (content.w < 1 or content.h < 1) return;

    const source = b.displayText(store);
    const line: u32 = b.caret.line;
    var col: u32 = b.caret.col;

    // Glyph under caret from the same buffer the user edits (local or note/doc).
    var under: u8 = ' ';
    const row_bytes = bubble_mod.lineSliceOf(source, line);
    if (col > row_bytes.len) col = @intCast(row_bytes.len);
    if (col < row_bytes.len) {
        const ch_byte = row_bytes[col];
        if (ch_byte >= 32 and ch_byte < 127) under = ch_byte;
    }

    const max_cols = text_mod.maxColsForWidth(content.w);
    r.reflow_lines.clearRetainingCapacity();
    _ = text_mod.reflow(r.allocator, source, max_cols, &r.reflow_lines) catch {
        // Fallback: unwrapped (pre-reflow) layout.
        const ch = Font.charH();
        const cw = Font.charW();
        const x = content.x + @as(f32, @floatFromInt(col)) * cw;
        const y = content.y + @as(f32, @floatFromInt(line)) * ch;
        paintCaretBlock(r, vp, x, y, cw, ch, under);
        return;
    };

    // Find the display row that contains (logical_line, col).
    var disp_row: ?usize = null;
    var col_in_row: u32 = col;
    for (r.reflow_lines.items, 0..) |dl, i| {
        if (dl.logical_line != line) continue;
        const row_len: u32 = @intCast(dl.bytes.len);
        const start = dl.col_offset;
        const end = start + row_len;
        // Caret may sit past end of last wrap piece (EOL).
        if (col >= start and (col < end or (col == end and (i + 1 >= r.reflow_lines.items.len or r.reflow_lines.items[i + 1].logical_line != line)))) {
            disp_row = i;
            col_in_row = col - start;
            break;
        }
        // Prefer last piece of this logical line if col is past all wraps.
        if (col >= end) {
            disp_row = i;
            col_in_row = row_len;
        }
    }
    if (disp_row == null and r.reflow_lines.items.len > 0) {
        // Logical line beyond reflow (should not happen after clamp) → last row.
        disp_row = r.reflow_lines.items.len - 1;
        col_in_row = @intCast(r.reflow_lines.items[disp_row.?].bytes.len);
    }
    const row_i = disp_row orelse return;

    const ch = Font.charH();
    const cw = Font.charW();
    var x = content.x + @as(f32, @floatFromInt(col_in_row)) * cw;
    var y = content.y + @as(f32, @floatFromInt(row_i)) * ch;
    // Fully inside content — never paint caret on the bubble chrome / outside the body.
    if (y + ch > content.bottom() + 0.5) {
        // Clamp to last visible row when the bubble is shorter than reflow (should be rare).
        const max_rows: f32 = @floor(content.h / ch);
        if (max_rows < 1) return;
        y = content.y + (max_rows - 1.0) * ch;
    }
    if (y < content.y) return;
    if (x < content.x) x = content.x;
    if (x + cw > content.right() + 0.5) {
        x = @max(content.x, content.right() - cw);
    }

    paintCaretBlock(r, vp, x, y, cw, ch, under);
}

fn paintCaretBlock(r: *Renderer, vp: Viewport, x: f32, y: f32, cw: f32, ch: f32, under: u8) void {
    fillWorldRect(vp, .{ .x = x, .y = y, .w = cw, .h = ch }, caret_block);
    if (under == ' ') return;
    sgl.loadPipeline(r.pip_blend);
    sgl.enableTexture();
    sgl.texture(r.atlas_view, r.atlas_smp);
    sgl.beginQuads();
    emitGlyph(vp, x, y, under, caret_glyph);
    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

/// Draw a monospaced line. If `spans` is non-null, color by highlight kinds.
/// `span_base` is the byte offset of `bytes` within the full logical line.
/// `bracket_ctx` overrides colors for nested bracket pairs (BPC2-style).
/// `force_range` forces a solid color for a column range (e.g. link name pill).
fn drawTextLineClipped(
    r: *Renderer,
    vp: Viewport,
    bytes: []const u8,
    box: BoundingBox,
    default_color: Color,
    spans: ?[]const highlight.Span,
    span_base: u32,
    bracket_ctx: ?BracketDrawCtx,
    force_range: ?GlyphRangeForce,
) void {
    if (bytes.len == 0 or box.w < 1) return;

    sgl.loadPipeline(r.pip_blend);
    sgl.enableTexture();
    sgl.texture(r.atlas_view, r.atlas_smp);
    sgl.beginQuads();

    const cw = Font.charW();
    var x = box.x;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (x + cw > box.x + box.w + 0.5) break;
        const c = bytes[i];
        if (c >= 0x80) {
            if (c >= 0xC0) {
                emitGlyph(vp, x, box.y, '?', default_color);
                x += cw;
            }
            continue;
        }
        if (c == '\t') {
            x += cw * 4;
            continue;
        }
        if (c == '\r') continue;

        var color = default_color;
        if (spans) |sp| {
            const kind = highlight.kindAt(sp, span_base + @as(u32, @intCast(i)));
            const rgb = highlight.colorRgb(kind);
            color = Color.rgb(rgb.r, rgb.g, rgb.b);
        }
        // Rainbow brackets override punctuation coloring.
        if (bracket_ctx) |bc| {
            const abs_off = bc.line_abs_start + span_base + @as(u32, @intCast(i));
            if (bc.index.entryAt(abs_off)) |ent| {
                if (ent.unmatched and !ent.is_open) {
                    color = Color.rgb(brackets_mod.unmatched_color.r, brackets_mod.unmatched_color.g, brackets_mod.unmatched_color.b);
                } else {
                    const rgb = brackets_mod.rgbForDepth(ent.depth);
                    color = Color.rgb(rgb.r, rgb.g, rgb.b);
                }
                const is_active = (bc.active_open != null and bc.active_open.? == abs_off) or
                    (bc.active_close != null and bc.active_close.? == abs_off);
                if (is_active) {
                    const br = brackets_mod.brighten(color.r, color.g, color.b);
                    color = Color.rgb(br.r, br.g, br.b);
                }
            }
        }
        // Link glow: brighten core glyphs (bloom already drawn underneath).
        if (force_range) |fr| {
            const col: u32 = @intCast(i);
            if (col >= fr.col0 and col < fr.col1) {
                if (fr.brighten) {
                    color = neonBrighten(color);
                } else {
                    color = fr.color;
                }
            }
        }
        emitGlyph(vp, x, box.y, c, color);
        x += cw;
    }

    sgl.end();
    sgl.disableTexture();
    sgl.loadDefaultPipeline();
}

fn emitGlyph(vp: Viewport, world_x: f32, world_y: f32, codepoint: u8, color: Color) void {
    emitGlyphScaled(vp, world_x, world_y, codepoint, color, 1.0);
}

/// Draw a glyph optionally scaled about the cell center (for soft neon bloom layers).
fn emitGlyphScaled(vp: Viewport, world_x: f32, world_y: f32, codepoint: u8, color: Color, scale: f32) void {
    const uv = Font.glyphUv(codepoint);
    const cw = Font.charW();
    const ch = Font.charH();
    const cx = world_x + cw * 0.5;
    const cy = world_y + ch * 0.5;
    const sc = vp.worldToScreen(.{ .x = cx, .y = cy });
    const sw = cw * scale * vp.pixelScale();
    const sh = ch * scale * vp.pixelScale();
    // Soft layers: no pixel snap (avoids shimmering halos). Core (scale≈1) snaps.
    const snap = scale < 1.05;
    const x0 = if (snap) @floor(sc.x - sw * 0.5 + 0.5) else sc.x - sw * 0.5;
    const y0 = if (snap) @floor(sc.y - sh * 0.5 + 0.5) else sc.y - sh * 0.5;
    const w = if (snap) @max(@as(f32, 1), @round(sw)) else @max(@as(f32, 1), sw);
    const h = if (snap) @max(@as(f32, 1), @round(sh)) else @max(@as(f32, 1), sh);
    const x1 = x0 + w;
    const y1 = y0 + h;
    sgl.v2fT2fC4f(x0, y0, uv.u_min, uv.v_min, color.r, color.g, color.b, color.a);
    sgl.v2fT2fC4f(x1, y0, uv.u_max, uv.v_min, color.r, color.g, color.b, color.a);
    sgl.v2fT2fC4f(x1, y1, uv.u_max, uv.v_max, color.r, color.g, color.b, color.a);
    sgl.v2fT2fC4f(x0, y1, uv.u_min, uv.v_max, color.r, color.g, color.b, color.a);
}

fn fillWorldRect(vp: Viewport, box: BoundingBox, c: Color) void {
    const tl = vp.worldToScreen(.{ .x = box.x, .y = box.y });
    const br = vp.worldToScreen(.{ .x = box.right(), .y = box.bottom() });
    fillScreenRect(tl.x, tl.y, br.x, br.y, c);
}

fn strokeWorldRect(vp: Viewport, box: BoundingBox, c: Color, thickness_px: f32) void {
    const tl = vp.worldToScreen(.{ .x = box.x, .y = box.y });
    const br = vp.worldToScreen(.{ .x = box.right(), .y = box.bottom() });
    strokeScreenRect(tl.x, tl.y, br.x, br.y, c, thickness_px);
}

fn fillWorldRoundRect(vp: Viewport, box: BoundingBox, r_world: f32, c: Color) void {
    const tl = vp.worldToScreen(.{ .x = box.x, .y = box.y });
    const br = vp.worldToScreen(.{ .x = box.right(), .y = box.bottom() });
    const r_px = r_world * vp.pixelScale();
    fillScreenRoundRect(tl.x, tl.y, br.x, br.y, r_px, c);
}

/// Rounded top corners only (title bar that matches the bubble chrome).
fn fillWorldRoundTopRect(vp: Viewport, box: BoundingBox, r_world: f32, c: Color) void {
    const tl = vp.worldToScreen(.{ .x = box.x, .y = box.y });
    const br = vp.worldToScreen(.{ .x = box.right(), .y = box.bottom() });
    const r_px = r_world * vp.pixelScale();
    fillScreenRoundTopRect(tl.x, tl.y, br.x, br.y, r_px, c);
}

fn strokeWorldRoundRect(vp: Viewport, box: BoundingBox, r_world: f32, c: Color, thickness_px: f32) void {
    const tl = vp.worldToScreen(.{ .x = box.x, .y = box.y });
    const br = vp.worldToScreen(.{ .x = box.right(), .y = box.bottom() });
    const r_px = r_world * vp.pixelScale();
    strokeScreenRoundRect(tl.x, tl.y, br.x, br.y, r_px, c, thickness_px);
}

fn fillScreenRect(x0: f32, y0: f32, x1: f32, y1: f32, c: Color) void {
    sgl.beginQuads();
    sgl.v2fC4f(x0, y0, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(x1, y0, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(x1, y1, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(x0, y1, c.r, c.g, c.b, c.a);
    sgl.end();
}

/// Axis-aligned border as four thin quads (crisp at any zoom).
fn strokeScreenRect(x0: f32, y0: f32, x1: f32, y1: f32, c: Color, t: f32) void {
    fillScreenRect(x0, y0, x1, y0 + t, c);
    fillScreenRect(x0, y1 - t, x1, y1, c);
    fillScreenRect(x0, y0, x0 + t, y1, c);
    fillScreenRect(x1 - t, y0, x1, y1, c);
}

fn clampCornerRadius(x0: f32, y0: f32, x1: f32, y1: f32, r: f32) f32 {
    const w = @abs(x1 - x0);
    const h = @abs(y1 - y0);
    const half = @min(w, h) * 0.5;
    if (half < 1.0) return 0;
    return std.math.clamp(r, 0, half);
}

/// Filled axis-aligned rounded rect in screen space (y-down).
fn fillScreenRoundRect(x0: f32, y0: f32, x1: f32, y1: f32, r_in: f32, c: Color) void {
    const r = clampCornerRadius(x0, y0, x1, y1, r_in);
    if (r < 0.5) {
        fillScreenRect(x0, y0, x1, y1, c);
        return;
    }
    // Center + 4 side boxes.
    fillScreenRect(x0 + r, y0, x1 - r, y1, c);
    fillScreenRect(x0, y0 + r, x0 + r, y1 - r, c);
    fillScreenRect(x1 - r, y0 + r, x1, y1 - r, c);
    // Corners: TL, TR, BR, BL (screen y-down: TL is min x,y).
    fillScreenCorner(x0 + r, y0 + r, r, std.math.pi, std.math.pi * 1.5, c); // TL
    fillScreenCorner(x1 - r, y0 + r, r, std.math.pi * 1.5, std.math.pi * 2.0, c); // TR
    fillScreenCorner(x1 - r, y1 - r, r, 0, std.math.pi * 0.5, c); // BR
    fillScreenCorner(x0 + r, y1 - r, r, std.math.pi * 0.5, std.math.pi, c); // BL
}

/// Rounded on the top edge only (title strip).
fn fillScreenRoundTopRect(x0: f32, y0: f32, x1: f32, y1: f32, r_in: f32, c: Color) void {
    const r = clampCornerRadius(x0, y0, x1, y1, r_in);
    if (r < 0.5) {
        fillScreenRect(x0, y0, x1, y1, c);
        return;
    }
    // Body of strip (includes square bottom).
    fillScreenRect(x0 + r, y0, x1 - r, y1, c);
    fillScreenRect(x0, y0 + r, x0 + r, y1, c);
    fillScreenRect(x1 - r, y0 + r, x1, y1, c);
    fillScreenCorner(x0 + r, y0 + r, r, std.math.pi, std.math.pi * 1.5, c); // TL
    fillScreenCorner(x1 - r, y0 + r, r, std.math.pi * 1.5, std.math.pi * 2.0, c); // TR
}

/// Quarter-disk as triangle fan from center (angles in radians, screen y-down).
/// Standard math angles: 0 = +x, π/2 = +y (down on screen).
fn fillScreenCorner(cx: f32, cy: f32, r: f32, a0: f32, a1: f32, c: Color) void {
    const n = corner_segments;
    sgl.beginTriangles();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
        const ang0 = a0 + (a1 - a0) * t0;
        const ang1 = a0 + (a1 - a0) * t1;
        const x_a = cx + @cos(ang0) * r;
        const y_a = cy + @sin(ang0) * r;
        const x_b = cx + @cos(ang1) * r;
        const y_b = cy + @sin(ang1) * r;
        sgl.v2fC4f(cx, cy, c.r, c.g, c.b, c.a);
        sgl.v2fC4f(x_a, y_a, c.r, c.g, c.b, c.a);
        sgl.v2fC4f(x_b, y_b, c.r, c.g, c.b, c.a);
    }
    sgl.end();
}

/// Rounded rect stroke via thick polyline along the perimeter.
fn strokeScreenRoundRect(x0: f32, y0: f32, x1: f32, y1: f32, r_in: f32, c: Color, t: f32) void {
    const r = clampCornerRadius(x0, y0, x1, y1, r_in);
    if (r < 0.5) {
        strokeScreenRect(x0, y0, x1, y1, c, t);
        return;
    }
    const half = t * 0.5;
    // Straight edges (inset by r so corners own the arcs).
    strokeThickSeg(x0 + r, y0, x1 - r, y0, half, c); // top
    strokeThickSeg(x1, y0 + r, x1, y1 - r, half, c); // right
    strokeThickSeg(x1 - r, y1, x0 + r, y1, half, c); // bottom
    strokeThickSeg(x0, y1 - r, x0, y0 + r, half, c); // left
    // Corner arcs.
    strokeScreenCornerArc(x0 + r, y0 + r, r, std.math.pi, std.math.pi * 1.5, half, c);
    strokeScreenCornerArc(x1 - r, y0 + r, r, std.math.pi * 1.5, std.math.pi * 2.0, half, c);
    strokeScreenCornerArc(x1 - r, y1 - r, r, 0, std.math.pi * 0.5, half, c);
    strokeScreenCornerArc(x0 + r, y1 - r, r, std.math.pi * 0.5, std.math.pi, half, c);
}

fn strokeThickSeg(ax: f32, ay: f32, bx: f32, by: f32, half: f32, c: Color) void {
    const dx = bx - ax;
    const dy = by - ay;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.01) return;
    const nx = -dy / len * half;
    const ny = dx / len * half;
    sgl.beginQuads();
    sgl.v2fC4f(ax + nx, ay + ny, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(bx + nx, by + ny, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(bx - nx, by - ny, c.r, c.g, c.b, c.a);
    sgl.v2fC4f(ax - nx, ay - ny, c.r, c.g, c.b, c.a);
    sgl.end();
}

fn strokeScreenCornerArc(cx: f32, cy: f32, r: f32, a0: f32, a1: f32, half: f32, c: Color) void {
    const n = corner_segments;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
        const ang0 = a0 + (a1 - a0) * t0;
        const ang1 = a0 + (a1 - a0) * t1;
        const x_a = cx + @cos(ang0) * r;
        const y_a = cy + @sin(ang0) * r;
        const x_b = cx + @cos(ang1) * r;
        const y_b = cy + @sin(ang1) * r;
        strokeThickSeg(x_a, y_a, x_b, y_b, half, c);
    }
}
