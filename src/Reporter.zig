const Reporter = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Token = @import("Token.zig");
const Span = @import("Span.zig");

const BUFFER_SIZE = 1024;

count: std.EnumArray(Level, usize),
mode: Mode,

file: Io.File,
buffer: [BUFFER_SIZE]u8,
writer: Io.File.Writer,

source: ?[]const u8,
io: Io,

const Level = enum { err, warn };

pub const Mode = enum {
    strict,
    normal,
    quiet,

    fn standardResponse(mode: Mode) Response {
        return switch (mode) {
            .strict => .major,
            .normal => .minor,
            .quiet => .pass,
        };
    }
};

pub const Diagnostic = union(enum) {
    missing_origin: struct {
        first_token: ?Span,
    },
    multiple_origins: struct {
        existing: Span,
        new: Span,
    },
    late_origin: struct {
        origin: Span,
        first_token: ?Span,
    },
    missing_end: struct {
        last_token: ?Span,
    },
    duplicate_label: struct {
        existing: Span,
        new: Span,
    },
    unexpected_label: struct {
        existing: Span,
        new: Span,
    },
    shadowed_label: struct {
        existing: Span,
        new: Span,
    },
    useless_label: struct {
        label: Span,
        token: Span,
    },
    undeclared_label: struct {
        label: Span,
    },
    offset_too_large: struct {
        definition: Span,
        reference: Span,
        // TODO: Add offset value
    },
    eof_label: struct {
        label: Span,
    },
    unexpected_token_kind: struct {
        token: Token,
    },
    unexpected_token: struct {
        token: Token,
    },
    unexpected_negative_integer: struct {
        integer: Span,
    },
    invalid_string_escape: struct {
        string: Span,
        sequence: Span,
    },
    multiline_string: struct {
        string: Span,
    },
    nonstandard_integer_radix: struct {
        integer: Span,
        radix: @import("integers.zig").Radix,
    },

    // TODO:
    generic: struct {
        code: anyerror,
        span: Span,
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

pub fn new(io: Io) Reporter {
    return .{
        .count = .initFill(0),
        .mode = .normal,
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

pub fn setMode(reporter: *Reporter, mode: Mode) void {
    reporter.mode = mode;
}

pub fn endSection(reporter: *Reporter) ?Level {
    const count_err = reporter.count.get(.err);
    const count_warn = reporter.count.get(.warn);

    const ctx: Ctx = .new(reporter, .warn);

    if (count_err > 0) {
        ctx.print("\x1b[31m", .{});
        ctx.print("{} errors", .{count_err});
        ctx.print("\x1b[0m", .{});
        ctx.print("\n", .{});
    }

    if (count_warn > 0) {
        ctx.print("\x1b[33m", .{});
        ctx.print("{} warnings", .{count_warn});
        ctx.print("\x1b[0m", .{});
        ctx.print("\n", .{});
    }

    ctx.flush();

    if (count_err > 0)
        return .err;
    if (count_warn > 0)
        return .warn;
    return null;
}

pub fn report(
    reporter: *Reporter,
    comptime tag: std.meta.Tag(Diagnostic),
    info: @FieldType(Diagnostic, @tagName(tag)),
) Response {
    return reporter.reportInner(@unionInit(Diagnostic, @tagName(tag), info));
}

fn reportInner(reporter: *Reporter, diag: Diagnostic) Response {
    const response: Response = switch (diag) {
        .missing_origin => reporter.mode.standardResponse(),
        .multiple_origins => .fatal,
        .late_origin => .fatal,
        .missing_end => reporter.mode.standardResponse(),
        .duplicate_label => .fatal,
        .unexpected_label => .major,
        .shadowed_label => reporter.mode.standardResponse(),
        .useless_label => reporter.mode.standardResponse(),
        .eof_label => reporter.mode.standardResponse(),
        .undeclared_label => .fatal,
        .offset_too_large => .fatal,
        .unexpected_token_kind => .fatal,
        .unexpected_token => .fatal,
        .unexpected_negative_integer => .fatal,
        .invalid_string_escape => reporter.mode.standardResponse(),
        .multiline_string => reporter.mode.standardResponse(),
        .nonstandard_integer_radix => reporter.mode.standardResponse(),

        .generic => .fatal,
    };

    const level: Level = switch (response) {
        .fatal, .major => .err,
        .minor => .warn,
        .pass => return .pass,
    };

    reporter.count.getPtr(level).* += 1;

    const ctx: Ctx = .new(reporter, level);
    const source = reporter.source orelse
        unreachable;

    switch (diag) {
        .missing_origin => |info| {
            ctx.printTitle("Missing .ORIG directive", .{});
            ctx.deepen().printSourceNote(
                "Origin should be declared before any instructions:",
                info.first_token orelse .firstCharOf(source),
            );
        },
        .multiple_origins => |info| {
            ctx.printTitle("Multiple .ORIG directives", .{});
            ctx.deepen().printSourceNote("First declared here:", info.existing);
            ctx.deepen().printSourceNote("Tried to redeclare here:", info.new);
        },
        .late_origin => |info| {
            ctx.printTitle("Origin declared after statements", .{});
            ctx.deepen().printSourceNote("Origin declared here:", info.origin);
            ctx.deepen().printSourceNote(
                "Origin must be declared at start of file",
                info.first_token orelse .firstCharOf(source),
            );
        },
        .missing_end => |info| {
            ctx.printTitle("Missing .END directive", .{});
            ctx.deepen().printSourceNote(
                "End should be declared after included all instructions:",
                info.last_token orelse .lastCharOf(source),
            );
        },
        .duplicate_label => |info| {
            ctx.printTitle("Label already declared", .{});
            ctx.deepen().printSourceNote("Label is first declared here:", info.existing);
            ctx.deepen().printSourceNote("Tried to redeclare here:", info.new);
        },
        .unexpected_label => |info| {
            ctx.printTitle("Multiple labels cannot be declared on the same line", .{});
            ctx.deepen().printSourceNote("First label declared here:", info.existing);
            ctx.deepen().printSourceNote("Another label declared on the same line:", info.new);
        },
        .shadowed_label => |info| {
            ctx.printTitle("Shadowed label has no use", .{});
            ctx.deepen().printSourceNote("First label declared here:", info.existing);
            ctx.deepen().printSourceNote("Another label declared in the same position:", info.new);
        },
        .useless_label => |info| {
            ctx.printTitle("Label is useless in this position", .{});
            ctx.deepen().printSourceNote("Label declared here:", info.label);
            ctx.deepen().printSourceNote("Token cannot be annotated with label", info.token);
        },
        .undeclared_label => |info| {
            ctx.printTitle("Label is not declared", .{});
            ctx.deepen().printSourceNote("Label used here:", info.label);
        },
        .offset_too_large => |info| {
            ctx.printTitle("Label offset is too large", .{});
            ctx.deepen().printSourceNote("Label declared here:", info.definition);
            ctx.deepen().printSourceNote("Label used here:", info.reference);
        },
        .eof_label => |info| {
            ctx.printTitle("Label is useless in this position", .{});
            ctx.deepen().printSourceNote("Label declared here:", info.label);
            ctx.deepen().printSourceNote(
                "Label is not followed by any token",
                .lastCharOf(source),
            );
        },
        .unexpected_token_kind => |info| {
            ctx.printTitle("Unexpected {s}", .{tokenKind(info.token)});
            ctx.deepen().printSourceNote("Token:", info.token.span);
            ctx.deepen().printNote("Expected label, instruction, or directive");
        },
        .unexpected_token => |info| {
            ctx.printTitle("Unexpected {s}", .{tokenKind(info.token)});
            ctx.deepen().printSourceNote("Token:", info.token.span);
            ctx.deepen().printNote("Expected end of line");
        },
        .unexpected_negative_integer => |info| {
            ctx.printTitle("Integer operand cannot be negative", .{});
            ctx.deepen().printSourceNote("Operand: ", info.integer);
        },
        .invalid_string_escape => |info| {
            ctx.printTitle("Invalid escape sequence", .{});
            ctx.deepen().printSourceNote("String: ", info.string);
            ctx.deepen().printSourceNote("Erroneous escape sequence: ", info.sequence);
        },
        .multiline_string => |info| {
            ctx.printTitle("String covers multiple lines", .{});
            ctx.deepen().printSourceNote("String: ", info.string);
        },
        .nonstandard_integer_radix => |info| {
            ctx.printTitle("Integer uses nonstandard radix '{t}'", .{info.radix});
            ctx.deepen().printSourceNote("Integer: ", info.integer);
        },

        .generic => |info| {
            ctx.printTitle("Generic error: '{t}'", .{info.code});
            ctx.deepen().printSourceNote("Token: ", info.span);
        },
    }

    ctx.flush();

    assert(response != .pass);
    return response;
}

fn tokenKind(token: Token) []const u8 {
    return switch (token.value) {
        .newline => "newline",
        .comma => "comma `,`",
        .colon => "colon `:`",
        .directive => "directive",
        .instruction => "instruction",
        .label => "label",
        .register => "register",
        .integer => "integer literal",
        .string => "string literal",
    };
}

const Ctx = struct {
    reporter: *Reporter,
    level: ?Level,
    depth: usize,
    // TODO: Add color/style fields

    pub fn new(reporter: *Reporter, level: ?Level) Ctx {
        return .{
            .reporter = reporter,
            .level = level,
            .depth = 0,
        };
    }

    pub fn print(ctx: Ctx, comptime fmt: []const u8, args: anytype) void {
        ctx.reporter.writer.interface.print(fmt, args) catch
            std.debug.panic("failed to write to reporter file", .{});
    }

    pub fn flush(ctx: Ctx) void {
        ctx.reporter.writer.interface.flush() catch
            std.debug.panic("failed to flush reporter file", .{});
    }

    // TODO: Rename
    pub fn deepen(ctx: Ctx) Ctx {
        var new_ctx = ctx;
        new_ctx.depth += 1;
        return new_ctx;
    }

    fn printDepth(ctx: Ctx) void {
        for (0..ctx.depth) |_|
            ctx.print(" " ** 4, .{});
    }

    pub fn printTitle(
        ctx: *const Ctx,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const level = ctx.level orelse
            unreachable;
        ctx.printDepth();
        switch (level) {
            .err => {
                ctx.print("\x1b[31m", .{});
                ctx.print("\x1b[1m", .{});
                ctx.print("Error: ", .{});
                ctx.print("\x1b[0m", .{});
            },
            .warn => {
                ctx.print("\x1b[33m", .{});
                ctx.print("\x1b[1m", .{});
                ctx.print("Warning: ", .{});
                ctx.print("\x1b[0m", .{});
            },
        }
        ctx.print(fmt, args);
        ctx.print("\n", .{});
    }

    pub fn printNote(ctx: Ctx, note: []const u8) void {
        ctx.printDepth();
        ctx.print("\x1b[36m", .{});
        ctx.print("Note: ", .{});
        ctx.print("\x1b[0m", .{});
        ctx.print("{s}", .{note});
        ctx.print("\n", .{});
    }

    pub fn printSourceNote(ctx: Ctx, note: []const u8, span: Span) void {
        ctx.printNote(note);
        ctx.deepen().printSource(span);
    }

    fn printSource(ctx: Ctx, span: Span) void {
        const source = ctx.reporter.source orelse
            unreachable;

        const lines = span.getContainingLines(source);
        var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
        while (iter.next()) |line_string| {
            const line = Span.fromSlice(line_string, source);

            // TODO: Print line numbers
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
};
