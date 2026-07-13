//! Infinite virtual canvas: pan/zoom viewport over a world of bubbles.
//! Paper: "portal on a large scrollable canvas" (Code Bubbles, §5–6).

const std = @import("std");
const geom = @import("geom.zig");
const bubble_mod = @import("bubble.zig");

pub const Bubble = bubble_mod.Bubble;
pub const BubbleId = bubble_mod.BubbleId;
pub const GroupId = bubble_mod.GroupId;
pub const Connection = bubble_mod.Connection;
pub const WorkingSet = bubble_mod.WorkingSet;
pub const INVALID_GROUP = bubble_mod.INVALID_GROUP;

/// Camera over world space.
/// Screen (framebuffer px) = (world - pan) * zoom * dpi.
pub const Viewport = struct {
    /// World-space point at the top-left of the screen.
    pan: geom.Vec2 = .{},
    /// Uniform scale in logical points (1.0 = 1 world unit per logical point).
    zoom: f32 = 1.0,
    /// Window system DPI scale (framebuffer_px / logical_point). Retina ≈ 2.
    dpi: f32 = 1.0,
    /// Viewport size in **framebuffer** pixels.
    screen_w: f32 = 1280,
    screen_h: f32 = 720,

    /// Combined scale: world → framebuffer pixels.
    pub fn pixelScale(self: Viewport) f32 {
        return self.zoom * self.dpi;
    }

    pub fn worldToScreen(self: Viewport, world: geom.Vec2) geom.Vec2 {
        const s = self.pixelScale();
        return .{
            .x = (world.x - self.pan.x) * s,
            .y = (world.y - self.pan.y) * s,
        };
    }

    pub fn screenToWorld(self: Viewport, screen: geom.Vec2) geom.Vec2 {
        const s = self.pixelScale();
        return .{
            .x = screen.x / s + self.pan.x,
            .y = screen.y / s + self.pan.y,
        };
    }

    /// World-space AABB currently visible on screen.
    pub fn visibleWorldBounds(self: Viewport) geom.BoundingBox {
        const top_left = self.screenToWorld(.{ .x = 0, .y = 0 });
        const bottom_right = self.screenToWorld(.{ .x = self.screen_w, .y = self.screen_h });
        return .{
            .x = top_left.x,
            .y = top_left.y,
            .w = bottom_right.x - top_left.x,
            .h = bottom_right.y - top_left.y,
        };
    }

    /// Zoom about a screen-space pivot so that world point under cursor stays fixed.
    pub fn zoomAt(self: *Viewport, screen_pivot: geom.Vec2, factor: f32, min_z: f32, max_z: f32) void {
        const before = self.screenToWorld(screen_pivot);
        self.zoom = std.math.clamp(self.zoom * factor, min_z, max_z);
        const after = self.screenToWorld(screen_pivot);
        self.pan.x += before.x - after.x;
        self.pan.y += before.y - after.y;
    }

    /// Pan so `world` lands at the screen center (zoom unchanged).
    pub fn centerOn(self: *Viewport, world: geom.Vec2) void {
        const s = self.pixelScale();
        if (s <= 0) return;
        self.pan.x = world.x - (self.screen_w * 0.5) / s;
        self.pan.y = world.y - (self.screen_h * 0.5) / s;
    }

    /// Camera target when focusing a bubble for reading.
    ///
    /// - Prefer `preferred_zoom` for comfortable reading.
    /// - Shrink only to fit **width** (never zoom out just to fit a tall bubble).
    /// - Short bubbles: center the full box.
    /// - Tall bubbles: keep reading zoom and frame around `anchor` (click / caret),
    ///   so you land on the code you clicked instead of a bird’s-eye of the whole body.
    pub fn focusTarget(
        self: Viewport,
        bounds: geom.BoundingBox,
        anchor: geom.Vec2,
        margin_frac: f32,
        preferred_zoom: f32,
        min_z: f32,
        max_z: f32,
    ) struct { pan: geom.Vec2, zoom: f32 } {
        const dpi = @max(self.dpi, 1.0);
        const m = std.math.clamp(margin_frac, 0.05, 0.4);
        const avail_w = @max(self.screen_w * (1.0 - 2.0 * m), 1.0);
        const bw = @max(bounds.w, 8.0);
        const bh = @max(bounds.h, 8.0);

        // Fit width if needed; do not pull back solely for full height.
        const z_fit_w = avail_w / (bw * dpi);
        const zoom = std.math.clamp(@min(preferred_zoom, z_fit_w), min_z, max_z);
        const s = zoom * dpi;
        const view_w = self.screen_w / s;
        const view_h = self.screen_h / s;
        const margin_h = view_h * m;

        // Horizontal: center the bubble.
        const pan_x = bounds.center().x - view_w * 0.5;

        // Vertical: center short bubbles; frame tall ones around the anchor.
        const fits_height = bh + margin_h * 2.0 <= view_h;
        const pan_y: f32 = if (fits_height)
            bounds.center().y - view_h * 0.5
        else blk: {
            // Put anchor in the upper-middle of the screen (title + nearby code).
            const anchor_frac: f32 = 0.32;
            var y = anchor.y - view_h * anchor_frac;
            // Clamp so we don't leave empty space past the bubble ends.
            const pan_top = bounds.y - margin_h;
            const pan_bot = bounds.bottom() - view_h + margin_h;
            const lo = @min(pan_top, pan_bot);
            const hi = @max(pan_top, pan_bot);
            y = std.math.clamp(y, lo, hi);
            break :blk y;
        };

        return .{
            .pan = .{ .x = pan_x, .y = pan_y },
            .zoom = zoom,
        };
    }

    /// Instantly focus the camera on `bounds` (reading zoom + center).
    pub fn focusBounds(
        self: *Viewport,
        bounds: geom.BoundingBox,
        margin_frac: f32,
        preferred_zoom: f32,
        min_z: f32,
        max_z: f32,
    ) void {
        const t = self.focusTarget(bounds, bounds.center(), margin_frac, preferred_zoom, min_z, max_z);
        self.pan = t.pan;
        self.zoom = t.zoom;
    }
};

/// Gap (world units) the spacer leaves between bubbles after resolving overlap.
pub const DEFAULT_GAP: f32 = 16;
/// Max center-to-center distance for implicit working-set membership.
pub const DEFAULT_GROUP_PROXIMITY: f32 = 80;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    viewport: Viewport = .{},

    bubbles: std.ArrayListUnmanaged(Bubble) = .empty,
    connections: std.ArrayListUnmanaged(Connection) = .empty,
    groups: std.ArrayListUnmanaged(WorkingSet) = .empty,

    next_bubble_id: BubbleId = 1,
    next_conn_id: bubble_mod.ConnectionId = 1,
    next_group_id: GroupId = 1,

    /// Minimum gap the spacer enforces between bubble edges.
    gap: f32 = DEFAULT_GAP,
    /// Proximity threshold for auto working-set formation.
    group_proximity: f32 = DEFAULT_GROUP_PROXIMITY,

    pub fn init(allocator: std.mem.Allocator) Canvas {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Canvas) void {
        for (self.bubbles.items) |*b| b.deinit(self.allocator);
        self.bubbles.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        for (self.groups.items) |*g| g.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addBubble(self: *Canvas, kind: bubble_mod.BubbleKind, bounds: geom.BoundingBox) !BubbleId {
        const id = self.next_bubble_id;
        self.next_bubble_id += 1;
        try self.bubbles.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .bounds = bounds,
            .z = @intCast(self.bubbles.items.len),
        });
        return id;
    }

    pub fn findBubble(self: *Canvas, id: BubbleId) ?*Bubble {
        for (self.bubbles.items) |*b| {
            if (b.id == id) return b;
        }
        return null;
    }

    pub fn findBubbleConst(self: *const Canvas, id: BubbleId) ?*const Bubble {
        for (self.bubbles.items) |*b| {
            if (b.id == id) return b;
        }
        return null;
    }

    /// Remove a bubble and any connections that reference it.
    pub fn removeBubble(self: *Canvas, id: BubbleId) void {
        // Drop connections first.
        var ci: usize = 0;
        while (ci < self.connections.items.len) {
            const c = self.connections.items[ci];
            if (c.from.bubble == id or c.to.bubble == id) {
                _ = self.connections.orderedRemove(ci);
            } else {
                ci += 1;
            }
        }
        if (self.indexOf(id)) |idx| {
            self.bubbles.items[idx].deinit(self.allocator);
            _ = self.bubbles.orderedRemove(idx);
        }
        // Strip from working-set membership lists.
        for (self.groups.items) |*g| {
            var mi: usize = 0;
            while (mi < g.members.items.len) {
                if (g.members.items[mi] == id) {
                    _ = g.members.orderedRemove(mi);
                } else {
                    mi += 1;
                }
            }
        }
    }

    /// Top-most bubble under a world point (for hit testing).
    pub fn hitTest(self: *const Canvas, world: geom.Vec2) ?BubbleId {
        var best: ?BubbleId = null;
        var best_z: i64 = -1;
        for (self.bubbles.items) |b| {
            if (b.bounds.containsPoint(world) and @as(i64, b.z) > best_z) {
                best = b.id;
                best_z = b.z;
            }
        }
        return best;
    }

    /// Top-most bubble whose **title bar** contains `world` (for drag handles).
    pub fn hitTestTitleBar(self: *const Canvas, world: geom.Vec2) ?BubbleId {
        var best: ?BubbleId = null;
        var best_z: i64 = -1;
        for (self.bubbles.items) |b| {
            if (b.hitTitleBar(world) and @as(i64, b.z) > best_z) {
                best = b.id;
                best_z = b.z;
            }
        }
        return best;
    }

    pub fn connect(self: *Canvas, from: BubbleId, to: BubbleId, from_line: ?u32) !bubble_mod.ConnectionId {
        return self.connectEx(from, to, from_line, null, null);
    }

    pub fn connectEx(
        self: *Canvas,
        from: BubbleId,
        to: BubbleId,
        from_line: ?u32,
        call_col_start: ?u32,
        call_col_end: ?u32,
    ) !bubble_mod.ConnectionId {
        const id = self.next_conn_id;
        self.next_conn_id += 1;
        try self.connections.append(self.allocator, .{
            .id = id,
            .from = .{ .bubble = from, .line = from_line },
            .to = .{ .bubble = to, .line = null },
            .call_col_start = call_col_start,
            .call_col_end = call_col_end,
        });
        return id;
    }

    /// Closest connection polyline to `world` within `thresh` world units, or null.
    pub fn hitTestConnection(self: *const Canvas, world: geom.Vec2, thresh: f32) ?bubble_mod.ConnectionId {
        const connection_mod = @import("connection.zig");
        var best_id: ?bubble_mod.ConnectionId = null;
        var best_d: f32 = thresh;
        for (self.connections.items) |conn| {
            const from_b = self.findBubbleConst(conn.from.bubble) orelse continue;
            const to_b = self.findBubbleConst(conn.to.bubble) orelse continue;
            const pl = connection_mod.routeRectilinear(from_b.bounds, to_b.bounds);
            const d = connection_mod.distanceToPolyline(pl, world);
            if (d < best_d) {
                best_d = d;
                best_id = conn.id;
            }
        }
        return best_id;
    }

    pub fn findConnection(self: *const Canvas, id: bubble_mod.ConnectionId) ?*const bubble_mod.Connection {
        for (self.connections.items) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// Index of bubble in `bubbles` storage, or null.
    pub fn indexOf(self: *const Canvas, id: BubbleId) ?usize {
        for (self.bubbles.items, 0..) |b, i| {
            if (b.id == id) return i;
        }
        return null;
    }

    /// Tight AABB covering all members of a working set, or null if empty.
    pub fn groupBounds(self: *const Canvas, group_id: GroupId) ?geom.BoundingBox {
        if (group_id == INVALID_GROUP) return null;
        var found = false;
        var box: geom.BoundingBox = undefined;
        for (self.bubbles.items) |b| {
            if (b.group_id != group_id) continue;
            if (!found) {
                box = b.bounds;
                found = true;
            } else {
                box = box.unionBox(b.bounds);
            }
        }
        return if (found) box else null;
    }
};

test "viewport round-trip" {
    var vp = Viewport{ .pan = .{ .x = 100, .y = 50 }, .zoom = 2 };
    const world = geom.Vec2{ .x = 200, .y = 100 };
    const screen = vp.worldToScreen(world);
    const back = vp.screenToWorld(screen);
    try std.testing.expect(world.approxEq(back, 1e-4));
}

test "viewport focus centers bounds" {
    var vp = Viewport{
        .pan = .{},
        .zoom = 0.5,
        .dpi = 1.0,
        .screen_w = 1000,
        .screen_h = 800,
    };
    const box = geom.BoundingBox{ .x = 100, .y = 200, .w = 200, .h = 100 };
    vp.focusBounds(box, 0.15, 1.4, 0.2, 3.0);
    const sc = vp.worldToScreen(box.center());
    try std.testing.expectApproxEqAbs(sc.x, 500, 1.0);
    try std.testing.expectApproxEqAbs(sc.y, 400, 1.0);
    try std.testing.expect(vp.zoom > 0.5); // zoomed in toward preferred
    try std.testing.expectApproxEqAbs(vp.zoom, 1.4, 0.01);
}

test "viewport focus keeps reading zoom on tall bubble" {
    var vp = Viewport{
        .pan = .{},
        .zoom = 2.0,
        .dpi = 1.0,
        .screen_w = 800,
        .screen_h = 600,
    };
    // Narrow enough to fit width at preferred zoom; very tall.
    const box = geom.BoundingBox{ .x = 0, .y = 0, .w = 300, .h = 2000 };
    const anchor = geom.Vec2{ .x = 150, .y = 80 }; // near top
    const t = vp.focusTarget(box, anchor, 0.1, 1.5, 0.15, 4.0);
    // Must not zoom out to fit full height — stay at preferred reading zoom.
    try std.testing.expectApproxEqAbs(t.zoom, 1.5, 0.01);
    // Anchor should land in the upper portion of the screen, not the bubble center.
    vp.pan = t.pan;
    vp.zoom = t.zoom;
    const sc = vp.worldToScreen(anchor);
    try std.testing.expect(sc.y < 600 * 0.45);
    try std.testing.expect(sc.y > 600 * 0.15);
}

test "viewport focus shrinks only for width" {
    var vp = Viewport{
        .pan = .{},
        .zoom = 2.0,
        .dpi = 1.0,
        .screen_w = 800,
        .screen_h = 600,
    };
    const box = geom.BoundingBox{ .x = 0, .y = 0, .w = 1000, .h = 200 };
    const t = vp.focusTarget(box, box.center(), 0.1, 1.5, 0.15, 4.0);
    try std.testing.expect(t.zoom < 1.0); // width forces pull-back
    try std.testing.expect(t.zoom > 0.5);
}
