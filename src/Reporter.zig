const Reporter = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Token = @import("Token.zig");
const Span = @import("Span.zig");

const BUFFER_SIZE = 1024;

count: std.EnumArray(Level, usize),

file: Io.File,
buffer: [BUFFER_SIZE]u8,
writer: Io.File.Writer,

source: ?[]const u8,
io: Io,

const Level = enum { err, warn };

// TODO:
pub const Diagnostic = struct {
    string: []const u8,
    code: Token.Error,
};

pub fn new(io: Io) Reporter {
    return .{
        .count = .initFill(0),
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
    assert(reporter.source == null);
    reporter.source = source;
}

pub fn err(
    reporter: *Reporter,
    // TODO:
    code: anyerror,
    token: Span,
) error{Reported}!noreturn {
    reporter.count.getPtr(.err).* += 1;

    reporter.print("\x1b[31m", .{});
    reporter.print("Error: {t}", .{code});
    reporter.print("\x1b[0m", .{});
    reporter.print("\n", .{});

    const source = reporter.source orelse
        unreachable;

    reporter.print("\x1b[33m", .{});
    reporter.print("  - Token: ", .{});
    reporter.print("\x1b[0m", .{});
    reporter.print("\x1b[3m", .{});
    reporter.print("{s}", .{token.resolve(source)});
    reporter.print("\x1b[0m", .{});
    reporter.print("\n", .{});

    reporter.print("\n", .{});

    reporter.flush();

    return error.Reported;
}

pub fn summary(reporter: *Reporter) ?Level {
    const count_err = reporter.count.get(.err);
    const count_warn = reporter.count.get(.warn);

    if (count_err > 0) {
        reporter.print("\x1b[31m", .{});
        reporter.print("{} errors", .{count_err});
        reporter.print("\x1b[0m", .{});
        reporter.print("\n", .{});
    }

    if (count_warn > 0) {
        reporter.print("\x1b[33m", .{});
        reporter.print("{} warnings", .{count_warn});
        reporter.print("\x1b[0m", .{});
        reporter.print("\n", .{});
    }

    reporter.flush();

    if (count_err > 0)
        return .err;
    if (count_warn > 0)
        return .warn;
    return null;
}

fn print(reporter: *Reporter, comptime fmt: []const u8, args: anytype) void {
    reporter.writer.interface.print(fmt, args) catch
        std.debug.panic("failed to write to reporter file", .{});
}

fn flush(reporter: *Reporter) void {
    reporter.writer.interface.flush() catch
        std.debug.panic("failed to flush reporter file", .{});
}
