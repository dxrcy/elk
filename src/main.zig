const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
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

    var air: Air = .new(gpa);

    var parser: Parser = .{
        .air = &air,
        .tokens = Tokenizer.new(source),
        .source = source,
        .reporter = &reporter,
    };

    defer {
        air.lines.deinit(air.allocator);
    }

    try parser.parse();

    {
        var was_raw_word = false;
        for (air.lines.items) |line| {
            const concise = line.statement == .raw_word and was_raw_word and line.label == null;
            if (!concise)
                std.debug.print("\n[{s}]", .{line.span.resolve(source)});
            if (line.label) |label| {
                std.debug.print(" \"{s}\"", .{label.resolve(source)});
            }
            if (!concise)
                std.debug.print("\n", .{});
            std.debug.print("{f}", .{line.statement});
            was_raw_word = line.statement == .raw_word;
        }
        std.debug.print("\n", .{});
    }
}

const ArrayList = std.ArrayList;

const Air = struct {
    origin: ?u16,

    lines: ArrayList(Line),
    allocator: Allocator,

    pub const Line = struct {
        label: ?Span,
        statement: Statement,
        span: Span,

        pub const Statement = union(enum) {
            raw_word: u16,

            add: struct {
                dest: Register,
                src_a: Register,
                src_b: RegisterOrImmediate,
            },

            lea: struct {
                dest: Register,
                src: Label,
            },

            trap: struct {
                vect: TrapVect,
            },

            pub const Register = u3;

            // TODO: Rename
            pub const RegisterOrImmediate = union(enum) {
                register: Register,
                immediate: u5,
            };

            // TODO: Use Span
            const Label = []const u8;

            const TrapVect = u8;

            pub fn format(statement: Statement, writer: *Io.Writer) !void {
                inline for (@typeInfo(Statement).@"union".fields) |tag| {
                    if (std.mem.eql(u8, @tagName(statement), tag.name)) {
                        const variant = @field(statement, tag.name);

                        if (@typeInfo(tag.type) == .@"struct") {
                            assert(statement != .raw_word);

                            for (tag.name) |char| {
                                try writer.print("{c}", .{std.ascii.toUpper(char)});
                            }
                            try writer.print(":\n", .{});

                            inline for (@typeInfo(tag.type).@"struct".fields) |field| {
                                try writer.print("{s:8} = ", .{field.name});
                                const value = @field(variant, field.name);
                                switch (field.type) {
                                    Register => try writer.print("Register: r{}", .{value}),
                                    Label => try writer.print("Label: [{s}]", .{value}),
                                    RegisterOrImmediate => {
                                        try writer.print("Register/Immediate: ", .{});
                                        switch (value) {
                                            .register => |register| try writer.print("r{}", .{register}),
                                            .immediate => |immediate| try writer.print("0x{x:02}", .{immediate}),
                                        }
                                    },
                                    TrapVect => try writer.print("Vect 0x{x:02}", .{value}),
                                    else => comptime unreachable,
                                }
                                try writer.print("\n", .{});
                            }
                        } else {
                            assert(statement == .raw_word);

                            try writer.print("0x{x:04}", .{variant});
                            if (variant > 0x7f) {
                                try writer.print(" (?)", .{});
                            } else switch (@as(u8, @intCast(variant))) {
                                '\n' => try writer.print(" '\\n'", .{}),
                                else => |char| try writer.print(" '{c}'", .{char}),
                            }
                            try writer.print("\n", .{});
                        }
                    }
                }
            }
        };
    };

    pub fn new(allocator: Allocator) Air {
        return .{
            .origin = null,
            .lines = .empty,
            .allocator = allocator,
        };
    }
};

const assert = std.debug.assert;

const Parser = struct {
    air: *Air,
    tokens: Tokenizer,
    source: []const u8,
    reporter: *Reporter,

    const Statement = Air.Line.Statement;

    pub fn parse(parser: *Parser) !void {
        var current_label: ?Span = null;

        while (true) {
            // TODO: Move loop contents to new methods
            // Handle `error.Reported` from method return in this loop

            const token = try nullIfReported(parser.nextToken()) orelse {
                parser.discardTokensInLine();
                continue;
            } orelse
                break;

            switch (token.kind) {
                .newline, .comma => continue,
                else => {},
            }

            switch (token.kind) {
                .label => {
                    if (current_label != null) {
                        parser.reporter.err(error.MultipleLabels, token.span);
                        continue;
                    }
                    current_label = token.span;
                    continue;
                },

                .instruction => |instruction| {
                    const statement = try parser.parseInstruction(instruction) orelse
                        continue;

                    const span: Span = .fromBounds(
                        token.span.offset,
                        parser.tokens.index,
                    );

                    try parser.appendLine(&current_label, statement, span);

                    continue; // TODO:
                },

                .directive => |directive| {
                    switch (directive) {
                        .orig => {
                            const origin = try parser.expectTokenKind(.integer);
                            if (parser.air.lines.items.len > 0) {
                                parser.reporter.err(error.LateOrigin, origin.span);
                                continue;
                            }
                            if (parser.air.origin != null) {
                                parser.reporter.err(error.MultipleOrigins, origin.span);
                                continue;
                            }
                            parser.air.origin = origin.value;
                            continue;
                        },

                        .end => return,

                        .stringz => {
                            const string = try parser.expectTokenKind(.string);
                            var is_escaped = false;
                            for (string.value) |char| {
                                if (!is_escaped and char == '\\') {
                                    is_escaped = true;
                                    continue;
                                }
                                const char_escaped: u8 =
                                    if (!is_escaped) char else switch (char) {
                                        '\\' => '\\',
                                        '"' => '"',
                                        'n' => '\n',
                                        't' => '\t',
                                        'r' => '\r',
                                        else => {
                                            parser.reporter.err(error.InvalidEscapeSequence, string.span);
                                            is_escaped = false;
                                            continue;
                                        },
                                    };
                                is_escaped = false;
                                try parser.appendLine(
                                    &current_label,
                                    .{ .raw_word = char_escaped },
                                    string.span,
                                );
                            }

                            continue; // TODO:
                        },

                        // TODO:
                        else => {},
                    }
                },

                // TODO:
                else => {},
            }

            std.debug.print("warning: unhandled {t:<10} {s}\n", .{
                token.kind,
                if (token.kind == .newline)
                    ""
                else
                    token.span.resolve(parser.source),
            });
        }

        parser.reporter.err(error.ExpectedEnd, .emptyAt(parser.source.len));
    }

    fn appendLine(
        parser: *Parser,
        current_label: *?Span,
        statement: Statement,
        span: Span,
    ) !void {
        try parser.air.lines.append(parser.air.allocator, .{
            .label = current_label.*,
            .statement = statement,
            .span = span,
        });
        current_label.* = null;
    }

    fn parseInstruction(
        parser: *Parser,
        instruction: Token.Kind.Instruction,
    ) !?Statement {
        const regular_instructions = [_]Token.Kind.Instruction{
            .add,
            .lea,
        };
        const trap_instructions = [_]struct { Token.Kind.Instruction, Statement.TrapVect }{
            .{ .puts, 0x22 },
            .{ .halt, 0x25 },
        };

        inline for (regular_instructions) |regular| {
            if (instruction == regular) {
                const Payload = @FieldType(Statement, @tagName(regular));
                var payload: Payload = undefined;

                inline for (@typeInfo(Payload).@"struct".fields) |field| {
                    const kind = switch (field.type) {
                        Statement.Register => .register,
                        Statement.Label => .label,
                        Statement.RegisterOrImmediate => .register_or_immediate,
                        else => comptime unreachable,
                    };

                    const token = try nullIfReported(parser.expectTokenKind(kind)) orelse
                        return null;
                    @field(payload, field.name) = token.value;
                }

                return @unionInit(Statement, @tagName(regular), payload);
            }
        }

        inline for (trap_instructions) |pair| {
            const trap, const vect = pair;
            if (instruction == trap) {
                return .{ .trap = .{ .vect = vect } };
            }
        }

        // TODO: Replace with `unreachable` and to remove `?` from return type
        return null;
    }

    fn nextToken(parser: *Parser) error{Reported}!?Token {
        while (true) {
            const span = parser.tokens.next() orelse
                return null;
            const token = Token.from(span, parser.source) catch |err| {
                parser.reporter.err(err, span);
                return error.Reported;
            };
            switch (token.kind) {
                .comma => continue,
                else => return token,
            }
        }
    }

    fn expectToken(parser: *Parser) !Token {
        const token = try parser.nextToken() orelse {
            parser.reporter.err(error.UnexpectedEof, .emptyAt(parser.source.len));
            return error.Reported;
        };
        switch (token.kind) {
            .newline => {
                parser.reporter.err(error.UnexpectedEol, .emptyAt(token.span.offset));
                return error.Reported;
            },
            .comma => unreachable,
            else => return token,
        }
    }

    fn expectTokenKind(
        parser: *Parser,
        comptime kind: @EnumLiteral(),
    ) !struct {
        span: Span,
        value: ExpectTokenKind(kind),
    } {
        const token = try parser.expectToken();
        assert(token.kind != .comma);
        const value_opt: ?ExpectTokenKind(kind) = switch (kind) {
            .register => switch (token.kind) {
                .register => |register| register,
                else => null,
            },
            .label => switch (token.kind) {
                .label => |label| label,
                else => null,
            },
            .register_or_immediate => switch (token.kind) {
                .register => |register| .{ .register = register },
                // FIXME: Handle u16->u5 conversion fail
                // Token.integer needs to remember ORIGINAL SOURCE sign to
                // handle/avoid sign extension triggering conversion failure
                .integer => |integer| .{ .immediate = @intCast(integer) },
                else => null,
            },
            .string => switch (token.kind) {
                .string => |string| string,
                else => null,
            },
            .integer => switch (token.kind) {
                .integer => |integer| integer,
                else => null,
            },
            else => comptime unreachable,
        };
        const value = value_opt orelse {
            parser.reporter.err(error.UnexpectedTokenKind, token.span);
            return error.Reported;
        };
        return .{
            .span = token.span,
            .value = value,
        };
    }

    fn ExpectTokenKind(comptime kind: @EnumLiteral()) type {
        return switch (kind) {
            .register => Statement.Register,
            .label => Statement.Label,
            .register_or_immediate => Statement.RegisterOrImmediate,
            // TODO: Use span
            .string => []const u8,
            .integer => u16,
            else => @compileError("unsupported token kind `." ++ @tagName(kind) ++ "`"),
        };
    }

    // TODO: Rename
    fn discardTokensInLine(parser: *Parser) void {
        while (true) {
            const token = try nullIfReported(parser.nextToken()) orelse {
                continue; // Ignore
            } orelse
                break;
            if (token.kind == .newline)
                break;
        }
    }
};

// TODO: Rename
fn nullIfReported(result: anytype) !?@typeInfo(@TypeOf(result)).error_union.payload {
    const error_union = @typeInfo(@TypeOf(result)).error_union;
    const error_set = @typeInfo(error_union.error_set).error_set.?;

    if (error_set.len < 2) {
        return result catch |err| switch (err) {
            error.Reported => return null,
        };
    } else {
        return result catch |err| switch (err) {
            error.Reported => return,
            else => return null,
        };
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
