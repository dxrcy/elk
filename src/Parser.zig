const Parser = @This();

const std = @import("std");
const assert = std.debug.assert;

const Air = @import("Air.zig");
const Operand = Air.Operand;
const OperandSpan = Air.OperandSpan;
const Statement = Air.Statement;
const Tokenizer = @import("Tokenizer.zig");
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Integer = @import("integers.zig").Integer;
const Reporter = @import("Reporter.zig");

source: []const u8,
reporter: *Reporter,
air: *Air,
tokens: Tokenizer,
current_label: ?Span,

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
            const statement = try parser.parseInstruction(instruction, token.span) orelse
                return error.Reported;
            const span: Span = .fromBounds(
                token.span.offset,
                parser.tokens.index,
            );
            try parser.appendLine(statement, span);
        },

        else => {
            // TODO:
            std.log.warn("unhandled token: {s}", .{token.span.view(parser.source)});
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
            const origin = try parser.expectOperand(.word);
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
            const string = try parser.expectOperand(.string);
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
            // Null terminator
            try parser.appendLine(
                .{ .raw_word = 0x0000 },
                string.span,
            );
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
    span: Span,
) !?Statement {
    const regular_instructions = [_]Token.Kind.Instruction{
        .add,
        .lea,
        .jsr,
    };
    const trap_aliases = [_]struct { Token.Kind.Instruction, Operand.TrapVect }{
        .{ .puts, 0x22 },
        .{ .halt, 0x25 },
    };

    inline for (regular_instructions) |regular| {
        if (instruction == regular) {
            const Payload = @FieldType(Statement, @tagName(regular));
            var payload: Payload = undefined;

            inline for (@typeInfo(Payload).@"struct".fields) |field| {
                const token = try parser.expectOperand(switch (field.type.Kind) {
                    Operand.Register => .register,
                    Operand.RegImm5 => .reg_imm5,
                    Operand.Offset9 => .offset9,
                    Operand.Offset11 => .offset11,
                    else => comptime unreachable,
                });
                @field(payload, field.name) = token;
            }

            return @unionInit(Statement, @tagName(regular), payload);
        }
    }

    inline for (trap_aliases) |pair| {
        const alias, const vect = pair;
        if (instruction == alias) {
            return .{
                .trap = .{
                    .vect = .{
                        // Use alias span for operand
                        .span = span,
                        .value = vect,
                    },
                },
            };
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

fn expectOperand(
    parser: *Parser,
    comptime operand: Operand,
) !OperandSpan(operand.asType()) {
    const token = try parser.expectToken();
    assert(token.kind != .comma);
    const value = convertOperand(operand, token.kind) catch |err| {
        try parser.reporter.err(err, token.span);
    };
    return .{
        .span = token.span,
        .value = value,
    };
}

// TODO: Rename
fn convertOperand(
    comptime operand: Operand,
    kind: Token.Kind,
) error{ UnexpectedTokenKind, IntegerTooLarge }!operand.asType() {
    return switch (operand) {
        .register => switch (kind) {
            .register => |register| .{ .value = register },
            else => error.UnexpectedTokenKind,
        },
        .reg_imm5 => switch (kind) {
            .register => |register| .{ .register = register },
            .integer => |integer| .{ .immediate = try integer.castTo(u5) },
            else => error.UnexpectedTokenKind,
        },
        .offset9 => switch (kind) {
            .integer => |integer| .{ .resolved = try integer.castTo(i9) },
            .label => .unresolved,
            else => error.UnexpectedTokenKind,
        },
        .offset11 => switch (kind) {
            .integer => |integer| .{ .resolved = try integer.castTo(i11) },
            .label => .unresolved,
            else => error.UnexpectedTokenKind,
        },
        .word => switch (kind) {
            .integer => |integer| integer,
            else => error.UnexpectedTokenKind,
        },
        .string => switch (kind) {
            .string => |string| string,
            else => error.UnexpectedTokenKind,
        },
    };
}

pub fn resolveLabels(parser: *Parser) void {
    for (parser.air.lines.items, 0..) |*line, index| {
        switch (line.statement) {
            .jsr => |*instruction| parser.resolveFieldLabel(&instruction.dest, index),
            .lea => |*instruction| parser.resolveFieldLabel(&instruction.src, index),
            // TODO: Add rest.
            else => {},
        }
    }
}

fn resolveFieldLabel(parser: *Parser, operand: anytype, index: usize) void {
    // Check generic param
    const Int = switch (@TypeOf(operand)) {
        *OperandSpan(Operand.Offset9) => i9,
        *OperandSpan(Operand.Offset11) => i11,
        else => comptime unreachable,
    };

    switch (operand.value) {
        .unresolved => {},
        .resolved => return,
    }

    const definition = parser.findLabelDefinition(operand.span.view(parser.source)) orelse {
        parser.reporter.err(error.UndeclaredLabel, operand.span) catch
            return;
    };
    const offset = calculateOffset(Int, definition, index) orelse {
        parser.reporter.err(error.OffsetTooLarge, operand.span) catch
            return;
    };
    operand.value = .{ .resolved = offset };
}

fn findLabelDefinition(parser: *const Parser, reference: []const u8) ?usize {
    for (parser.air.lines.items, 0..) |*line, index| {
        const label = line.label orelse
            continue;
        // TODO: should it be case insensitive ?
        if (std.mem.eql(u8, label.view(parser.source), reference))
            return index;
    }
    return null;
}

fn calculateOffset(
    comptime T: type,
    definition: usize,
    reference: usize,
) ?T {
    return std.math.cast(
        T,
        std.math.sub(
            usize,
            definition,
            reference +
                1, // PC is at N+1 when instruction N is interpreted
        ) catch
            return null,
    );
}
