const std = @import("std");

/// Demo module for zega Code Bubbles — real Zig source.
pub fn main() !void {
    const p = Point{ .x = 3, .y = 4 };
    std.debug.print("len={d}\n", .{p.length()});
    try runApp();
}

fn runApp() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    _ = alloc;
}

pub const Point = struct {
    x: f32,
    y: f32,

    pub fn length(self: Point) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
};

pub const Color = enum {
    red,
    green,
    blue,
};

pub fn blend(a: Color, b: Color) Color {
    _ = a;
    return b;
}

test "point length" {
    const p = Point{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 5), p.length(), 1e-5);
}
