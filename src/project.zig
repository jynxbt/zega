//! Project root + current folder navigation (navigate-in-place).

const std = @import("std");

pub const Project = struct {
    allocator: std.mem.Allocator,
    /// Absolute project root path (owned).
    root_abs: []u8 = &.{},
    /// Relative path under root: "" = root, "src", "src/util" (owned, no leading/trailing slash).
    cwd_rel: []u8 = &.{},
    /// Basename of root for breadcrumb first segment (owned).
    root_name: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Project {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Project) void {
        if (self.root_abs.len != 0) self.allocator.free(self.root_abs);
        if (self.cwd_rel.len != 0) self.allocator.free(self.cwd_rel);
        if (self.root_name.len != 0) self.allocator.free(self.root_name);
        self.* = undefined;
    }

    pub fn setRoot(self: *Project, abs_path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, abs_path);
        // Normalize: strip trailing slashes.
        var end = copy.len;
        while (end > 1 and copy[end - 1] == '/') end -= 1;
        const trimmed = try self.allocator.dupe(u8, copy[0..end]);
        self.allocator.free(copy);

        if (self.root_abs.len != 0) self.allocator.free(self.root_abs);
        self.root_abs = trimmed;

        const base = std.fs.path.basename(self.root_abs);
        const name = try self.allocator.dupe(u8, base);
        if (self.root_name.len != 0) self.allocator.free(self.root_name);
        self.root_name = name;

        if (self.cwd_rel.len != 0) self.allocator.free(self.cwd_rel);
        self.cwd_rel = try self.allocator.dupe(u8, "");
    }

    pub fn setCwdRel(self: *Project, rel: []const u8) !void {
        // Normalize: no leading/trailing '/'
        var s = rel;
        while (s.len > 0 and s[0] == '/') s = s[1..];
        while (s.len > 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
        const copy = try self.allocator.dupe(u8, s);
        if (self.cwd_rel.len != 0) self.allocator.free(self.cwd_rel);
        self.cwd_rel = copy;
    }

    /// Absolute path of the current folder.
    pub fn absCurrent(self: *const Project, buf: []u8) ![]const u8 {
        if (self.cwd_rel.len == 0) {
            if (self.root_abs.len >= buf.len) return error.NameTooLong;
            @memcpy(buf[0..self.root_abs.len], self.root_abs);
            return buf[0..self.root_abs.len];
        }
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root_abs, self.cwd_rel });
    }

    /// Join cwd_rel with a child name → new relative path (caller frees with allocator).
    pub fn joinRel(self: *const Project, child: []const u8) ![]u8 {
        if (self.cwd_rel.len == 0) return try self.allocator.dupe(u8, child);
        return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.cwd_rel, child });
    }

    /// Breadcrumb segments: [root_name, ...cwd parts]. Uses internal buffers;
    /// valid until next project mutation. Written into `out` (max capacity).
    pub fn breadcrumb(self: *const Project, out: [][]const u8) usize {
        var n: usize = 0;
        if (n < out.len) {
            out[n] = if (self.root_name.len != 0) self.root_name else "project";
            n += 1;
        }
        if (self.cwd_rel.len == 0) return n;
        var it = std.mem.splitScalar(u8, self.cwd_rel, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (n >= out.len) break;
            out[n] = seg;
            n += 1;
        }
        return n;
    }

    /// Navigate to breadcrumb index: 0 = root, 1 = first child, etc.
    pub fn pathForBreadcrumbIndex(self: *const Project, index: usize, buf: []u8) ![]const u8 {
        if (index == 0) return "";
        // Rebuild rel from first `index` segments of cwd_rel (cwd has depth segments).
        var segs: [32][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, self.cwd_rel, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            if (count >= segs.len) break;
            segs[count] = seg;
            count += 1;
        }
        const take = @min(index, count);
        if (take == 0) return "";
        var len: usize = 0;
        var i: usize = 0;
        while (i < take) : (i += 1) {
            if (i > 0) {
                if (len >= buf.len) return error.NameTooLong;
                buf[len] = '/';
                len += 1;
            }
            if (len + segs[i].len > buf.len) return error.NameTooLong;
            @memcpy(buf[len .. len + segs[i].len], segs[i]);
            len += segs[i].len;
        }
        return buf[0..len];
    }
};

pub fn shouldSkipDirName(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '.') return true; // .git, .zig-cache, hidden
    return std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, ".zig-cache");
}
