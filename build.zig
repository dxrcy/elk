const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Local modules
    const mod_lib = b.addModule("elk", .{
        .root_source_file = b.path("lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod_cli= b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod_build_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Fetched modules
    const mod_zilc = (try b.dependencyLazy("zilc", .{})).module("zilc");

    mod_cli.addImport("elk", mod_lib);
    mod_cli.addImport("zilc", mod_zilc);
    mod_cli.addImport("build_zon", mod_build_zon);

    { // zig build run
        const exe_cli = b.addExecutable(.{ .name = "elk", .root_module = mod_cli });
        b.installArtifact(exe_cli);
        const cmd_run = b.addRunArtifact(exe_cli);
        cmd_run.addPassthruArgs();
        b.step("run", "Run the application").dependOn(&cmd_run.step);
    }

    { // zig build test
        const step_test= b.step("test", "Run unit tests");
        step_test.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod_lib })).step);
        step_test.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod_cli })).step);
    }

    { // zig build docs
        const step_docs = b.step("docs", "Build docs");
        const obj_lib = b.addObject(.{ .name = "elk", .root_module = mod_lib });
        step_docs.dependOn(&b.addInstallDirectory(.{
            .source_dir = obj_lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        }).step);
    }
}
