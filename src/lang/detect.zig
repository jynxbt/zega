//! Language detection for zega (Zig + Rust only in Milestone A).

const std = @import("std");

pub const Language = enum {
    zig,
    rust,
    unknown,

    pub fn name(self: Language) []const u8 {
        return switch (self) {
            .zig => "zig",
            .rust => "rust",
            .unknown => "text",
        };
    }
};

/// Detect language from file path extension (flow-style file type match).
pub fn fromPath(path: []const u8) Language {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".zig")) return .zig;
    if (std.mem.endsWith(u8, base, ".rs")) return .rust;
    // Zon is Zig object notation — treat as zig for outline purposes.
    if (std.mem.endsWith(u8, base, ".zon")) return .zig;
    return .unknown;
}

pub fn isSupported(path: []const u8) bool {
    return fromPath(path) != .unknown;
}

test "detect zig and rust" {
    try std.testing.expect(fromPath("src/main.zig") == .zig);
    try std.testing.expect(fromPath("/tmp/foo.Rs") == .unknown); // case-sensitive extensions
    try std.testing.expect(fromPath("lib.rs") == .rust);
    try std.testing.expect(fromPath("readme.md") == .unknown);
}
