//! JetBrains Mono atlas bake via stb_truetype.
//! Supersampled monospaced grid for sharp code on HiDPI displays.

const std = @import("std");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

const ttf_bytes = @embedFile("fonts/JetBrainsMono-Regular.ttf");

/// Logical glyph height in world units (points). Layout / reflow use this.
pub const logical_px_h: f32 = 15.0;

/// Rasterize this many times larger than logical for clean HiDPI / zoom.
pub const supersample: f32 = 2.0;

pub const first_codepoint: u8 = 32;
pub const last_codepoint: u8 = 127;
pub const glyph_count: u32 = last_codepoint - first_codepoint;

pub const atlas_cols: u32 = 16;
pub const atlas_rows: u32 = 6;

/// Atlas cell size in texture pixels (after bake).
pub var cell_w: u32 = 20;
pub var cell_h: u32 = 36;
pub var atlas_w: u32 = 320;
pub var atlas_h: u32 = 216;

/// Logical monospaced advance / line height (world units). Set by bake.
pub var logical_char_w: f32 = 9;
pub var logical_char_h: f32 = 15;

pub var ascent: f32 = 12;
pub var descent: f32 = -3;
pub var line_gap: f32 = 1;

pub const max_atlas_pixels: usize = 1024 * 1024 * 4;

pub const GlyphUv = struct {
    u_min: f32,
    v_min: f32,
    u_max: f32,
    v_max: f32,
};

pub const Font = struct {
    /// World-unit width for layout / reflow / caret.
    pub fn charW() f32 {
        return logical_char_w;
    }
    pub fn charH() f32 {
        return logical_char_h;
    }

    pub const char_w: f32 = 9;
    pub const char_h: f32 = 15;

    pub fn glyphUv(codepoint: u8) GlyphUv {
        const cp = if (codepoint >= first_codepoint and codepoint < last_codepoint)
            codepoint
        else
            @as(u8, '?');
        const idx: u32 = cp - first_codepoint;
        const col = idx % atlas_cols;
        const row = idx / atlas_cols;
        const aw: f32 = @floatFromInt(atlas_w);
        const ah: f32 = @floatFromInt(atlas_h);
        const cw: f32 = @floatFromInt(cell_w);
        const ch: f32 = @floatFromInt(cell_h);
        // Inset half a texel so NEAREST never bleeds into the neighbor cell.
        const pad_u = 0.5 / aw;
        const pad_v = 0.5 / ah;
        return .{
            .u_min = @as(f32, @floatFromInt(col)) * cw / aw + pad_u,
            .v_min = @as(f32, @floatFromInt(row)) * ch / ah + pad_v,
            .u_max = @as(f32, @floatFromInt(col + 1)) * cw / aw - pad_u,
            .v_max = @as(f32, @floatFromInt(row + 1)) * ch / ah - pad_v,
        };
    }

    pub fn bakeRgba(out: []u8) bool {
        var info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(
            &info,
            @ptrCast(ttf_bytes.ptr),
            c.stbtt_GetFontOffsetForIndex(@ptrCast(ttf_bytes.ptr), 0),
        ) == 0) {
            return false;
        }

        const bake_h = logical_px_h * supersample;
        const scale = c.stbtt_ScaleForPixelHeight(&info, bake_h);

        var i_ascent: c_int = 0;
        var i_descent: c_int = 0;
        var i_line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &i_ascent, &i_descent, &i_line_gap);
        const a = @as(f32, @floatFromInt(i_ascent)) * scale;
        const d = @as(f32, @floatFromInt(i_descent)) * scale;
        const lg = @as(f32, @floatFromInt(i_line_gap)) * scale;
        ascent = a / supersample;
        descent = d / supersample;
        line_gap = lg / supersample;

        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&info, 'M', &adv, &lsb);
        const advance_px = @as(f32, @floatFromInt(adv)) * scale;

        const pad: u32 = 2;
        const measured_w: u32 = @intFromFloat(@ceil(advance_px));
        const measured_h: u32 = @intFromFloat(@ceil(a - d + @max(lg, 0)));
        cell_w = @max(measured_w + pad, 12);
        cell_h = @max(measured_h + pad * 2, 16);
        atlas_w = atlas_cols * cell_w;
        atlas_h = atlas_rows * cell_h;

        // Layout metrics in world units (logical points).
        logical_char_w = advance_px / supersample;
        logical_char_h = @as(f32, @floatFromInt(cell_h)) / supersample;

        const need = atlas_w * atlas_h * 4;
        if (out.len < need) return false;
        @memset(out[0..need], 0);

        const baseline_y: f32 = @as(f32, @floatFromInt(pad)) + a;

        var cp: u8 = first_codepoint;
        while (cp < last_codepoint) : (cp += 1) {
            const idx: u32 = cp - first_codepoint;
            const col = idx % atlas_cols;
            const row = idx / atlas_cols;
            const cell_x: i32 = @intCast(col * cell_w);
            const cell_y: i32 = @intCast(row * cell_h);

            var gw: c_int = 0;
            var gh: c_int = 0;
            var xoff: c_int = 0;
            var yoff: c_int = 0;
            const bmp = c.stbtt_GetCodepointBitmap(
                &info,
                scale,
                scale,
                cp,
                &gw,
                &gh,
                &xoff,
                &yoff,
            );
            if (bmp == null or gw <= 0 or gh <= 0) continue;
            defer c.stbtt_FreeBitmap(bmp, null);

            const x_off: i32 = cell_x + @divTrunc(@as(i32, @intCast(cell_w)) - gw, 2);
            const y_off: i32 = cell_y + @as(i32, @intFromFloat(@floor(baseline_y))) + yoff;

            var gy: c_int = 0;
            while (gy < gh) : (gy += 1) {
                var gx: c_int = 0;
                while (gx < gw) : (gx += 1) {
                    const px = x_off + gx;
                    const py = y_off + gy;
                    if (px < 0 or py < 0) continue;
                    if (px >= @as(i32, @intCast(atlas_w)) or py >= @as(i32, @intCast(atlas_h))) continue;
                    const coverage = bmp[@intCast(gy * gw + gx)];
                    if (coverage == 0) continue;
                    const i = (@as(usize, @intCast(py)) * atlas_w + @as(usize, @intCast(px))) * 4;
                    // Straight alpha (rgb white, a = coverage).
                    out[i + 0] = 255;
                    out[i + 1] = 255;
                    out[i + 2] = 255;
                    out[i + 3] = coverage;
                }
            }
        }
        return true;
    }

    pub fn maxCols(content_width: f32) u32 {
        const cw = charW();
        if (content_width < cw) return 1;
        return @intFromFloat(@floor(content_width / cw));
    }
};

test "bake jetbrains mono atlas" {
    var pixels: [max_atlas_pixels]u8 = undefined;
    try std.testing.expect(Font.bakeRgba(&pixels));
    try std.testing.expect(cell_w >= 12);
    try std.testing.expect(cell_h >= 16);
    try std.testing.expect(logical_char_w > 4);
    const idx: u32 = 'A' - first_codepoint;
    const col = idx % atlas_cols;
    const row = idx / atlas_cols;
    const ox = col * cell_w;
    const oy = row * cell_h;
    var on: usize = 0;
    var y: u32 = 0;
    while (y < cell_h) : (y += 1) {
        var x: u32 = 0;
        while (x < cell_w) : (x += 1) {
            const i = ((oy + y) * atlas_w + (ox + x)) * 4;
            if (pixels[i + 3] > 16) on += 1;
        }
    }
    try std.testing.expect(on > 20);
}

test "glyph UV in unit square" {
    var pixels: [max_atlas_pixels]u8 = undefined;
    _ = Font.bakeRgba(&pixels);
    const uv = Font.glyphUv('A');
    try std.testing.expect(uv.u_min >= 0 and uv.u_max <= 1.0001);
    try std.testing.expect(uv.v_max > uv.v_min);
}

test "maxCols" {
    logical_char_w = 10;
    try std.testing.expectEqual(@as(u32, 1), Font.maxCols(0));
    try std.testing.expectEqual(@as(u32, 10), Font.maxCols(100));
}
