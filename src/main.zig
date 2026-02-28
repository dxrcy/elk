const std = @import("std");
const Io = std.Io;

const Reporter = @import("report/Reporter.zig");
const Air = @import("compile/Air.zig");
const Parser = @import("compile/parse/Parser.zig");
const Runtime = @import("emulate/Runtime.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const asm_path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, asm_path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    // reporter.options.strictness = .normal;
    // reporter.options.verbosity = .normal;
    reporter.options.policies = &.config_lace;

    var air: Air = .init();
    defer air.deinit(gpa);

    var parser: Parser = .new(&air, .new(source, &reporter));

    try parser.parse(gpa);

    parser.resolveLabels();

    {
        if (reporter.endSection() == .err) {
            std.log.info("stop", .{});
            return 1;
        }
    }

    {
        const bin_path = "hw.obj";

        var file = try Io.Dir.cwd().createFile(io, bin_path, .{});
        defer file.close(io);

        var buffer: [512]u8 = undefined;
        var writer = file.writer(io, &buffer);

        try air.emitWriter(&writer.interface);
        try writer.flush();
    }

    {
        const trap_table: Runtime.traps.Table = .default;

        var write_buffer: [64]u8 = undefined;
        var runtime = try Runtime.init(&trap_table, &write_buffer, io, gpa);
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
    }

    return 0;
}

comptime {
    std.testing.refAllDecls(@This());
}
