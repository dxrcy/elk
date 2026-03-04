const std = @import("std");
const Io = std.Io;

const lcz = @import("lcz");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = lcz.Reporter.new(io);
    try reporter.init();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    const cli = Cli.parse(&args) catch |err| switch (err) {
        error.DisplayHelp => {
            std.debug.print("todo: help info\n", .{});
            return 0;
        },
        error.DisplayVersion => {
            std.debug.print("todo: version info\n", .{});
            return 0;
        },
        else => return err,
    };

    const policies: lcz.Policies = .config_lace;
    reporter.options.policies = &policies;

    const traps: lcz.Traps = comptime .initBuiltins(&.{
        lcz.Traps.Standard,
        lcz.Traps.Debug,
    });
    const hooks: lcz.Runtime.Hooks = .{};

    switch (cli.command) {
        .assemble => {
            const source = try Io.Dir.cwd().readFileAlloc(io, cli.filepath, gpa, .unlimited);
            defer gpa.free(source);

            reporter.setSource(source);

            var air: lcz.Air = .init();
            defer air.deinit(gpa);

            var parser: lcz.Parser = .new(&air, &traps, source, &reporter);

            try parser.parse(gpa);
            if (reporter.getLevel() == .err) {
                reporter.showSummary();
                return 1;
            }

            parser.resolveLabels();
            if (reporter.getLevel() == .err) {
                reporter.showSummary();
                return 1;
            }

            reporter.showSummary();

            // TODO: Derive from `cli.filepath`
            const obj_path = "hw.obj";

            var file = try Io.Dir.cwd().createFile(io, obj_path, .{});
            defer file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = file.writer(io, &buffer);

            try air.emitWriter(&writer.interface);
            try writer.flush();
        },

        .emulate => {
            std.debug.print("todo: emulate\n", .{});
        },

        .assemble_emulate => {
            const source = try Io.Dir.cwd().readFileAlloc(io, cli.filepath, gpa, .unlimited);
            defer gpa.free(source);

            reporter.setSource(source);

            var air: lcz.Air = .init();
            defer air.deinit(gpa);

            var parser: lcz.Parser = .new(&air, &traps, source, &reporter);

            try parser.parse(gpa);
            if (reporter.getLevel() == .err) {
                reporter.showSummary();
                return 1;
            }

            parser.resolveLabels();
            if (reporter.getLevel() == .err) {
                reporter.showSummary();
                return 1;
            }

            reporter.showSummary();

            var write_buffer: [64]u8 = undefined;
            var writer = Io.File.stdout().writer(io, &write_buffer);
            var reader = Io.File.stdin().reader(io, &.{});

            var runtime = try lcz.Runtime.init(
                &traps,
                hooks,
                &policies,
                &writer.interface,
                &reader.interface,
                io,
                gpa,
            );
            defer runtime.deinit(gpa);

            try air.emitRuntime(&runtime);

            runtime.run() catch |err| switch (err) {
                error.WriteFailed,
                error.ReadFailed,
                error.TermiosFailed,
                => |err2| return err2,
                else => |err2| {
                    std.log.err("runtime threw exception: {t}", .{err2});
                },
            };

            try runtime.writer.ensureNewline();
            try runtime.writer.interface.flush();
        },
    }

    return 0;
}
