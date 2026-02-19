const std = @import("std");
const Io = std.Io;

const Air = @import("Air.zig");
const Parser = @import("Parser.zig");
const Reporter = @import("Reporter.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const asm_path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, asm_path, gpa, .unlimited);
    defer gpa.free(source);

    const mode: Reporter.Mode = .strict;

    reporter.setSource(source);
    reporter.setMode(mode);

    var air: Air = .init();
    defer air.deinit(gpa);

    var parser: Parser = .new(&air, source, &reporter, gpa);

    try parser.parse();

    if (false) //
    {
        var was_raw_word = false;
        for (air.lines.items, 0..) |line, i| {
            const concise =
                line.statement == .raw_word and
                was_raw_word and
                line.label == null;
            if (!concise)
                std.debug.print("\n", .{});
            if (line.label) |label| {
                std.debug.print("\"{s}\" ", .{label.view(source)});
            }
            if (!concise)
                std.debug.print("[{s}]\n", .{line.span.view(source)});
            std.debug.print("{f}", .{line.statement.format(&air, source, i)});
            was_raw_word = line.statement == .raw_word;
        }
        std.debug.print("\n", .{});
    }

    parser.resolveLabels();

    if (false) //
    {
        var was_raw_word = false;
        for (air.lines.items, 0..) |line, i| {
            const concise =
                line.statement == .raw_word and
                was_raw_word and
                line.label == null;
            if (!concise)
                std.debug.print("\n", .{});
            if (line.label) |label| {
                std.debug.print("\"{s}\" ", .{label.view(source)});
            }
            if (!concise)
                std.debug.print("[{s}]\n", .{line.span.view(source)});
            std.debug.print("{f}", .{line.statement.format(&air, source, i)});
            was_raw_word = line.statement == .raw_word;
        }
        std.debug.print("\n", .{});
    }

    // if (true) return;

    // if (false) //
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

        try air.emit(&writer.interface);
        try writer.flush();
    }

    return 0;
}

comptime {
    std.testing.refAllDecls(@This());
}
