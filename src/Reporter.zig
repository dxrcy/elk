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

// TODO: Rename to `Policy`
pub const Mode = enum {
    strict,
    normal,
    quiet,
};

const Level = enum { err, warn };

pub const Diagnostic = union(enum) {
    missing_origin,
    duplicate_label: struct {
        existing: Span,
        new: Span,
    },
};

pub const Response = enum {
    /// Must be handled immediately.
    fatal,
    /// Must be handled in this pass.
    major,

    minor,
    pass,

    pub fn abort(response: Response) error{Reported}!noreturn {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .pass => unreachable,
        };
    }
    pub fn handle(response: Response) error{Reported}!void {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .pass => {},
        };
    }
    pub fn proceed(response: Response) void {
        switch (response) {
            .fatal => unreachable,
            .major, .minor, .pass => {},
        }
    }
};

pub fn report(reporter: *Reporter, diag: Diagnostic) Response {
    const response: Response = switch (diag) {
        .missing_origin => switch (reporter.mode) {
            .strict => .major,
            .normal => .minor,
            .quiet => .pass,
        },
        .duplicate_label => .major,
    };

    const level: Level = switch (response) {
        .fatal, .major => .err,
        .minor => .warn,
        .pass => return .pass,
    };

    reporter.count.getPtr(level).* += 1;

    const ctx: Ctx = .{ .reporter = reporter, .level = level };

    switch (diag) {
        .missing_origin => {
            ctx.printTitle("Missing .ORIG directive");
        },
        .duplicate_label => |info| {
            ctx.printTitle("Label already declared");
            ctx.deepen().printNote("First declared here:", info.existing);
            ctx.deepen().printNote("Tried to redeclare here:", info.new);
        },
    }

    reporter.flush();

    assert(response != .pass);
    return response;
}

// TODO: Rename?
const Ctx = struct {
    reporter: *Reporter,
    level: Level,
    depth: usize = 0,

    // TODO: Rename
    pub fn deepen(ctx: Ctx) Ctx {
        var new_ctx = ctx;
        new_ctx.depth += 1;
        return new_ctx;
    }

    fn printDepth(ctx: Ctx) void {
        for (0..ctx.depth) |_|
            ctx.print("  ", .{});
    }

    fn printTitle(ctx: *const Ctx, title: []const u8) void {
        ctx.printDepth();

        switch (ctx.level) {
            .err => {
                ctx.print("\x1b[31m", .{});
                ctx.print("Error: ", .{});
                ctx.print("\x1b[0m", .{});
            },
            .warn => {
                ctx.print("\x1b[33m", .{});
                ctx.print("Warning: ", .{});
                ctx.print("\x1b[0m", .{});
            },
        }
        ctx.print("{s}", .{title});
        ctx.print("\n", .{});
    }

    fn printNote(ctx: Ctx, note: []const u8, span: Span) void {
        ctx.print("  " ** 1, .{});
        ctx.print("\x1b[36m", .{});
        ctx.print("Note: ", .{});
        ctx.print("\x1b[0m", .{});
        ctx.print("{s}", .{note});
        ctx.print("\n", .{});

        ctx.deepen().printSource(span);
    }

    fn printSource(ctx: Ctx, span: Span) void {
        const source = ctx.reporter.source orelse
            unreachable;

        const lines = span.getContainingLines(source);
        var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
        while (iter.next()) |line_string| {
            const line = Span.fromSlice(line_string, source);

            ctx.printDepth();
            ctx.print("\x1b[36m", .{});
            ctx.print("| ", .{});
            ctx.print("\x1b[0m", .{});
            ctx.print("\x1b[3m", .{});
            ctx.print("{s}", .{line_string});
            ctx.print("\x1b[0m", .{});
            ctx.print("\n", .{});

            if (std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0) {
                continue;
            }

            ctx.printDepth();
            ctx.print("\x1b[36m", .{});
            ctx.print("| ", .{});
            for (0..line_string.len) |i| {
                const index = line.offset + i;
                if (index >= span.offset and index < span.end()) {
                    ctx.print("^", .{});
                } else {
                    ctx.print(" ", .{});
                }
            }
            ctx.print("\x1b[0m", .{});
            ctx.print("\n", .{});
        }
    }

    fn print(ctx: Ctx, comptime fmt: []const u8, args: anytype) void {
        // TODO: Once this is the only callsite for `Reporter.print`, we can
        // inline it here and remove the reporter method.
        ctx.reporter.print(fmt, args);
    }
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

    reporter.printContextOld(token);

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

    reporter.printContextOld(token);

    reporter.flush();
}

pub const Category = enum {
    standard,
    extension,
};

// TODO: Rename
pub fn reportOld(
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

fn printContextOld(reporter: *Reporter, span: Span) void {
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
