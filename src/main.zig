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

    var air: Air = .init(gpa);
    defer air.deinit();

    {
        var parser: Parser = .new(&air, source, &reporter);
        try parser.parse();
    }

    {
        var was_raw_word = false;
        for (air.lines.items) |line| {
            const concise =
                line.statement == .raw_word and
                was_raw_word and
                line.label == null;
            if (!concise)
                std.debug.print("\n", .{});
            if (line.label) |label| {
                std.debug.print("\"{s}\" ", .{label.resolve(source)});
            }
            if (!concise)
                std.debug.print("[{s}]\n", .{line.span.resolve(source)});
            std.debug.print("{f}", .{line.statement.format(source)});
            was_raw_word = line.statement == .raw_word;
        }
        std.debug.print("\n", .{});
    }
}

const ArrayList = std.ArrayList;

const Integer = @import("integers.zig").Integer;

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
                src_b: RegImm5,
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
            pub const RegImm5 = union(enum) {
                register: Register,
                immediate: u5,
            };

            const Label = union(enum) {
                unresolved: Span,
                index: u16,
            };

            const TrapVect = u8;

            pub fn format(statement: Statement, source: []const u8) Format {
                return .{
                    .statement = statement,
                    .source = source,
                };
            }

            pub const Format = struct {
                statement: Statement,
                source: []const u8,

                pub fn format(self: Format, writer: *Io.Writer) !void {
                    inline for (@typeInfo(Statement).@"union".fields) |tag| {
                        if (std.mem.eql(u8, @tagName(self.statement), tag.name)) {
                            const variant = @field(self.statement, tag.name);

                            if (@typeInfo(tag.type) == .@"struct") {
                                assert(self.statement != .raw_word);

                                for (tag.name) |char| {
                                    try writer.print("{c}", .{std.ascii.toUpper(char)});
                                }
                                try writer.print(":\n", .{});

                                inline for (@typeInfo(tag.type).@"struct".fields) |field| {
                                    try writer.print("{s:8}: ", .{field.name});
                                    const value = @field(variant, field.name);
                                    switch (field.type) {
                                        Register => try writer.print("Register = r{}", .{value}),
                                        Label => {
                                            try writer.print("Label = ", .{});
                                            switch (value) {
                                                .unresolved => |span| try writer.print("\"{s}\"", .{span.resolve(self.source)}),
                                                .index => |index| try writer.print("{}", .{index}),
                                            }
                                        },
                                        RegImm5 => {
                                            try writer.print("Reg/Imm = ", .{});
                                            switch (value) {
                                                .register => |register| try writer.print("r{}", .{register}),
                                                .immediate => |immediate| try writer.print("0x{x:02}", .{immediate}),
                                            }
                                        },
                                        TrapVect => try writer.print("Vect = 0x{x:02}", .{value}),
                                        else => comptime unreachable,
                                    }
                                    try writer.print("\n", .{});
                                }
                            } else {
                                assert(self.statement == .raw_word);

                                try writer.print("    0x{x:04}", .{variant});
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
    };

    pub fn init(allocator: Allocator) Air {
        return .{
            .origin = null,
            .lines = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(air: *Air) void {
        air.lines.deinit(air.allocator);
    }
};

const assert = std.debug.assert;

const Parser = struct {
    source: []const u8,
    reporter: *Reporter,

    air: *Air,
    tokens: Tokenizer,
    current_label: ?Span,

    const Statement = Air.Line.Statement;

    pub fn new(air: *Air, source: []const u8, reporter: *Reporter) Parser {
        return .{
            .source = source,
            .reporter = reporter,
            .air = air,
            .tokens = Tokenizer.new(source),
            .current_label = null,
        };
    }

    pub fn parse(parser: *Parser) !void {
        while (true) {
            const control = parser.parseLine() catch |err| switch (err) {
                error.Reported => {
                    parser.discardRestOfLine();
                    continue;
                },
                error.Eof => {
                    parser.reporter.err(error.ExpectedEnd, .emptyAt(parser.source.len)) catch
                        {}; // Ignore
                    break;
                },
                error.OutOfMemory => |other| return other,
            };

            switch (control) {
                .@"continue" => continue,
                .@"break" => break,
            }
        }
    }

    fn discardRestOfLine(parser: *Parser) void {
        while (true) {
            const token = parser.nextToken(&.{.comma}) catch |err| switch (err) {
                // Ignore any other errors on this line
                error.Reported => continue,
            };
            if (token == null or token.?.kind == .newline)
                break;
        }
    }

    const Control = enum { @"continue", @"break" };

    fn parseLine(parser: *Parser) !Control {
        const token = try parser.nextToken(&.{ .comma, .newline }) orelse
            return error.Eof;

        switch (token.kind) {
            .label => {
                parser.expectNoCurrentLabel();
                parser.current_label = token.span;
            },

            .directive => |directive| {
                return try parser.parseDirective(directive);
            },

            .instruction => |instruction| {
                const statement = try parser.parseInstruction(instruction) orelse
                    return error.Reported;
                const span: Span = .fromBounds(
                    token.span.offset,
                    parser.tokens.index,
                );
                try parser.appendLine(statement, span);
            },

            else => {
                // TODO:
                std.log.warn("unhandled token: {s}", .{token.span.resolve(parser.source)});
            },
        }
        return .@"continue";
    }

    fn parseDirective(
        parser: *Parser,
        directive: Token.Kind.Directive,
    ) !Control {
        switch (directive) {
            .end => {
                parser.expectNoCurrentLabel();
                return .@"break";
            },

            .orig => {
                parser.expectNoCurrentLabel();
                if (parser.current_label) |label| {
                    try parser.reporter.err(error.UnusedLabel, label);
                }
                const origin = try parser.expectTokenKind(.word);
                if (parser.air.lines.items.len > 0) {
                    try parser.reporter.err(error.LateOrigin, origin.span);
                }
                if (parser.air.origin != null) {
                    try parser.reporter.err(error.MultipleOrigins, origin.span);
                }
                parser.air.origin = origin.value.asUnsigned() orelse {
                    try parser.reporter.err(error.IntegerTooLarge, origin.span);
                };
            },

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
                                parser.reporter.err(error.InvalidEscapeSequence, string.span) catch
                                    {}; // Keep parsing string
                                is_escaped = false;
                                continue;
                            },
                        };
                    is_escaped = false;
                    try parser.appendLine(
                        .{ .raw_word = char_escaped },
                        string.span,
                    );
                }
            },

            else => {
                // TODO:
                std.log.warn("unimplemented directive: {t}", .{directive});
            },
        }

        return .@"continue";
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
                        Statement.RegImm5 => .reg_imm5,
                        else => comptime unreachable,
                    };

                    const token = try parser.expectTokenKind(kind);
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

    fn expectNoCurrentLabel(parser: *Parser) void {
        if (parser.current_label) |label| {
            parser.reporter.err(error.UnusedLabel, label) catch
                {}; // Ignore; caller can continue parsing line
        }
    }

    fn appendLine(parser: *Parser, statement: Statement, span: Span) !void {
        try parser.air.lines.append(parser.air.allocator, .{
            .label = parser.current_label,
            .statement = statement,
            .span = span,
        });
        parser.current_label = null;
    }

    fn nextToken(
        parser: *Parser,
        comptime skip: []const std.meta.Tag(Token.Kind),
    ) error{Reported}!?Token {
        token: while (true) {
            const span = parser.tokens.next() orelse
                return null;
            const token = Token.from(span, parser.source) catch |err| {
                try parser.reporter.err(err, span);
            };
            for (skip) |skip_kind| {
                if (token.kind == skip_kind)
                    continue :token;
            }
            return token;
        }
    }

    fn expectToken(parser: *Parser) !Token {
        const token = try parser.nextToken(&.{.comma}) orelse {
            try parser.reporter.err(error.UnexpectedEof, .emptyAt(parser.source.len));
        };
        switch (token.kind) {
            .newline => {
                try parser.reporter.err(error.UnexpectedEol, .emptyAt(token.span.offset));
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
            .reg_imm5 => switch (token.kind) {
                .register => |register| .{ .register = register },
                .integer => |integer| .{
                    .immediate = integer.castTo(u5) orelse {
                        try parser.reporter.err(error.IntegerTooLarge, token.span);
                    },
                },
                else => null,
            },
            .imm5 => switch (token.kind) {
                .integer => |integer| integer.castTo(u5) orelse {
                    try parser.reporter.err(error.IntegerTooLarge, token.span);
                },
                else => null,
            },
            .word => switch (token.kind) {
                .integer => |integer| integer,
                else => null,
            },
            .label => switch (token.kind) {
                .label => .{ .unresolved = token.span },
                else => null,
            },
            .string => switch (token.kind) {
                .string => |string| string,
                else => null,
            },
            else => comptime unreachable,
        };
        const value = value_opt orelse {
            try parser.reporter.err(error.UnexpectedTokenKind, token.span);
        };
        return .{
            .span = token.span,
            .value = value,
        };
    }

    fn ExpectTokenKind(comptime kind: @EnumLiteral()) type {
        return switch (kind) {
            .register => Statement.Register,
            .reg_imm5 => Statement.RegImm5,
            .imm5 => u5,
            .word => Integer(16),
            .label => Statement.Label,
            .string => []const u8,
            else => @compileError("unsupported token kind `." ++ @tagName(kind) ++ "`"),
        };
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
