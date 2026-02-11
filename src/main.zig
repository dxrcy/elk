const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Tokenizer = @import("Tokenizer.zig");
const LineIterator = Tokenizer.LineIterator;
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Reporter = @import("Reporter.zig");

pub fn main(init: std.process.Init) !void {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    var tokens = Tokenizer.new(source);
    while (tokens.next()) |span| {
        const token_str = span.resolve(source);
        std.debug.print("\t[{s}]", .{token_str});

        const token = Token.from(span, source) catch |err| {
            std.debug.print("\n", .{});
            reporter.err(err, span);
            continue;
        };

        std.debug.print("\t{f}\n", .{token.kind});
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
