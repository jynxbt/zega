const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pure layout core (no GPU) — library + tests.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addIncludePath(b.path("third_party"));
    core_mod.addCSourceFile(.{
        .file = b.path("third_party/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    core_mod.link_libc = true;

    const lib = b.addLibrary(.{
        .name = "zega",
        .root_module = core_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addIncludePath(b.path("third_party"));
    test_mod.addCSourceFile(.{
        .file = b.path("third_party/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    test_mod.link_libc = true;

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Sokol-backed editor shell.
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });
    app_mod.addIncludePath(b.path("third_party"));
    app_mod.addCSourceFile(.{
        .file = b.path("third_party/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    app_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "zega",
        .root_module = app_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the zega editor");
    run_step.dependOn(&run_cmd.step);
}
