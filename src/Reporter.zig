const Reporter = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Token = @import("Token.zig");
const Span = @import("Span.zig");

const BUFFER_SIZE = 1024;

// TODO: Group as `Options`
strictness: Strictness,
verbosity: Verbosity,

source: ?[]const u8,
count: std.EnumArray(Level, usize),

file: Io.File,
buffer: [BUFFER_SIZE]u8,
writer: Io.File.Writer,
io: Io,

const Level = enum { err, warn };

// TODO: Rename
pub const Strictness = enum {
    strict,
    normal,
    relaxed,

    fn standardResponse(strictness: Strictness) Response {
        return switch (strictness) {
            .strict => .major,
            .normal => .minor,
            .relaxed => .pass,
        };
    }
};

pub const Verbosity = enum {
    verbose,
    normal,
    quiet,
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
        expected: []const TokenKinds.Kind,
    },
    unexpected_token: struct {
        token: Token,
    },
    invalid_token: struct {
        token: Span,
        // TODO: Rename
        kind: ?TokenKinds.Kind,
    },
    unknown_directive: struct {
        directive: Span,
    },
    unmatched_quote: struct {
        string: Span,
    },
    unexpected_negative_integer: struct {
        integer: Span,
    },
    integer_too_large: struct {
        integer: Span,
        bits: u16,
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

    generic_debug: struct {
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
        .strictness = .normal,
        .verbosity = .normal,
        .source = null,
        .count = .initFill(0),
        .file = undefined,
        .buffer = undefined,
        .writer = undefined,
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

pub fn setStrictness(reporter: *Reporter, strictness: Strictness) void {
    reporter.strictness = strictness;
}
pub fn setVerbosity(reporter: *Reporter, verbosity: Verbosity) void {
    reporter.verbosity = verbosity;
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
        .missing_origin => reporter.strictness.standardResponse(),
        .multiple_origins => .fatal,
        .late_origin => .fatal,
        .missing_end => reporter.strictness.standardResponse(),
        .duplicate_label => .fatal,
        .unexpected_label => .major,
        .shadowed_label => reporter.strictness.standardResponse(),
        .useless_label => reporter.strictness.standardResponse(),
        .eof_label => reporter.strictness.standardResponse(),
        .undeclared_label => .fatal,
        .offset_too_large => .fatal,
        .unexpected_token_kind => .fatal,
        .unexpected_token => .fatal,
        .invalid_token => .fatal,
        .unknown_directive => .fatal,
        .unmatched_quote => .fatal,
        .unexpected_negative_integer => .fatal,
        .integer_too_large => .fatal,
        .invalid_string_escape => reporter.strictness.standardResponse(),
        .multiline_string => reporter.strictness.standardResponse(),
        .nonstandard_integer_radix => reporter.strictness.standardResponse(),

        .generic_debug => .fatal,
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
                "Origin should be declared before any instructions",
                .{},
                info.first_token orelse .firstCharOf(source),
            );
        },
        .multiple_origins => |info| {
            ctx.printTitle("Multiple .ORIG directives", .{});
            ctx.deepen().printSourceNote("First declared here", .{}, info.existing);
            ctx.deepen().printSourceNote("Tried to redeclare here", .{}, info.new);
        },
        .late_origin => |info| {
            ctx.printTitle("Origin declared after statements", .{});
            ctx.deepen().printSourceNote("Origin declared here", .{}, info.origin);
            ctx.deepen().printSourceNote(
                "Origin must be declared at start of file",
                .{},
                info.first_token orelse .firstCharOf(source),
            );
        },
        .missing_end => |info| {
            ctx.printTitle("Missing .END directive", .{});
            ctx.deepen().printSourceNote(
                "End should be declared after included all instructions",
                .{},
                info.last_token orelse .lastCharOf(source),
            );
        },
        .duplicate_label => |info| {
            ctx.printTitle("Label already declared", .{});
            ctx.deepen().printSourceNote("Label is first declared here", .{}, info.existing);
            ctx.deepen().printSourceNote("Tried to redeclare here", .{}, info.new);
        },
        .unexpected_label => |info| {
            ctx.printTitle("Multiple labels cannot be declared on the same line", .{});
            ctx.deepen().printSourceNote("First label declared here", .{}, info.existing);
            ctx.deepen().printSourceNote("Another label declared on the same line", .{}, info.new);
        },
        .shadowed_label => |info| {
            ctx.printTitle("Shadowed label has no use", .{});
            ctx.deepen().printSourceNote("First label declared here", .{}, info.existing);
            ctx.deepen().printSourceNote("Another label declared in the same position", .{}, info.new);
        },
        .useless_label => |info| {
            ctx.printTitle("Label is useless in this position", .{});
            ctx.deepen().printSourceNote("Label declared here", .{}, info.label);
            ctx.deepen().printSourceNote("Token cannot be annotated with label", .{}, info.token);
        },
        .undeclared_label => |info| {
            ctx.printTitle("Label is not declared", .{});
            ctx.deepen().printSourceNote("Label used here", .{}, info.label);
        },
        .offset_too_large => |info| {
            ctx.printTitle("Label offset is too large", .{});
            ctx.deepen().printSourceNote("Label declared here", .{}, info.definition);
            ctx.deepen().printSourceNote("Label used here", .{}, info.reference);
        },
        .eof_label => |info| {
            ctx.printTitle("Label is useless in this position", .{});
            ctx.deepen().printSourceNote("Label declared here", .{}, info.label);
            ctx.deepen().printSourceNote(
                "Label is not followed by any token",
                .{},
                .lastCharOf(source),
            );
        },
        .unexpected_token_kind => |info| {
            ctx.printTitle("Unexpected {s}", .{TokenKinds.name(info.token.value)});
            ctx.deepen().printSourceNote("Token", .{}, info.token.span);
            ctx.deepen().printNote("Expected {f}", .{TokenKinds{ .kinds = info.expected }});
        },
        .unexpected_token => |info| {
            ctx.printTitle("Unexpected {s}", .{TokenKinds.name(info.token.value)});
            ctx.deepen().printSourceNote("Token", .{}, info.token.span);
            ctx.deepen().printNote("Expected end of line", .{});
        },
        .invalid_token => |info| {
            ctx.printTitle("Invalid token", .{});
            ctx.deepen().printSourceNote("Token", .{}, info.token);
            if (info.kind) |kind|
                ctx.deepen().printNote("Cannot parse as {s}", .{TokenKinds.name(kind)})
            else
                ctx.deepen().printNote("Cannot parse as any valid token", .{});
        },
        .unknown_directive => |info| {
            ctx.printTitle("Directive is not supported", .{});
            ctx.deepen().printSourceNote("Tried to use directive here", .{}, info.directive);
        },
        .unmatched_quote => |info| {
            ctx.printTitle("String literal does not end with quote `\"`", .{});
            ctx.deepen().printSourceNote("String is used here", .{}, info.string);
            ctx.deepen().printNote("Strings do not automatically stop at end of line", .{});
        },
        .unexpected_negative_integer => |info| {
            ctx.printTitle("Integer operand cannot be negative", .{});
            ctx.deepen().printSourceNote("Operand ", .{}, info.integer);
        },
        .integer_too_large => |info| {
            ctx.printTitle("Integer operand is too large", .{});
            ctx.deepen().printSourceNote("Operand ", .{}, info.integer);
            ctx.deepen().printNote("Value cannot be represented in {} bits", .{info.bits});
        },
        .invalid_string_escape => |info| {
            ctx.printTitle("Invalid escape sequence", .{});
            ctx.deepen().printSourceNote("String ", .{}, info.string);
            ctx.deepen().printSourceNote("Erroneous escape sequence ", .{}, info.sequence);
        },
        .multiline_string => |info| {
            ctx.printTitle("String covers multiple lines", .{});
            ctx.deepen().printSourceNote("String ", .{}, info.string);
        },
        .nonstandard_integer_radix => |info| {
            ctx.printTitle("Integer uses nonstandard radix '{t}'", .{info.radix});
            ctx.deepen().printSourceNote("Integer ", .{}, info.integer);
        },

        .generic_debug => |info| {
            ctx.printTitle("Generic error '{t}'", .{info.code});
            ctx.deepen().printSourceNote("Token ", .{}, info.span);
        },
    }

    switch (ctx.reporter.verbosity) {
        .verbose, .normal => {
            ctx.print("\n", .{});
        },
        .quiet => {},
    }

    ctx.flush();

    assert(response != .pass);
    return response;
}

const TokenKinds = struct {
    kinds: []const Kind,

    const Kind = std.meta.Tag(Token.Value);

    pub fn format(self: *const @This(), writer: *Io.Writer) !void {
        for (self.kinds, 0..) |kind, i| {
            if (i > 0) {
                if (i + 1 >= self.kinds.len)
                    try writer.print(", or ", .{})
                else
                    try writer.print(", ", .{});
            }

            try writer.print("{s}", .{name(kind)});
        }
    }

    pub fn name(kind: Kind) []const u8 {
        return switch (kind) {
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
};

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

        switch (ctx.reporter.verbosity) {
            .verbose, .normal => {
                ctx.print("\n", .{});
            },
            .quiet => {},
        }
    }

    pub fn printNote(ctx: Ctx, comptime fmt: []const u8, args: anytype) void {
        switch (ctx.reporter.verbosity) {
            .verbose, .normal => {},
            .quiet => return,
        }

        ctx.printDepth();
        ctx.print("\x1b[36m", .{});
        ctx.print("Note: ", .{});
        ctx.print("\x1b[0m", .{});
        ctx.print(fmt, args);
        ctx.print("\n", .{});
    }

    pub fn printSourceNote(
        ctx: Ctx,
        comptime fmt: []const u8,
        args: anytype,
        span: Span,
    ) void {
        ctx.printNote(fmt ++ ": ", args);
        ctx.printSource(span);
    }

    fn printSource(ctx: Ctx, span: Span) void {
        const source = ctx.reporter.source orelse
            unreachable;

        switch (ctx.reporter.verbosity) {
            .verbose, .normal => {},
            .quiet => {
                const line_number = span.getLineNumber(source);
                ctx.print(" (Line {})", .{line_number});
                ctx.print("\n", .{});
                return;
            },
        }

        const lines = span.getSurroundingLines(source);
        var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
        while (iter.next()) |line_string| {
            const line = Span.fromSlice(line_string, source);
            const line_number = line.getLineNumber(source);

            ctx.printDepth();
            ctx.print("\x1b[2m", .{});
            ctx.print("{:3} ", .{line_number});
            ctx.print("| ", .{});
            ctx.print("\x1b[0m", .{});
            ctx.print("\x1b[3m", .{});
            ctx.print("\x1b[2m", .{});

            {
                var was_in_span = false;
                for (line_string, 0..) |char, i| {
                    const index = line.offset + i;
                    const in_span = span.containsIndex(index);
                    if (in_span and !was_in_span)
                        ctx.print("\x1b[22m", .{})
                    else if (!in_span and was_in_span)
                        ctx.print("\x1b[2m", .{});
                    ctx.print("{c}", .{char});
                    was_in_span = in_span;
                }
            }

            ctx.print("\x1b[0m", .{});
            ctx.print("\n", .{});

            if (!line.overlaps(span) or
                std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0)
            {
                continue;
            }

            ctx.printDepth();
            ctx.print("\x1b[2m", .{});
            ctx.print("    | ", .{});
            ctx.print("\x1b[22m", .{});
            ctx.print("\x1b[36m", .{});
            for (0..line_string.len) |i| {
                const index = line.offset + i;
                if (span.containsIndex(index))
                    ctx.print("^", .{})
                else
                    ctx.print(" ", .{});
            }
            ctx.print("\x1b[0m", .{});
            ctx.print("\n", .{});
        }
    }
};
