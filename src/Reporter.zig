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

mode: Mode,

pub const Mode = enum {
    strict,
    normal,
    quiet,
};

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
        .mode = .normal,
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

pub fn setMode(reporter: *Reporter, mode: Mode) void {
    reporter.mode = mode;
}

pub fn err(
    reporter: *Reporter,
    // TODO:
    code: anyerror,
    token: Span,
) error{Reported}!noreturn {
    reporter.count.getPtr(.err).* += 1;

    reporter.print("\x1b[31m", .{});
    reporter.print("\x1b[1m", .{});
    reporter.print("Error:", .{});
    reporter.print("\x1b[22m", .{});
    reporter.print(" {t}", .{code});
    reporter.print("\x1b[0m", .{});
    reporter.print("\n", .{});

    reporter.printContext(token);

    reporter.flush();
    return error.Reported;
}

pub fn warn(
    reporter: *Reporter,
    code: anyerror,
    token: Span,
) void {
    reporter.count.getPtr(.warn).* += 1;

    reporter.print("\x1b[33m", .{});
    reporter.print("\x1b[1m", .{});
    reporter.print("Warning:", .{});
    reporter.print("\x1b[22m", .{});
    reporter.print(" {t}", .{code});
    reporter.print("\x1b[0m", .{});
    reporter.print("\n", .{});

    reporter.printContext(token);

    reporter.flush();
}

pub const Category = enum {
    standard,
    extension,
};

// TODO: Rename
pub fn report(
    reporter: *Reporter,
    category: Category,
    code: anyerror,
    token: Span,
) error{Reported}!void {
    switch (category) {
        .standard => switch (reporter.mode) {
            .strict => try reporter.err(code, token),
            .normal => reporter.warn(code, token),
            .quiet => {},
        },
        .extension => switch (reporter.mode) {
            .strict => try reporter.err(code, token),
            .normal => reporter.warn(code, token),
            .quiet => {},
        },
    }
}

fn printContext(reporter: *Reporter, span: Span) void {
    const source = reporter.source orelse
        unreachable;

    const lines = span.getContainingLines(source);
    var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
    while (iter.next()) |line_string| {
        const line = Span.fromSlice(line_string, source);

        reporter.print("\x1b[36m", .{});
        reporter.print("  | ", .{});
        reporter.print("\x1b[0m", .{});
        reporter.print("\x1b[3m", .{});
        reporter.print("{s}", .{line_string});
        reporter.print("\x1b[0m", .{});
        reporter.print("\n", .{});

        if (std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0) {
            continue;
        }

        reporter.print("\x1b[36m", .{});
        reporter.print("  | ", .{});
        for (0..line_string.len) |i| {
            const index = line.offset + i;
            if (index >= span.offset and index < span.end()) {
                reporter.print("^", .{});
            } else {
                reporter.print(" ", .{});
            }
        }
        reporter.print("\x1b[0m", .{});
        reporter.print("\n", .{});
    }
}

pub fn endSection(reporter: *Reporter) ?Level {
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
