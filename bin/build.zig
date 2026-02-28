const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lcz_mod = b.dependency("lcz", .{
        .target = target,
        .optimize = optimize,
    }).module("lcz");

    const mcz_mod = b.dependency("mcz", .{
        .target = target,
        .optimize = optimize,
    }).module("mcz");

    exe_mod.addImport("lcz", lcz_mod);
    exe_mod.addImport("mcz", mcz_mod);

    const exe = b.addExecutable(.{
        .name = "lcz",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
