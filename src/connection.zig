//! Rectilinear (orthogonal) connector geometry between bubbles.
//! Paper: "a rectilinear arrow connection is added to indicate the calling
//! relationship between the resulting method definition bubble and the bubble
//! containing the call." (Code Bubbles, Fig. 1-M)

const std = @import("std");
const geom = @import("geom.zig");

/// Minimum clear channel between bubbles for an elbow (world units).
pub const min_channel: f32 = 16;

pub const Polyline = struct {
    points: [6]geom.Vec2 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Polyline) []const geom.Vec2 {
        return self.points[0..self.len];
    }

    pub fn last(self: *const Polyline) geom.Vec2 {
        std.debug.assert(self.len > 0);
        return self.points[self.len - 1];
    }

    pub fn secondLast(self: *const Polyline) geom.Vec2 {
        std.debug.assert(self.len >= 2);
        return self.points[self.len - 2];
    }

    fn push(self: *Polyline, p: geom.Vec2) void {
        // Drop zero-length segments / duplicates.
        if (self.len > 0) {
            const prev = self.points[self.len - 1];
            if (prev.approxEq(p, 0.25)) return;
        }
        if (self.len >= self.points.len) return;
        self.points[self.len] = p;
        self.len += 1;
    }
};

pub const ArrowHead = struct {
    tip: geom.Vec2,
    left: geom.Vec2,
    right: geom.Vec2,
};

const Side = enum { left, right, top, bottom };

/// Build a clean orthogonal path between two AABBs.
/// Picks exterior ports so the path does not start inside either box, and
/// uses a mid-channel that stays outside both boxes when possible.
pub fn routeRectilinear(from: geom.BoundingBox, to: geom.BoundingBox) Polyline {
    const fc = from.center();
    const tc = to.center();
    const dx = tc.x - fc.x;
    const dy = tc.y - fc.y;

    // Decide primary direction from relative centers (with separation bias).
    const gap_x = if (dx >= 0) to.x - from.right() else from.x - to.right();
    const gap_y = if (dy >= 0) to.y - from.bottom() else from.y - to.bottom();

    // Prefer horizontal routing when there is a clear side gap, else vertical.
    const prefer_h = gap_x > gap_y;

    var pl: Polyline = .{};

    if (prefer_h and dx >= 0) {
        // --- to the right: exit right center, enter left center ---
        const start = portCenter(from, .right);
        const end = portCenter(to, .left);
        routeHVH(&pl, start, end, from, to);
    } else if (prefer_h and dx < 0) {
        // --- to the left: exit left center, enter right center ---
        const start = portCenter(from, .left);
        const end = portCenter(to, .right);
        routeHVHLeft(&pl, start, end, from, to);
    } else if (dy >= 0) {
        // --- below: exit bottom center, enter top center ---
        const start = portCenter(from, .bottom);
        const end = portCenter(to, .top);
        routeVHV(&pl, start, end, from, to);
    } else {
        // --- above: exit top center, enter bottom center ---
        const start = portCenter(from, .top);
        const end = portCenter(to, .bottom);
        routeVHVUp(&pl, start, end, from, to);
    }

    // Guarantee at least start→end if something failed.
    if (pl.len < 2) {
        pl.len = 0;
        pl.push(from.center());
        pl.push(to.center());
    }
    return pl;
}

/// Attachment point at the midpoint of a box edge (centered arrows).
fn portCenter(box: geom.BoundingBox, side: Side) geom.Vec2 {
    const c = box.center();
    return switch (side) {
        .left => .{ .x = box.x, .y = c.y },
        .right => .{ .x = box.right(), .y = c.y },
        .top => .{ .x = c.x, .y = box.y },
        .bottom => .{ .x = c.x, .y = box.bottom() },
    };
}

/// Horizontal-first when target is to the right: H → V → H
fn routeHVH(pl: *Polyline, start: geom.Vec2, end: geom.Vec2, from: geom.BoundingBox, to: geom.BoundingBox) void {
    pl.push(start);
    // Mid channel strictly between boxes when gap is positive.
    var mid_x = (start.x + end.x) * 0.5;
    if (end.x > start.x) {
        const lo = start.x + min_channel * 0.5;
        const hi = end.x - min_channel * 0.5;
        if (hi > lo) mid_x = std.math.clamp(mid_x, lo, hi);
    } else {
        // Overlap / nested: route outside both tops.
        const exterior_y = @min(from.y, to.y) - min_channel;
        pl.push(.{ .x = start.x + min_channel, .y = start.y });
        pl.push(.{ .x = start.x + min_channel, .y = exterior_y });
        pl.push(.{ .x = end.x - min_channel, .y = exterior_y });
        pl.push(.{ .x = end.x - min_channel, .y = end.y });
        pl.push(end);
        return;
    }

    if (@abs(start.y - end.y) < 0.5) {
        pl.push(end);
        return;
    }
    pl.push(.{ .x = mid_x, .y = start.y });
    pl.push(.{ .x = mid_x, .y = end.y });
    pl.push(end);
}

/// Target to the left: step left, vertical, into target from the right.
fn routeHVHLeft(pl: *Polyline, start: geom.Vec2, end: geom.Vec2, from: geom.BoundingBox, to: geom.BoundingBox) void {
    _ = from;
    _ = to;
    pl.push(start);
    const channel_x = @min(start.x, end.x) - min_channel;
    if (@abs(start.y - end.y) < 0.5) {
        pl.push(.{ .x = channel_x, .y = start.y });
        pl.push(.{ .x = channel_x, .y = end.y });
        pl.push(end);
        return;
    }
    pl.push(.{ .x = channel_x, .y = start.y });
    pl.push(.{ .x = channel_x, .y = end.y });
    pl.push(end);
}

/// Vertical-first when target is below: V → H → V
fn routeVHV(pl: *Polyline, start: geom.Vec2, end: geom.Vec2, from: geom.BoundingBox, to: geom.BoundingBox) void {
    pl.push(start);
    var mid_y = (start.y + end.y) * 0.5;
    if (end.y > start.y) {
        const lo = start.y + min_channel * 0.5;
        const hi = end.y - min_channel * 0.5;
        if (hi > lo) mid_y = std.math.clamp(mid_y, lo, hi);
    } else {
        const exterior_x = @max(from.right(), to.right()) + min_channel;
        pl.push(.{ .x = start.x, .y = start.y + min_channel });
        pl.push(.{ .x = exterior_x, .y = start.y + min_channel });
        pl.push(.{ .x = exterior_x, .y = end.y - min_channel });
        pl.push(.{ .x = end.x, .y = end.y - min_channel });
        pl.push(end);
        return;
    }

    if (@abs(start.x - end.x) < 0.5) {
        pl.push(end);
        return;
    }
    pl.push(.{ .x = start.x, .y = mid_y });
    pl.push(.{ .x = end.x, .y = mid_y });
    pl.push(end);
}

fn routeVHVUp(pl: *Polyline, start: geom.Vec2, end: geom.Vec2, from: geom.BoundingBox, to: geom.BoundingBox) void {
    _ = from;
    _ = to;
    pl.push(start);
    const channel_y = @min(start.y, end.y) - min_channel;
    if (@abs(start.x - end.x) < 0.5) {
        pl.push(.{ .x = start.x, .y = channel_y });
        pl.push(.{ .x = end.x, .y = channel_y });
        pl.push(end);
        return;
    }
    pl.push(.{ .x = start.x, .y = channel_y });
    pl.push(.{ .x = end.x, .y = channel_y });
    pl.push(end);
}

/// Distance from point to polyline (min over segments).
pub fn distanceToPolyline(pl: Polyline, p: geom.Vec2) f32 {
    if (pl.len < 2) return std.math.floatMax(f32);
    var best: f32 = std.math.floatMax(f32);
    var i: u8 = 1;
    while (i < pl.len) : (i += 1) {
        const d = distanceToSegment(pl.points[i - 1], pl.points[i], p);
        if (d < best) best = d;
    }
    return best;
}

fn distanceToSegment(a: geom.Vec2, b: geom.Vec2, p: geom.Vec2) f32 {
    const ab = geom.Vec2.sub(b, a);
    const len_sq = ab.lengthSq();
    if (len_sq < 1e-8) return geom.Vec2.sub(p, a).length();
    var t = (geom.Vec2.sub(p, a).x * ab.x + geom.Vec2.sub(p, a).y * ab.y) / len_sq;
    t = std.math.clamp(t, 0, 1);
    const proj = geom.Vec2{ .x = a.x + ab.x * t, .y = a.y + ab.y * t };
    return geom.Vec2.sub(p, proj).length();
}

/// Arrowhead at end of polyline; size in world units.
pub fn arrowHead(pl: Polyline, size: f32) ?ArrowHead {
    if (pl.len < 2) return null;
    const tip = pl.last();
    const prev = pl.secondLast();
    var dir = geom.Vec2.sub(tip, prev);
    const len = dir.length();
    if (len < 1e-4) return null;
    dir = dir.scale(1.0 / len);

    const px = -dir.y;
    const py = dir.x;
    // Pull tip slightly back so the head sits on the edge, not past it.
    const tip2 = geom.Vec2.sub(tip, dir.scale(0.5));
    const back = geom.Vec2.sub(tip2, dir.scale(size));
    return .{
        .tip = tip2,
        .left = .{ .x = back.x + px * size * 0.55, .y = back.y + py * size * 0.55 },
        .right = .{ .x = back.x - px * size * 0.55, .y = back.y - py * size * 0.55 },
    };
}

// --- tests ---

test "route rightward HVH orthogonal" {
    const from = geom.BoundingBox{ .x = 0, .y = 0, .w = 100, .h = 80 };
    const to = geom.BoundingBox{ .x = 200, .y = 120, .w = 100, .h = 80 };
    const pl = routeRectilinear(from, to);
    try std.testing.expect(pl.len >= 2);
    try std.testing.expectApproxEqAbs(from.right(), pl.points[0].x, 1e-3);
    try std.testing.expectApproxEqAbs(from.center().y, pl.points[0].y, 1e-3);
    try std.testing.expectApproxEqAbs(to.x, pl.last().x, 1e-3);
    try std.testing.expectApproxEqAbs(to.center().y, pl.last().y, 1e-3);
    try expectOrthogonal(pl);
}

test "route below VHV orthogonal" {
    const from = geom.BoundingBox{ .x = 0, .y = 0, .w = 120, .h = 60 };
    const to = geom.BoundingBox{ .x = 20, .y = 200, .w = 120, .h = 60 };
    const pl = routeRectilinear(from, to);
    try std.testing.expect(pl.len >= 2);
    try std.testing.expectApproxEqAbs(from.bottom(), pl.points[0].y, 1e-3);
    try std.testing.expectApproxEqAbs(from.center().x, pl.points[0].x, 1e-3);
    try std.testing.expectApproxEqAbs(to.y, pl.last().y, 1e-3);
    try std.testing.expectApproxEqAbs(to.center().x, pl.last().x, 1e-3);
    try expectOrthogonal(pl);
}

test "route leftward orthogonal" {
    const from = geom.BoundingBox{ .x = 300, .y = 0, .w = 100, .h = 50 };
    const to = geom.BoundingBox{ .x = 0, .y = 80, .w = 100, .h = 50 };
    const pl = routeRectilinear(from, to);
    try expectOrthogonal(pl);
    try std.testing.expect(pl.last().x <= to.right() + 1);
}

test "arrow head non-zero" {
    const from = geom.BoundingBox{ .x = 0, .y = 0, .w = 50, .h = 40 };
    const to = geom.BoundingBox{ .x = 150, .y = 0, .w = 50, .h = 40 };
    const pl = routeRectilinear(from, to);
    const ah = arrowHead(pl, 12) orelse return error.TestUnexpectedResult;
    try std.testing.expect(geom.Vec2.sub(ah.left, ah.tip).length() > 1);
}

test "distance to horizontal segment" {
    const pl = routeRectilinear(
        .{ .x = 0, .y = 0, .w = 50, .h = 40 },
        .{ .x = 150, .y = 0, .w = 50, .h = 40 },
    );
    const mid = geom.Vec2{ .x = 100, .y = 20 };
    const d = distanceToPolyline(pl, mid);
    try std.testing.expect(d < 5);
}

fn expectOrthogonal(pl: Polyline) !void {
    var i: u8 = 1;
    while (i < pl.len) : (i += 1) {
        const a = pl.points[i - 1];
        const b = pl.points[i];
        const orth = @abs(a.x - b.x) < 1e-3 or @abs(a.y - b.y) < 1e-3;
        try std.testing.expect(orth);
    }
}
