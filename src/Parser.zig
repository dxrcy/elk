const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Air = @import("Air.zig");
const Operand = Air.Operand;
const Statement = Air.Statement;
const TokenIter = @import("TokenIter.zig");
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Reporter = @import("Reporter.zig");

air: *Air,
/// Used for `air`.
allocator: Allocator,

tokens: TokenIter,
current_label: ?Span,

source: []const u8,
reporter: *Reporter,

pub fn new(
    air: *Air,
    source: []const u8,
    reporter: *Reporter,
    allocator: Allocator,
) Parser {
    return .{
        .air = air,
        .allocator = allocator,
        .tokens = .new(source, reporter),
        .current_label = null,
        .source = source,
        .reporter = reporter,
    };
}

const Control = enum { @"continue", @"break" };

const InnerError = error{
    Reported,
    Eof,
    OutOfMemory,
};

pub fn parse(parser: *Parser) error{OutOfMemory}!void {
    while (true) {
        const control = parser.parseLine() catch |err| switch (err) {
            error.Reported => {
                parser.tokens.discardRemainingLine();
                continue;
            },
            error.Eof => {
                parser.reporter.warn(error.ExpectedEnd, .emptyAt(parser.source.len));
                break;
            },
            error.OutOfMemory => |other| return other,
        };

        switch (control) {
            .@"continue" => continue,
            .@"break" => break,
        }
    }

    if (parser.air.origin == null) {
        parser.reporter.warn(error.MissingOrigin, .emptyAt(0));
        parser.air.origin = 0x3000;
    }
}

fn parseLine(parser: *Parser) InnerError!Control {
    const token = try parser.tokens.nextExcluding(&.{.newline});

    switch (token.value) {
        .label => {
            parser.ensureNoCurrentLabel();

            if (parser.getExistingLabel(token.span.view(parser.source))) |existing_label| {
                try parser.reporter.err(error.DuplicateLabel, existing_label);
            } else {
                parser.current_label = token.span;
            }

            parser.tokens.discardOptional(.colon);

            // Disallow two labels on same line
            // This should also be checked when the second label is parsed, but
            // this reports a more appropriate message
            if (parser.tokens.nextMatching(.label)) |label| {
                try parser.reporter.err(error.UnexpectedLabel, label.span);
            }
        },

        .directive => |directive| {
            const control = try parser.parseDirective(directive);
            try parser.tokens.expectEol();
            return control;
        },

        .instruction => |instruction| {
            const statement = try parser.parseInstruction(instruction, token.span) orelse
                return error.Reported;
            const span: Span = .fromBounds(
                token.span.offset,
                parser.tokens.getIndex(),
            );
            try parser.tokens.expectEol();
            try parser.appendLine(statement, span);
        },

        else => {
            try parser.reporter.err(error.UnexpectedTokenKind, token.span);
        },
    }
    return .@"continue";
}

fn appendLine(
    parser: *Parser,
    statement: Statement,
    span: Span,
) error{OutOfMemory}!void {
    try parser.air.lines.append(parser.allocator, .{
        .label = parser.current_label,
        .statement = statement,
        .span = span,
    });
    parser.current_label = null;
}

/// Note that the current label is only applied to the *first* statement in the
/// sequence.
/// Equivalent to calling `appendLine` `n` times, but only resizes once at most.
fn appendLineNTimes(
    parser: *Parser,
    statement: Statement,
    span: Span,
    n: usize,
) error{OutOfMemory}!void {
    assert(n > 0);

    try parser.air.lines.ensureUnusedCapacity(parser.allocator, n);

    parser.air.lines.appendAssumeCapacity(.{
        .label = parser.current_label,
        .statement = statement,
        .span = span,
    });
    parser.current_label = null;

    parser.air.lines.appendNTimesAssumeCapacity(.{
        .label = null,
        .statement = statement,
        .span = span,
    }, n - 1);
}

fn parseDirective(
    parser: *Parser,
    directive: Token.Value.Directive,
) InnerError!Control {
    switch (directive) {
        .end => {
            parser.ensureNoCurrentLabel();
            return .@"break";
        },

        .orig => {
            parser.ensureNoCurrentLabel();
            const origin = try parser.tokens.expectArgument(.word);
            if (parser.air.lines.items.len > 0) {
                try parser.reporter.err(error.LateOrigin, origin.span);
            }
            if (parser.air.origin != null) {
                try parser.reporter.err(error.MultipleOrigins, origin.span);
            }
            parser.air.origin = origin.value.castToUnsigned() orelse {
                try parser.reporter.err(error.IntegerTooLarge, origin.span);
            };
        },

        .fill => {
            const word = try parser.tokens.expectArgument(.word);
            try parser.appendLine(
                .{ .raw_word = word.value.bitcastToUnsigned() },
                word.span,
            );
        },

        .blkw => {
            const size = try parser.tokens.expectArgument(.word);
            try parser.appendLineNTimes(
                .{ .raw_word = 0x00 },
                size.span,
                size.value.bitcastToUnsigned(),
            );
        },

        .stringz => {
            const string = try parser.tokens.expectArgument(.string);
            const string_value = string.value.in(string.span).view(parser.source);

            if (std.mem.containsAtLeast(u8, string_value, 1, "\n")) {
                parser.reporter.warn(error.MultilineString, string.span);
            }

            var is_escaped = false;
            for (string_value) |char| {
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
    }

    return .@"continue";
}

fn parseInstruction(
    parser: *Parser,
    instruction: Token.Value.Instruction,
    span: Span,
) InnerError!?Statement {
    switch (instruction) {
        inline // Automatic parsing for 'regular' instructions
        .add,
        .@"and",
        .jmp,
        .jsr,
        .jsrr,
        .ld,
        .ldi,
        .ldr,
        .lea,
        .not,
        .ret,
        .rti,
        .st,
        .sti,
        .str,
        .trap,
        => |regular| {
            switch (regular) {
                .rti => parser.reporter.warn(error.InterruptInstruction, span),
                else => {},
            }
            const Payload = @FieldType(Statement, @tagName(regular));
            var payload: Payload = undefined;
            inline for (@typeInfo(Payload).@"struct".fields) |field| {
                parser.tokens.discardOptional(.comma);
                const operand = try parser.tokens.expectArgument(
                    .{ .operand = @FieldType(field.type, "value") },
                );
                @field(payload, field.name) = operand;
            }
            return @unionInit(Statement, @tagName(regular), payload);
        },

        inline // Branch instructions
        .br, .brn, .brz, .brp, .brnz, .brzp, .brnp, .brnzp => |branch| {
            const condition: Operand.Value.ConditionMask = switch (branch) {
                .brn => .n,
                .brz => .z,
                .brp => .p,
                .brnz => .nz,
                .brzp => .zp,
                .brnp => .np,
                .br, .brnzp => .nzp,
                else => comptime unreachable,
            };
            parser.tokens.discardOptional(.comma);
            const dest = try parser.tokens.expectArgument(.{ .operand = Operand.Value.PCOffset9 });
            return .{ .br = .{
                .condition = .{ .span = span, .value = condition },
                .dest = dest,
            } };
        },

        inline // Trap aliases
        .getc,
        .out,
        .puts,
        .in,
        .putsp,
        .halt,
        .putn,
        .reg,
        => |alias| {
            const vect: u8 = switch (alias) {
                .getc => 0x20,
                .out => 0x21,
                .puts => 0x22,
                .in => 0x23,
                .putsp => 0x24,
                .halt => 0x25,
                .putn => 0x26,
                .reg => 0x27,
                else => comptime unreachable,
            };
            return .{ .trap = .{
                .vect = .{ .span = span, .value = .{ .inner = vect } },
            } };
        },
    }
}

fn ensureNoCurrentLabel(parser: *Parser) void {
    if (parser.current_label) |label| {
        parser.reporter.warn(error.UselessLabel, label);
    }
}

fn getExistingLabel(parser: *const Parser, new_label: []const u8) ?Span {
    for (parser.air.lines.items) |line| {
        const existing_label = line.label orelse
            continue;
        if (std.mem.eql(u8, existing_label.view(parser.source), new_label)) {
            return existing_label;
        }
    }
    return null;
}

pub fn resolveLabels(parser: *Parser) void {
    for (parser.air.lines.items, 0..) |*line, index| {
        switch (line.statement) {
            .br => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            .jsr => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            .ld => |*operands| parser.resolveFieldLabel(&operands.src, index),
            .ldi => |*operands| parser.resolveFieldLabel(&operands.src, index),
            .lea => |*operands| parser.resolveFieldLabel(&operands.src, index),
            .st => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            .sti => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            else => {},
        }
    }
}

fn resolveFieldLabel(parser: *Parser, operand: anytype, index: usize) void {
    // Check generic param
    const Int = switch (@TypeOf(operand)) {
        *Operand.Spanned(Operand.Value.PCOffset9) => i9,
        *Operand.Spanned(Operand.Value.PCOffset11) => i11,
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

fn calculateOffset(comptime T: type, definition: usize, reference: usize) ?T {
    comptime assert(@typeInfo(T).int.signedness == .signed);
    return std.math.cast(
        T,
        std.math.sub(
            isize,
            @intCast(definition),
            @intCast(reference +
                1), // PC is at N+1 when instruction N is interpreted
        ) catch
            return null,
    );
}
