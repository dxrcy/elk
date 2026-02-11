const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Tokenizer = @import("Tokenizer.zig");
const LineIterator = Tokenizer.LineIterator;
const Span = @import("Span.zig");
const Token = @import("Token.zig");

pub fn main(init: std.process.Init) !void {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    var lines: LineIterator = .new(source);
    while (lines.next()) |line| {
        const line_str = line.resolve(source);

        std.debug.print("-" ** 20 ++ "\n", .{});
        std.debug.print("[{s}]\n", .{line_str});

        var tokens = Tokenizer.new(line_str);
        while (tokens.next()) |span| {
            const string = span.resolve(line_str);
            std.debug.print("\t[{s}]", .{string});
            if (Token.from(span, line_str)) |token| {
                std.debug.print("\t{f}\n", .{token.kind});
            } else |err| {
                std.debug.print("\n", .{});
                reporter.err(err, line);
            }
        }

        std.debug.print("\n", .{});
    }
}

pub const Diagnostic = struct {
    string: []const u8,
    code: Token.Error,
};

pub const Reporter = struct {
    const BUFFER_SIZE = 1024;

    file: Io.File,
    buffer: [BUFFER_SIZE]u8,
    writer: Io.File.Writer,

    source: ?[]const u8,

    io: Io,

    pub fn new(io: Io) Reporter {
        return .{
            .file = undefined,
            .buffer = undefined,
            .writer = undefined,
            .source = null,
            .io = io,
        };
    }

    pub fn init(reporter: *Reporter) !void {
        reporter.file = std.Io.File.stderr();
        reporter.writer = reporter.file.writer(reporter.io, &reporter.buffer);
    }

    pub fn setSource(reporter: *Reporter, source: []const u8) void {
        std.debug.assert(reporter.source == null);
        reporter.source = source;
    }

    pub fn err(reporter: *Reporter, code: Token.Error, line: Span) void {
        reporter.print("\x1b[31m", .{});
        reporter.print("Error: {t}", .{code});
        reporter.print("\x1b[0m", .{});
        reporter.print("\n", .{});

        const source = reporter.source orelse
            unreachable;

        reporter.print("\x1b[33m", .{});
        reporter.print("Line: [{s}]", .{line.resolve(source)});
        reporter.print("\x1b[0m", .{});
        reporter.print("\n", .{});

        reporter.flush();
    }

    fn print(reporter: *Reporter, comptime fmt: []const u8, args: anytype) void {
        reporter.writer.interface.print(fmt, args) catch
            std.debug.panic("failed to write to reporter file", .{});
    }

    fn flush(reporter: *Reporter) void {
        reporter.writer.interface.flush() catch
            std.debug.panic("failed to flush reporter file", .{});
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
