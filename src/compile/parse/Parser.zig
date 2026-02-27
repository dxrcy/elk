const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../Air.zig");
const Span = @import("../Span.zig");
const TokenIter = @import("TokenIter.zig");
const Token = @import("Token.zig");
const Operand = Air.Operand;
const Statement = Air.Statement;

air: *Air,
tokens: TokenIter,
current_label: ?Span,
origin: ?Span,

pub fn new(air: *Air, tokens: TokenIter) Parser {
    return .{
        .air = air,
        .tokens = tokens,
        .current_label = null,
        .origin = null,
    };
}

fn source(parser: *const Parser) []const u8 {
    return parser.tokens.source;
}
fn reporter(parser: *Parser) *Reporter {
    return parser.tokens.reporter;
}

const Control = enum { @"continue", @"break" };

const InnerError = error{
    Reported,
    Eof,
    OutOfMemory,
};

pub fn parse(parser: *Parser, gpa: Allocator) error{OutOfMemory}!void {
    var missing_end = false;

    while (true) {
        const control = parser.parseLine(gpa) catch |err| switch (err) {
            error.Reported => {
                parser.tokens.discardRemainingLine();
                continue;
            },
            error.Eof => {
                missing_end = true; // Report at end of function
                break;
            },
            error.OutOfMemory => |other| return other,
        };

        switch (control) {
            .@"continue" => continue,
            .@"break" => break,
        }
    }

    if (parser.origin == null) {
        parser.reporter().report(.missing_origin, .{
            .first_token = parser.air.getFirstSpan(),
        }).proceed();
    }

    if (parser.current_label) |existing| {
        parser.reporter().report(.eof_label, .{
            .label = existing,
        }).proceed();
    }

    if (missing_end) {
        parser.reporter().report(.missing_end, .{
            .last_token = parser.tokens.latest,
        }).proceed();
    }
}

fn parseLine(parser: *Parser, gpa: Allocator) InnerError!Control {
    const token = try parser.tokens.nextExcluding(&.{.newline});

    switch (token.value) {
        .label => {
            if (parser.current_label) |existing| {
                parser.reporter().report(.shadowed_label, .{
                    .existing = existing,
                    .new = token.span,
                }).proceed();
            }

            if (parser.getExistingLabel(token.span.view(parser.source()))) |existing_label| {
                try parser.reporter().report(.duplicate_label, .{
                    .existing = existing_label,
                    .new = token.span,
                }).abort();
            } else {
                parser.current_label = token.span;
            }

            parser.tokens.discardOptional(.colon);

            // Disallow two labels on same line
            // This should also be checked when the second label is parsed, but
            // this reports a more appropriate message
            if (try parser.tokens.nextMatching(.label)) |label| {
                parser.reporter().report(.unexpected_label, .{
                    .existing = token.span,
                    .new = label.span,
                }).proceed(); // May be followed by a (valid) instruction
            }
        },

        .directive => |directive| {
            const control = try parser.parseDirective(directive, token.span, gpa);
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
            try parser.appendLine(statement, span, gpa);
        },

        else => {
            try parser.reporter().report(.unexpected_token_kind, .{
                .token = token,
                .expected = &.{ .label, .instruction, .directive },
            }).abort();
        },
    }
    return .@"continue";
}

fn appendLine(
    parser: *Parser,
    statement: Statement,
    span: Span,
    gpa: Allocator,
) error{OutOfMemory}!void {
    try parser.air.lines.append(gpa, .{
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
    gpa: Allocator,
) error{OutOfMemory}!void {
    assert(n > 0);

    try parser.air.lines.ensureUnusedCapacity(gpa, n);

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
    span: Span,
    gpa: Allocator,
) InnerError!Control {
    switch (directive) {
        .end => {
            if (parser.current_label) |label| {
                parser.reporter().report(.useless_label, .{
                    .label = label,
                    .token = span,
                }).proceed();
            }
            return .@"break";
        },

        .orig => {
            // FIXME: This should technically be removed I think ??
            if (parser.current_label) |label| {
                parser.reporter().report(.useless_label, .{
                    .label = label,
                    .token = span,
                }).proceed();
            }

            const origin = try parser.tokens.expectArgument(.word);
            if (parser.origin) |existing| {
                try parser.reporter().report(.multiple_origins, .{
                    .existing = existing,
                    .new = origin.span,
                }).abort();
            }
            parser.air.origin = origin.value.castToUnsigned() orelse {
                try parser.reporter().report(.unexpected_negative_integer, .{
                    .integer = origin.span,
                }).abort();
            };
            parser.origin = origin.span;

            if (parser.air.lines.items.len > 0) {
                try parser.reporter().report(.late_origin, .{
                    .origin = origin.span,
                    .first_token = parser.air.getFirstSpan(),
                }).abort();
            }
        },

        .fill => {
            const word = try parser.tokens.expectArgument(.word);
            try parser.appendLine(
                .{ .raw_word = word.value.underlying },
                word.span,
                gpa,
            );
        },

        .blkw => {
            const size = try parser.tokens.expectArgument(.word);
            try parser.appendLineNTimes(
                .{ .raw_word = 0x00 },
                size.span,
                size.value.underlying,
                gpa,
            );
        },

        .stringz => {
            const string = try parser.tokens.expectArgument(.string);
            const contents = string.value.in(string.span);

            var is_escaped = false;
            for (contents.view(parser.source()), 0..) |char, i| {
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
                            try parser.reporter().report(.invalid_string_escape, .{
                                .string = string.span,
                                .sequence = .{
                                    .offset = contents.offset + i - 1,
                                    .len = 2,
                                },
                            }).handle();
                            is_escaped = false;
                            continue;
                        },
                    };
                is_escaped = false;

                try parser.appendLine(
                    .{ .raw_word = char_escaped },
                    string.span,
                    gpa,
                );
            }

            // Null terminator
            try parser.appendLine(
                .{ .raw_word = 0x0000 },
                string.span,
                gpa,
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
        .not,
        .jmp,
        .ret,
        .jsr,
        .jsrr,
        .lea,
        .ld,
        .ldi,
        .ldr,
        .st,
        .sti,
        .str,
        .trap,
        .push,
        .pop,
        .call,
        .rets,
        .rti,
        => |regular| {
            const Operands = @FieldType(Statement, @tagName(regular));
            var operands: Operands = undefined;
            inline for (@typeInfo(Operands).@"struct".fields) |field| {
                parser.tokens.discardOptional(.comma);
                const operand = try parser.tokens.expectArgument(
                    .{ .operand = @FieldType(field.type, "value") },
                );
                @field(operands, field.name) = operand;
            }
            return @unionInit(Statement, @tagName(regular), operands);
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
            const dest = try parser.tokens.expectArgument(.{ .operand = Operand.Value.PcOffset9 });
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
                .vect = .{ .span = span, .value = .{ .immediate = vect } },
            } };
        },
    }
}

fn getExistingLabel(parser: *const Parser, new_label: []const u8) ?Span {
    for (parser.air.lines.items) |line| {
        const existing_label = line.label orelse
            continue;
        if (std.mem.eql(u8, existing_label.view(parser.source()), new_label)) {
            return existing_label;
        }
    }
    return null;
}

pub fn resolveLabels(parser: *Parser) void {
    for (parser.air.lines.items, 0..) |*line, index| {
        _ = switch (line.statement) {
            .br => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            .jsr => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            .ld => |*operands| parser.resolveFieldLabel(&operands.src, index),
            .ldi => |*operands| parser.resolveFieldLabel(&operands.src, index),
            .lea => |*operands| parser.resolveFieldLabel(&operands.src, index),
            .st => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            .sti => |*operands| parser.resolveFieldLabel(&operands.dest, index),
            else => {},
        } catch |err| switch (err) {
            error.Reported => continue,
        };
    }
}

fn resolveFieldLabel(
    parser: *Parser,
    operand: anytype,
    index: usize,
) error{Reported}!void {
    // Check generic param
    const Int = switch (@TypeOf(operand)) {
        *Operand.Spanned(Operand.Value.PcOffset9) => i9,
        *Operand.Spanned(Operand.Value.PcOffset11) => i11,
        else => comptime unreachable,
    };

    switch (operand.value) {
        .unresolved => {},
        .resolved => return,
    }

    const definition = parser.findLabelDefinition(operand.span.view(parser.source())) orelse {
        try parser.reporter().report(.undeclared_label, .{
            .label = operand.span,
        }).abort();
    };
    const offset = calculateOffset(Int, definition, index) orelse {
        try parser.reporter().report(.offset_too_large, .{
            .reference = operand.span,
            .definition = parser.air.lines.items[definition].label orelse
                unreachable,
        }).abort();
    };
    operand.value = .{ .resolved = offset };
}

fn findLabelDefinition(parser: *const Parser, reference: []const u8) ?usize {
    for (parser.air.lines.items, 0..) |*line, index| {
        const label = line.label orelse
            continue;
        if (std.mem.eql(u8, label.view(parser.source()), reference))
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
