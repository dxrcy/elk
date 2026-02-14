const std = @import("std");
const Io = std.Io;

const Air = @import("Air.zig");
const Parser = @import("Parser.zig");
const Reporter = @import("Reporter.zig");

pub fn main(init: std.process.Init) !void {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    var air: Air = .init(gpa);
    defer air.deinit();

    var parser: Parser = .new(&air, source, &reporter);

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

    // if (false) //
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

    if (reporter.summary() == .err) {
        std.log.info("stop", .{});
        return;
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
