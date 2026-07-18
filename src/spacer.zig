//! Bubble Spacer — non-overlapping layout engine.
//!
//! From Code Bubbles (ICSE 2010 §5 / CHI 2010 [4]):
//!   "When one bubble is moved on top of another, a bubble spacer automatically
//!    moves the overlapped bubbles out of the way using a simple, recursive,
//!    heuristic algorithm that minimizes the total movement of bubbles."
//!
//! Design:
//! 1. The *seed* bubble is treated as fixed for this resolution pass
//!    (caller pins it while dragging / after a move or resize).
//! 2. Any bubble that intersects the seed (expanded by `gap`) is pushed along
//!    the axis of least penetration (MTV) — minimum movement heuristic.
//! 3. Each pushed bubble becomes a new seed recursively (cascade).
//! 4. A visited set prevents cycles; depth and iteration caps keep it real-time.
//! 5. Group extension (paper §6.3): optional rigid translation of whole working
//!    sets when any member is displaced (hook provided, not fully wired yet).

const std = @import("std");
const geom = @import("geom.zig");
const canvas_mod = @import("canvas.zig");
const bubble_mod = @import("bubble.zig");

pub const Canvas = canvas_mod.Canvas;
pub const BubbleId = bubble_mod.BubbleId;
const GroupId = bubble_mod.GroupId;
const INVALID_GROUP = bubble_mod.INVALID_GROUP;

pub const SpacerConfig = struct {
    /// Extra clearance between bubble edges after resolution.
    gap: f32 = canvas_mod.DEFAULT_GAP,
    /// Hard cap on recursion depth (guards against pathological cascades).
    max_depth: u32 = 32,
    /// Max push operations per resolve call (real-time budget).
    max_pushes: u32 = 512,
    /// Full-canvas pairwise separation passes (collision settling).
    max_iters: u32 = 10,
    /// Ignore residual overlaps smaller than this (float noise).
    epsilon: f32 = 0.5,
};

pub const SpacerStats = struct {
    pushes: u32 = 0,
    max_depth_reached: u32 = 0,
    unresolved: u32 = 0,
};

const SpacerState = struct {
    canvas: *Canvas,
    cfg: SpacerConfig,
    /// Bubble ids already used as fixed seeds in this cascade (cycle guard).
    visited: std.AutoHashMapUnmanaged(BubbleId, void) = .empty,
    stats: SpacerStats = .{},

    fn deinit(self: *SpacerState, allocator: std.mem.Allocator) void {
        self.visited.deinit(allocator);
    }
};

/// Resolve all overlaps caused by (or involving) `seed_id` (cascade from seed).
/// Call after the user finishes moving/resizing a bubble, or while dragging
/// if you want live push-away (pin the dragged bubble first).
pub fn resolve(canvas: *Canvas, seed_id: BubbleId, cfg: SpacerConfig) !SpacerStats {
    var state = SpacerState{ .canvas = canvas, .cfg = cfg };
    defer state.deinit(canvas.allocator);

    // Seed is the immovable obstacle for its children in the cascade.
    try state.visited.put(canvas.allocator, seed_id, {});
    try resolveFrom(&state, seed_id, 0);

    // Global pairwise settle so residual collisions (A–C after A→B cascade) clear.
    const extra = resolveOverlaps(canvas, cfg);
    state.stats.pushes += extra.pushes;
    state.stats.unresolved += extra.unresolved;
    return state.stats;
}

/// Convenience: resolve with canvas gap and defaults.
pub fn resolveDefault(canvas: *Canvas, seed_id: BubbleId) !SpacerStats {
    return resolve(canvas, seed_id, .{ .gap = canvas.gap });
}

/// Separate all overlapping bubble pairs (pinned = immovable).
/// Use for initial layout packing or a full collision pass without a seed.
pub fn resolveOverlaps(canvas: *Canvas, cfg: SpacerConfig) SpacerStats {
    var stats: SpacerStats = .{};
    const half_gap = cfg.gap * 0.5;
    var iter: u32 = 0;
    while (iter < cfg.max_iters) : (iter += 1) {
        var any = false;
        const n = canvas.bubbles.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j = i + 1;
            while (j < n) : (j += 1) {
                if (stats.pushes >= cfg.max_pushes) {
                    stats.unresolved += 1;
                    return stats;
                }
                const a = &canvas.bubbles.items[i];
                const b = &canvas.bubbles.items[j];
                if (a.pinned and b.pinned) continue;

                const box_a = a.bounds.expanded(half_gap);
                const box_b = b.bounds.expanded(half_gap);
                if (!box_a.intersects(box_b)) continue;

                // MTV to push B out of A (expanded space).
                const sep_b = geom.BoundingBox.separationVector(box_a, box_b);
                if (@abs(sep_b.x) < cfg.epsilon and @abs(sep_b.y) < cfg.epsilon) continue;

                if (a.pinned and !b.pinned) {
                    b.translate(sep_b);
                } else if (b.pinned and !a.pinned) {
                    const sep_a = geom.BoundingBox.separationVector(box_b, box_a);
                    a.translate(sep_a);
                } else {
                    // Both free: split movement (minimize total travel).
                    a.translate(.{ .x = -sep_b.x * 0.5, .y = -sep_b.y * 0.5 });
                    b.translate(.{ .x = sep_b.x * 0.5, .y = sep_b.y * 0.5 });
                }
                stats.pushes += 1;
                any = true;
            }
        }
        stats.max_depth_reached = iter + 1;
        if (!any) break;
    }
    // Count remaining overlaps as unresolved.
    const half = cfg.gap * 0.5;
    const n = canvas.bubbles.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j = i + 1;
        while (j < n) : (j += 1) {
            const a = canvas.bubbles.items[i].bounds.expanded(half);
            const b = canvas.bubbles.items[j].bounds.expanded(half);
            if (a.intersects(b)) stats.unresolved += 1;
        }
    }
    return stats;
}

/// Full-canvas collision with canvas gap (layout open / drop).
pub fn resolveAllDefault(canvas: *Canvas) SpacerStats {
    return resolveOverlaps(canvas, .{ .gap = canvas.gap, .max_iters = 16, .max_pushes = 1024 });
}

fn resolveFrom(state: *SpacerState, fixed_id: BubbleId, depth: u32) !void {
    state.stats.max_depth_reached = @max(state.stats.max_depth_reached, depth);
    if (depth >= state.cfg.max_depth) return;
    if (state.stats.pushes >= state.cfg.max_pushes) return;

    const fixed = state.canvas.findBubble(fixed_id) orelse return;
    // Inflate fixed bounds by gap so cleared pairs keep visual separation.
    const obstacle = fixed.bounds.expanded(state.cfg.gap * 0.5);

    // Snapshot ids we may push; list can be mutated only via positions.
    var to_push: std.ArrayListUnmanaged(BubbleId) = .empty;
    defer to_push.deinit(state.canvas.allocator);

    for (state.canvas.bubbles.items) |*other| {
        if (other.id == fixed_id) continue;
        if (other.pinned) continue;
        if (state.visited.contains(other.id)) continue;

        const other_box = other.bounds.expanded(state.cfg.gap * 0.5);
        if (!obstacle.intersects(other_box)) continue;

        const sep = geom.BoundingBox.separationVector(obstacle, other_box);
        if (@abs(sep.x) < state.cfg.epsilon and @abs(sep.y) < state.cfg.epsilon) continue;

        other.translate(sep);
        state.stats.pushes += 1;
        try to_push.append(state.canvas.allocator, other.id);

        if (state.stats.pushes >= state.cfg.max_pushes) break;
    }

    // Cascade: each pushed bubble is now fixed for its neighbors.
    for (to_push.items) |pushed_id| {
        const gop = try state.visited.getOrPut(state.canvas.allocator, pushed_id);
        if (gop.found_existing) continue;
        try resolveFrom(state, pushed_id, depth + 1);
    }
}

/// File-halos: one group per document for fragment bubbles on the canvas.
/// Single-member files still get a halo (drop target + visual file region).
/// Terminals / folders / notes are ungrouped.
///
/// (Proximity working-sets from the paper are deferred; default chrome is file identity.)
pub fn recomputeWorkingSets(canvas: *Canvas) !void {
    try recomputeFileGroups(canvas);
}

pub fn recomputeFileGroups(canvas: *Canvas) !void {
    // Tear down old groups.
    for (canvas.groups.items) |*g| g.deinit(canvas.allocator);
    canvas.groups.clearRetainingCapacity();
    for (canvas.bubbles.items) |*b| b.group_id = INVALID_GROUP;

    // doc_id → group index in canvas.groups
    var doc_to_gidx: std.AutoHashMapUnmanaged(bubble_mod.DocId, usize) = .empty;
    defer doc_to_gidx.deinit(canvas.allocator);

    var color: u8 = 0;
    for (canvas.bubbles.items) |*b| {
        // Only document-backed code/import bubbles form file groups.
        if (b.kind != .code and b.kind != .imports) continue;
        const f = b.fragment() orelse continue;
        const gop = try doc_to_gidx.getOrPut(canvas.allocator, f.doc);
        if (!gop.found_existing) {
            const gid = canvas.next_group_id;
            canvas.next_group_id += 1;
            // Stable-ish color from doc id.
            const cidx: u8 = @truncate(f.doc +% color);
            color +%= 1;
            try canvas.groups.append(canvas.allocator, .{
                .id = gid,
                .color_index = cidx,
                .doc = f.doc,
            });
            gop.value_ptr.* = canvas.groups.items.len - 1;
        }
        const gidx = gop.value_ptr.*;
        const g = &canvas.groups.items[gidx];
        b.group_id = g.id;
        try g.members.append(canvas.allocator, b.id);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "spacer pushes overlapping bubble along shallow axis" {
    const alloc = std.testing.allocator;

    var canvas = Canvas.init(alloc);
    defer canvas.deinit();
    canvas.gap = 10;

    // A: 0,0 100x50 — fixed seed
    const a = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 100, .h = 50 });
    // B overlaps A on the right by 20px
    const b = try canvas.addBubble(.code, .{ .x = 80, .y = 5, .w = 100, .h = 50 });

    const stats = try resolveDefault(&canvas, a);
    try std.testing.expect(stats.pushes >= 1);

    const ba = canvas.findBubble(a).?;
    const bb = canvas.findBubble(b).?;
    // With gap, B should sit fully to the right of A.
    try std.testing.expect(bb.bounds.x >= ba.bounds.right() + canvas.gap - 1);
    try std.testing.expect(!ba.bounds.expanded(canvas.gap * 0.5 - 0.1)
        .intersects(bb.bounds.expanded(canvas.gap * 0.5 - 0.1)));
}

test "spacer cascades through a chain" {
    const alloc = std.testing.allocator;

    var canvas = Canvas.init(alloc);
    defer canvas.deinit();
    canvas.gap = 0;

    const a = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 50, .h = 50 });
    _ = try canvas.addBubble(.code, .{ .x = 40, .y = 0, .w = 50, .h = 50 });
    _ = try canvas.addBubble(.code, .{ .x = 80, .y = 0, .w = 50, .h = 50 });

    const stats = try resolveDefault(&canvas, a);
    try std.testing.expect(stats.pushes >= 2);

    // All pairs non-overlapping.
    const items = canvas.bubbles.items;
    try std.testing.expect(!items[0].bounds.intersects(items[1].bounds));
    try std.testing.expect(!items[1].bounds.intersects(items[2].bounds));
    try std.testing.expect(!items[0].bounds.intersects(items[2].bounds));
}

test "resolveOverlaps separates free pairs and respects pin" {
    const alloc = std.testing.allocator;
    var canvas = Canvas.init(alloc);
    defer canvas.deinit();
    canvas.gap = 8;

    const a = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 80, .h = 40 });
    const b = try canvas.addBubble(.code, .{ .x = 40, .y = 10, .w = 80, .h = 40 });
    canvas.findBubble(a).?.pinned = true;

    const stats = resolveOverlaps(&canvas, .{ .gap = canvas.gap });
    try std.testing.expect(stats.pushes >= 1);

    const ba = canvas.findBubble(a).?;
    const bb = canvas.findBubble(b).?;
    // Pinned A stays put.
    try std.testing.expectApproxEqAbs(@as(f32, 0), ba.bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ba.bounds.y, 0.01);
    // B is pushed clear of A + gap.
    try std.testing.expect(!ba.bounds.expanded(canvas.gap * 0.5 - 0.1)
        .intersects(bb.bounds.expanded(canvas.gap * 0.5 - 0.1)));
}

test "file groups form by document id" {
    const alloc = std.testing.allocator;

    var canvas = Canvas.init(alloc);
    defer canvas.deinit();

    const a = try canvas.addBubble(.code, .{ .x = 0, .y = 0, .w = 40, .h = 40 });
    const b = try canvas.addBubble(.code, .{ .x = 50, .y = 0, .w = 40, .h = 40 });
    const c = try canvas.addBubble(.code, .{ .x = 500, .y = 500, .w = 40, .h = 40 });
    canvas.findBubble(a).?.setFragment(1, 0, 5);
    canvas.findBubble(b).?.setFragment(1, 5, 10); // same file
    canvas.findBubble(c).?.setFragment(2, 0, 3); // other file

    try recomputeFileGroups(&canvas);
    try std.testing.expect(canvas.groups.items.len == 2);
    // Both doc1 bubbles share a group.
    try std.testing.expect(canvas.bubbles.items[0].group_id == canvas.bubbles.items[1].group_id);
    try std.testing.expect(canvas.bubbles.items[0].group_id != canvas.bubbles.items[2].group_id);
}
