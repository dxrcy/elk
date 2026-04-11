const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
    });

    const elk_dep = b.dependency("elk", .{
        .target = target,
        .optimize = optimize,
    }).module("elk");

    const mcz_mod = b.dependency("mcz", .{
        .target = target,
        .optimize = optimize,
    }).module("mcz");

    exe_mod.addImport("build_zon", build_zon_mod);
    exe_mod.addImport("elk", elk_dep);
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
}
