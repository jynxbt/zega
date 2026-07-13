//! Spatial primitives for the infinite virtual canvas.
//! All coordinates are in world space (canvas units) unless noted.

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }

    pub fn lengthSq(a: Vec2) f32 {
        return a.x * a.x + a.y * a.y;
    }

    pub fn length(a: Vec2) f32 {
        return @sqrt(a.lengthSq());
    }

    pub fn approxEq(a: Vec2, b: Vec2, eps: f32) bool {
        return @abs(a.x - b.x) <= eps and @abs(a.y - b.y) <= eps;
    }
};

/// Axis-aligned bounding box in world space.
/// Origin is top-left; +x right, +y down (screen-like, matches typical 2D UI).
pub const BoundingBox = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn fromPosSize(position: Vec2, dimensions: Vec2) BoundingBox {
        return .{ .x = position.x, .y = position.y, .w = dimensions.x, .h = dimensions.y };
    }

    pub fn pos(self: BoundingBox) Vec2 {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn size(self: BoundingBox) Vec2 {
        return .{ .x = self.w, .y = self.h };
    }

    pub fn center(self: BoundingBox) Vec2 {
        return .{ .x = self.x + self.w * 0.5, .y = self.y + self.h * 0.5 };
    }

    pub fn right(self: BoundingBox) f32 {
        return self.x + self.w;
    }

    pub fn bottom(self: BoundingBox) f32 {
        return self.y + self.h;
    }

    pub fn translated(self: BoundingBox, d: Vec2) BoundingBox {
        return .{ .x = self.x + d.x, .y = self.y + d.y, .w = self.w, .h = self.h };
    }

    pub fn expanded(self: BoundingBox, margin: f32) BoundingBox {
        return .{
            .x = self.x - margin,
            .y = self.y - margin,
            .w = self.w + margin * 2,
            .h = self.h + margin * 2,
        };
    }

    pub fn containsPoint(self: BoundingBox, p: Vec2) bool {
        return p.x >= self.x and p.x < self.right() and
            p.y >= self.y and p.y < self.bottom();
    }

    pub fn intersects(a: BoundingBox, b: BoundingBox) bool {
        return a.x < b.right() and a.right() > b.x and
            a.y < b.bottom() and a.bottom() > b.y;
    }

    /// Positive overlap extents on each axis when boxes intersect; zero otherwise.
    pub fn overlap(a: BoundingBox, b: BoundingBox) Vec2 {
        if (!intersects(a, b)) return .{};
        return .{
            .x = @min(a.right(), b.right()) - @max(a.x, b.x),
            .y = @min(a.bottom(), b.bottom()) - @max(a.y, b.y),
        };
    }

    /// Union of two boxes (tight AABB covering both).
    pub fn unionBox(a: BoundingBox, b: BoundingBox) BoundingBox {
        const min_x = @min(a.x, b.x);
        const min_y = @min(a.y, b.y);
        const max_x = @max(a.right(), b.right());
        const max_y = @max(a.bottom(), b.bottom());
        return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
    }

    /// Minimum translation vector (MTV) to push `movable` fully out of `fixed`.
    /// Chooses the axis of *least* penetration to minimize movement (paper heuristic).
    /// Prefer direction away from the center of `fixed` when ties.
    pub fn separationVector(fixed: BoundingBox, movable: BoundingBox) Vec2 {
        if (!intersects(fixed, movable)) return .{};

        const ov = overlap(fixed, movable);
        const mc = movable.center();
        const fc = fixed.center();

        // Push along the shallower penetration axis.
        if (ov.x < ov.y) {
            const dir: f32 = if (mc.x >= fc.x) 1 else -1;
            return .{ .x = ov.x * dir, .y = 0 };
        } else {
            const dir: f32 = if (mc.y >= fc.y) 1 else -1;
            return .{ .x = 0, .y = ov.y * dir };
        }
    }
};

test "BoundingBox intersects and separation" {
    const a = BoundingBox{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const b = BoundingBox{ .x = 80, .y = 10, .w = 100, .h = 50 };
    try std.testing.expect(a.intersects(b));
    const sep = BoundingBox.separationVector(a, b);
    // Shallower axis is X (overlap 20) vs Y (overlap 40) → push on X.
    try std.testing.expect(sep.x > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sep.y, 1e-5);
    const resolved = b.translated(sep);
    try std.testing.expect(!a.intersects(resolved));
}
