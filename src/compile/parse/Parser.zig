const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Traps = @import("../../Traps.zig");
const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../Air.zig");
const Span = @import("../Span.zig");
const Instruction = @import("../instruction.zig").Instruction;
const Operand = @import("../Operand.zig");
const TokenIter = @import("TokenIter.zig");
const Token = @import("Token.zig");
const case = @import("case.zig");

tokens: TokenIter,
current_label: ?Span,
origin: ?Span,

pub fn new(
    traps: *const Traps,
    source_: []const u8,
    reporter_: *Reporter,
) ?Parser {
    for (source_, 0..) |char, i| {
        if (!Token.isValidChar(char)) {
            reporter_.report(.invalid_source_byte, .{
                .byte = i,
            }).abort() catch
                return null;
        }
    }

    return .{
        .tokens = .new(traps, source_, reporter_),
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
    TooLong,
    OutOfMemory,
};

pub fn parse(parser: *Parser, air: *Air, gpa: Allocator) error{OutOfMemory}!void {
    var missing_end = false;

    while (true) {
        const control = parser.parseLine(air, gpa) catch |err| switch (err) {
            error.Reported => {
                parser.tokens.discardRemainingLine();
                continue;
            },
            error.Eof => {
                missing_end = true; // Report at end of function
                break;
            },
            error.TooLong => {
                return; // Give up, do not warn for anything else
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
            .first_token = air.getFirstSpan(),
        }).proceed(); // Can't return `error.Reported`
    }

    if (parser.current_label) |existing| {
        parser.reporter().report(.invalid_label_target, .{
            .label = existing,
            .target = null,
        }).proceed(); // Can't return `error.Reported`
    }

    if (missing_end) {
        parser.reporter().report(.missing_end, .{
            .last_token = parser.tokens.latest,
        }).proceed(); // Can't return `error.Reported`
    }
}

fn parseLine(parser: *Parser, air: *Air, gpa: Allocator) InnerError!Control {
    const token = try parser.tokens.nextExcluding(&.{.newline});

    switch (token.value) {
        .label => {
            if (parser.current_label) |existing| {
                try parser.reporter().report(.shadowed_label, .{
                    .existing = existing,
                    .new = token.span,
                }).handle();
            }

            if (parser.getExistingLabel(air, token.span.view(parser.source()))) |existing_label| {
                try parser.reporter().report(.redeclared_label, .{
                    .existing = existing_label,
                    .new = token.span,
                }).abort();
            } else {
                parser.current_label = token.span;
            }

            if (try parser.tokens.nextMatching(.colon)) |colon| {
                try parser.reporter().report(.label_colon, .{
                    .colon = colon.span,
                }).handle();
            }

            // Disallow two labels on same line
            // This should also be checked when the second label is parsed, but
            // this reports a more appropriate message
            if (try parser.tokens.nextMatching(.label)) |label| {
                try parser.reporter().report(.multiple_labels, .{
                    .existing = token.span,
                    .new = label.span,
                }).handle();
            }

            if (!case.isPascalCase(token.span.view(parser.source()))) {
                try parser.reporter().report(.unconventional_case, .{
                    .token = token.span,
                    .kind = .label,
                }).handle();
            }
        },

        .directive => |directive| {
            const control = try parser.parseDirective(air, directive, token.span, gpa);
            try parser.tokens.expectEol();
            return control;
        },

        .instruction => |instruction| {
            const instr = try parser.parseInstruction(instruction, token.span) orelse
                return error.Reported;
            const span: Span = .fromBounds(
                token.span.offset,
                parser.tokens.getIndex(),
            );
            try parser.tokens.expectEol();
            try parser.appendLine(air, .{ .instruction = instr }, span, gpa);
        },

        .trap_alias => |vect| {
            const statement: Air.Statement = .{
                .instruction = .{ .trap = .{
                    .vect = .{
                        .span = token.span,
                        .value = .{
                            .immediate = .{ .integer = vect, .form = null },
                        },
                    },
                } },
            };
            try parser.tokens.expectEol();
            try parser.appendLine(air, statement, token.span, gpa);
        },

        else => {
            try parser.reporter().report(.unexpected_token_kind, .{
                .found = token,
                .expected = &.{ .label, .instruction, .directive },
            }).abort();
        },
    }
    return .@"continue";
}

fn appendLine(
    parser: *Parser,
    air: *Air,
    statement: Air.Statement,
    span: Span,
    gpa: Allocator,
) error{ TooLong, OutOfMemory }!void {
    try parser.ensureCanAppendLines(air, 1, span);

    try air.lines.append(gpa, .{
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
    air: *Air,
    statement: Air.Statement,
    span: Span,
    n: usize,
    gpa: Allocator,
) error{ TooLong, OutOfMemory }!void {
    assert(n > 0);
    try parser.ensureCanAppendLines(air, n, span);

    try air.lines.ensureUnusedCapacity(gpa, n);

    air.lines.appendAssumeCapacity(.{
        .label = parser.current_label,
        .statement = statement,
        .span = span,
    });
    parser.current_label = null;

    air.lines.appendNTimesAssumeCapacity(.{
        .label = null,
        .statement = statement,
        .span = span,
    }, n - 1);
}

fn ensureCanAppendLines(parser: *Parser, air: *Air, n: usize, span: Span) error{TooLong}!void {
    if (air.origin + air.lines.items.len + n > 0xffff) {
        parser.reporter().report(.output_too_long, .{
            .statement = span,
        }).abort() catch
            return error.TooLong;
    }
}

fn parseDirective(
    parser: *Parser,
    air: *Air,
    directive: Token.Value.Directive,
    span: Span,
    gpa: Allocator,
) InnerError!Control {
    switch (directive) {
        .end => {
            if (parser.current_label) |label| {
                try parser.reporter().report(.invalid_label_target, .{
                    .label = label,
                    .target = span,
                }).handle();
            }
            return .@"break";
        },

        .orig => {
            // FIXME: This should technically be removed I think ??
            if (parser.current_label) |label| {
                try parser.reporter().report(.invalid_label_target, .{
                    .label = label,
                    .target = span,
                }).handle();
            }

            const origin = try parser.tokens.expectArgument(.word);
            if (parser.origin) |existing| {
                try parser.reporter().report(.multiple_origins, .{
                    .existing = existing,
                    .new = origin.span,
                }).abort();
            }
            air.origin = origin.value.castToUnsigned() orelse {
                try parser.reporter().report(.unexpected_negative_integer, .{
                    .integer = origin.span,
                }).abort();
            };
            parser.origin = origin.span;

            if (air.lines.items.len > 0) {
                try parser.reporter().report(.late_origin, .{
                    .origin = origin.span,
                    .first_token = air.getFirstSpan(),
                }).abort();
            }
        },

        .fill => {
            const word = try parser.tokens.expectArgument(.word);
            try parser.appendLine(
                air,
                .{ .raw_word = word.value.underlying },
                word.span,
                gpa,
            );
        },

        .blkw => {
            const size = try parser.tokens.expectArgument(.word);
            try parser.appendLineNTimes(
                air,
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
                    air,
                    .{ .raw_word = char_escaped },
                    string.span,
                    gpa,
                );
            }

            // Null terminator
            try parser.appendLine(
                air,
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
) InnerError!?Instruction {
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
            switch (regular) {
                .push, .pop, .call, .rets => {
                    try parser.reporter().report(.stack_instruction, .{
                        .instruction = span,
                        .kind = instruction,
                    }).handle();
                },
                else => {},
            }

            const Operands = @FieldType(Instruction, @tagName(regular));
            var operands: Operands = undefined;

            const fields = @typeInfo(Operands).@"struct".fields;
            inline for (fields, 0..) |field, i| {
                const operand = try parser.tokens.expectArgument(
                    .{ .operand = @FieldType(field.type, "value") },
                );
                @field(operands, field.name) = operand;

                if (i + 1 < fields.len)
                    if (try parser.tokens.nextMatching(.comma) == null) {
                        try parser.reporter().report(.missing_operand_comma, .{
                            .operand = operand.span,
                        }).handle();
                    };
            }

            return @unionInit(Instruction, @tagName(regular), operands);
        },

        inline // Branch instructions
        .br, .brn, .brz, .brp, .brnz, .brzp, .brnp, .brnzp => |branch| {
            const condition: Operand.value.ConditionMask = switch (branch) {
                .brn => .n,
                .brz => .z,
                .brp => .p,
                .brnz => .nz,
                .brzp => .zp,
                .brnp => .np,
                .br, .brnzp => .nzp,
                else => comptime unreachable,
            };
            const dest = try parser.tokens.expectArgument(.{
                .operand = Operand.value.PcOffset(9),
            });
            return .{ .br = .{
                .condition = .{ .span = span, .value = condition },
                .dest = dest,
            } };
        },
    }
}

fn getExistingLabel(parser: *const Parser, air: *Air, new_label: []const u8) ?Span {
    for (air.lines.items) |line| {
        const existing_label = line.label orelse
            continue;
        if (std.mem.eql(u8, existing_label.view(parser.source()), new_label)) {
            return existing_label;
        }
    }
    return null;
}

pub fn resolveLabels(parser: *Parser, air: *Air) void {
    for (air.lines.items, 0..) |*line, index| {
        const instruction = switch (line.statement) {
            .raw_word => continue,
            .instruction => |*instruction| instruction,
        };
        _ = switch (instruction.*) {
            .br => |*operands| parser.resolveFieldLabel(air, &operands.dest, index),
            .jsr => |*operands| parser.resolveFieldLabel(air, &operands.dest, index),
            .ld => |*operands| parser.resolveFieldLabel(air, &operands.src, index),
            .ldi => |*operands| parser.resolveFieldLabel(air, &operands.src, index),
            .lea => |*operands| parser.resolveFieldLabel(air, &operands.src, index),
            .st => |*operands| parser.resolveFieldLabel(air, &operands.dest, index),
            .sti => |*operands| parser.resolveFieldLabel(air, &operands.dest, index),
            .call => |*operands| parser.resolveFieldLabel(air, &operands.dest, index),
            else => {},
        } catch |err| switch (err) {
            error.Reported => continue,
        };
    }
}

fn resolveFieldLabel(
    parser: *Parser,
    air: *const Air,
    operand: anytype,
    index: usize,
) error{Reported}!void {
    // Extract integer type from operand argument type
    const Spanned = @typeInfo(@TypeOf(operand)).pointer.child;
    const Value = @FieldType(Spanned, "value");
    const Formed = @FieldType(Value, "resolved");
    const Int = @FieldType(Formed, "integer");

    switch (operand.value) {
        .unresolved => {},
        .resolved => return,
    }

    const string = operand.span.view(parser.source());

    const definition, const definition_span =
        parser.findLabelDefinition(air, string, .sensitive) orelse {
            _, const near_match =
                parser.findLabelDefinition(air, string, .insensitive) orelse .{ {}, null };
            try parser.reporter().report(.undeclared_label, .{
                .reference = operand.span,
                .nearest = near_match,
            }).abort();
        };

    const offset = calculateOffset(Int, definition, index) orelse {
        try parser.reporter().report(.offset_too_large, .{
            .reference = operand.span,
            .definition = definition_span,
            .offset = calculateOffset(i17, definition, index) orelse
                unreachable,
            .bits = @typeInfo(Int).int.bits,
        }).abort();
    };

    operand.value = .{ .resolved = .{ .integer = offset, .form = null } };
}

fn findLabelDefinition(
    parser: *const Parser,
    air: *const Air,
    reference: []const u8,
    case_mode: enum { sensitive, insensitive },
) ?struct { usize, Span } {
    for (air.lines.items, 0..) |*line, index| {
        const label = line.label orelse
            continue;
        const string = label.view(parser.source());
        const matches = switch (case_mode) {
            .sensitive => std.mem.eql(u8, string, reference),
            .insensitive => std.ascii.eqlIgnoreCase(string, reference),
        };
        if (matches)
            return .{ index, label };
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
