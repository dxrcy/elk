const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("elk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = module,
    });
    const test_cmd = b.addRunArtifact(unit_tests);
    test_step.dependOn(&test_cmd.step);

    const docs_step = b.step("docs", "Build docs");
    const docs_obj = b.addObject(.{
        .name = "elk",
        .root_module = module,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}
