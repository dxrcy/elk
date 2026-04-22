const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("elk", .{
        .root_source_file = b.path("lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    const mcz_mod = b.dependency("mcz", .{
        .target = target,
        .optimize = optimize,
    }).module("mcz");

    exe_mod.addImport("build_zon", build_zon_mod);
    exe_mod.addImport("elk", lib_mod);
    exe_mod.addImport("mcz", mcz_mod);

    const exe = b.addExecutable(.{
        .name = "elk",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const test_cmd = b.addRunArtifact(unit_tests);
    test_step.dependOn(&test_cmd.step);

    const docs_step = b.step("docs", "Build docs");
    const docs_obj = b.addObject(.{
        .name = "elk",
        .root_module = lib_mod,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
