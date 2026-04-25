const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Policies = @import("../policies.zig").Policies;
const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");

pub const Printer = @import("Printer.zig");
pub const Printerface = @import("Printerface.zig");

// TODO: Move or remove
pub const Primary = Reporter(@import("diagnostic.zig").Diagnostic);

pub const Level = enum(u2) {
    info = 1,
    warn = 2,
    err = 3,

    pub fn order(lhs: Level, rhs: Level) std.math.Order {
        return std.math.order(@intFromEnum(lhs), @intFromEnum(rhs));
    }
};

pub const Options = struct {
    policies: Policies = .none,
    strictness: Strictness = .default,
    verbosity: Verbosity = .default,

    pub const Strictness = enum {
        strict,
        normal,
        relaxed,
        pub const default: Strictness = .normal;
    };

    pub const Verbosity = enum {
        normal,
        quiet,
        pub const default: Verbosity = .normal;
    };
};

pub const Response = enum {
    /// Must be handled immediately.
    fatal,
    /// Must be handled in this pass.
    major,

    minor,
    info,
    pass,

    pub fn abort(response: Response) error{Reported}!noreturn {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .info, .pass => unreachable,
        };
    }
    pub fn collect(response: Response, result: *error{Reported}!void) void {
        return switch (response) {
            .fatal, .major => {
                result.* = error.Reported;
            },
            .minor, .info, .pass => {},
        };
    }
    pub fn handle(response: Response) error{Reported}!void {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .info, .pass => {},
        };
    }
    /// Callsites should document why `proceed` is used rather than `handle`.
    pub fn proceed(response: Response) void {
        switch (response) {
            .fatal => unreachable,
            .major, .minor, .info, .pass => {},
        }
    }
};

pub fn Reporter(comptime Diag: type) type {
    assert(@typeInfo(Diag).@"union".tag_type != null);

    return struct {
        const Self = @This();

        printer: Printerface,
        count: std.EnumArray(Level, usize),
        options: Options,
        source: ?[]const u8,

        pub fn new(printer: Printerface) Self {
            return .{
                .printer = printer,
                .count = .initFill(0),
                .options = .{},
                .source = null,
            };
        }

        fn writeFailed() noreturn {
            std.debug.panic("failed to write to reporter", .{});
        }

        pub fn report(
            reporter: *Self,
            comptime tag: std.meta.Tag(Diag),
            info: @FieldType(Diag, @tagName(tag)),
        ) Response {
            return reporter.reportInner(@unionInit(Diag, @tagName(tag), info)) catch
                writeFailed();
        }

        fn reportInner(reporter: *Self, diag: Diag) error{WriteFailed}!Response {
            const response: Response = diag.getResponse(reporter.options);

            const level: Level = switch (response) {
                .fatal, .major => .err,
                .minor => .warn,
                .info => .info,
                .pass => return .pass,
            };

            reporter.count.getPtr(level).* += 1;

            try reporter.printer.printDiagnostic(
                diag,
                level,
                reporter.options.verbosity,
                reporter.source orelse unreachable,
            );

            assert(response != .pass);
            return response;
        }

        pub fn summarize(reporter: *Self) void {
            reporter.summarizeInner() catch
                writeFailed();
        }

        fn summarizeInner(reporter: *Self) error{WriteFailed}!void {
            try reporter.printer.printSummary(
                &reporter.count,
                reporter.options.verbosity,
            );
        }

        pub fn getLevel(reporter: *const Self) ?Level {
            if (reporter.count.get(.err) > 0)
                return .err;
            if (reporter.count.get(.warn) > 0)
                return .warn;
            return null;
        }

        pub fn isLevelAtMost(reporter: *const Self, max: Level) bool {
            const level = reporter.getLevel() orelse
                return true;
            return level.order(max).compare(.lte);
        }
    };
}

pub fn writeSpanContext(
    writer: *std.Io.Writer,
    span: Span,
    config: struct {
        indent: usize = 0,
        max_context: usize = 1,
        max_line_width: usize = 80,
    },
    source: []const u8,
) error{WriteFailed}!void {
    const lines = span.getSurroundingLines(config.max_context, source);
    var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
    while (iter.next()) |line_string_full| {
        const line_string = line_string_full[0..@min(line_string_full.len, config.max_line_width)];
        const is_truncated = line_string_full.len > config.max_line_width;

        const line = Span.fromSlice(line_string, source);
        const line_number = line.getLineNumber(source);

        for (0..config.indent) |_|
            try writer.print(" ", .{});

        try writer.print("\x1b[2m", .{});
        try writer.print("{:3} ", .{line_number});
        try writer.print("| ", .{});
        try writer.print("\x1b[0m", .{});
        try writer.print("\x1b[3m", .{});
        try writer.print("\x1b[2m", .{});

        {
            var was_in_span = false;
            var was_non_valid = false;

            for (line_string, 0..) |char, i| {
                const index = line.offset + i;

                const in_span = span.containsIndex(index);
                if (in_span and !was_in_span)
                    try writer.print("\x1b[22m", .{})
                else if (!in_span and was_in_span)
                    try writer.print("\x1b[2m", .{});

                const non_valid = Token.isValidChar(char);
                if (!non_valid and was_non_valid)
                    try writer.print("\x1b[31m", .{})
                else if (non_valid and !was_non_valid)
                    try writer.print("\x1b[39m", .{});

                if (non_valid)
                    try writer.print("{c}", .{char})
                else
                    try writer.print("?", .{});

                was_in_span = in_span;
                was_non_valid = non_valid;
            }
        }

        if (is_truncated) {
            try writer.print("\x1b[0m", .{});
            try writer.print("\x1b[36;2m", .{});
            try writer.print("...", .{});
        }

        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});

        if (!line.overlaps(span) or
            std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0)
        {
            continue;
        }

        for (0..config.indent) |_|
            try writer.print(" ", .{});

        try writer.print("\x1b[2m", .{});
        try writer.print("    | ", .{});
        try writer.print("\x1b[22m", .{});
        try writer.print("\x1b[36m", .{});
        for (0..line_string.len + 1) |i| {
            const index = line.offset + i;
            if (span.containsIndex(index) or
                // Still highlight first character if len==0
                span.offset == index)
                try writer.print("^", .{})
            else
                try writer.print(" ", .{});
        }
        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});
    }
}
