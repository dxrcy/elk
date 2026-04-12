const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Traps = @import("../../Traps.zig");
const Reporter = @import("../../reporting/reporting.zig").Primary;
const Air = @import("../Air.zig");
const Instruction = @import("../instruction.zig").Instruction;
const Span = @import("../Span.zig");
const Operand = @import("../Operand.zig");
const Tokenizer = @import("Tokenizer.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const case = @import("case.zig");

tokenizer: Tokenizer,
origin: ?Span,

pub fn new(
    traps: *const Traps,
    source_: []const u8,
    reporter_: *Reporter,
) error{Reported}!Parser {
    for (source_, 0..) |char, i| {
        if (!Token.isValidChar(char)) {
            try reporter_.report(.invalid_source_byte, .{
                .byte = i,
            }).abort();
        }
    }

    return .{
        .tokenizer = .new(traps, source_, reporter_),
        .origin = null,
    };
}

fn source(parser: *const Parser) []const u8 {
    return parser.tokenizer.source;
}
fn reporter(parser: *Parser) *Reporter {
    return parser.tokenizer.reporter;
}

const Control = enum { @"continue", @"break" };

const InnerError = error{
    Reported,
    Eof,
    TooLong,
    OutOfMemory,
};

pub fn parseAir(parser: *Parser, gpa: Allocator, air: *Air) error{OutOfMemory}!void {
    var missing_end = false;

    while (true) {
        const control = parser.parseLine(gpa, air) catch |err| switch (err) {
            error.Reported => {
                parser.tokenizer.discardRemainingLine();
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
            .first_token = parser.getFirstTokenSpan(),
        }).proceed(); // Can't return `error.Reported`
    }

    parser.discardCurrentLabel(air, null) catch
        {}; // Can't return `error.Reported`

    if (missing_end) {
        parser.reporter().report(.missing_end, .{
            .last_token = parser.tokenizer.latest,
        }).proceed(); // Can't return `error.Reported`
    }

    air.assertLabelOrder();
}

fn getFirstTokenSpan(parser: *const Parser) ?Span {
    var lexer: Lexer = .new(parser.source(), true);
    while (true) {
        const span = lexer.next() orelse
            return null;
        if (!std.mem.eql(u8, span.view(parser.source()), "\n"))
            return span;
    }
}

fn parseLine(parser: *Parser, gpa: Allocator, air: *Air) InnerError!Control {
    const token = try parser.tokenizer.nextExcluding(&.{.newline});

    switch (token.value) {
        .label => {
            try parser.addLabel(gpa, air, token.span);
        },

        .directive => |directive| {
            const control = try parser.parseDirective(gpa, air, directive, token.span);
            try parser.tokenizer.expectEol();
            return control;
        },

        .mnemonic => |mnemonic| {
            const instruction = try parser.parseInstructionOperands(mnemonic, token.span);
            const span: Span = .fromBounds(
                token.span.offset,
                parser.tokenizer.getIndex(),
            );
            try parser.tokenizer.expectEol();

            try parser.ensureCanAppendLines(air, 1, span);
            try air.lines.append(gpa, .{
                .statement = .{ .instruction = instruction },
                .span = span,
            });
        },

        .trap_alias => |vect| {
            const statement: Air.Statement = .{
                .instruction = .{ .trap = .{
                    .vect = .{
                        .span = token.span,
                        .value = .{ .immediate = .{ .integer = vect, .form = null } },
                    },
                } },
            };
            try parser.tokenizer.expectEol();

            try parser.ensureCanAppendLines(air, 1, token.span);
            try air.lines.append(gpa, .{
                .statement = statement,
                .span = token.span,
            });
        },

        else => {
            try parser.reporter().report(.unexpected_token_kind, .{
                .found = token,
                .expected = &.{ .label, .mnemonic, .directive },
            }).abort();
        },
    }
    return .@"continue";
}

/// Asserts that at least one non-`newline` token exists before EOF.
/// Label definition for this line must be handled by caller.
pub fn parseInstruction(parser: *Parser) error{Reported}!Instruction {
    const token = parser.tokenizer.nextExcluding(&.{.newline}) catch |err| switch (err) {
        error.Reported => return error.Reported,
        error.Eof => unreachable,
    };

    switch (token.value) {
        .mnemonic => |mnemonic| {
            const instruction = try parser.parseInstructionOperands(mnemonic, token.span);
            try parser.tokenizer.expectEol();
            return instruction;
        },

        .trap_alias => |vect| {
            return .{
                .trap = .{
                    .vect = .{
                        .span = token.span,
                        .value = .{
                            .immediate = .{ .integer = vect, .form = null },
                        },
                    },
                },
            };
        },

        else => {
            try parser.reporter().report(.unexpected_token_kind, .{
                .found = token,
                .expected = &.{.mnemonic},
            }).abort();
        },
    }
}

fn discardCurrentLabel(parser: *Parser, air: *Air, target: ?Span) error{Reported}!void {
    air.assertLabelOrder();

    const index = air.lines.items.len;
    var i: usize = air.labels.items.len;
    while (i > 0) : (i -= 1) {
        const label = air.labels.items[i - 1];
        assert(label.index <= index);
        if (label.index != index)
            break;

        if (Air.Label.Kind.from(label.span.view(parser.source())) != .normal)
            continue;

        _ = air.labels.orderedRemove(i - 1);

        try parser.reporter().report(.invalid_label_target, .{
            .label = label.span,
            .target = target,
        }).handle();
    }
}

fn ensureCanAppendLines(parser: *Parser, air: *Air, n: usize, span: Span) error{TooLong}!void {
    if (air.origin + air.lines.items.len + n > 0xffff) {
        parser.reporter().report(.output_too_long, .{
            .statement = span,
        }).abort() catch
            return error.TooLong;
    }
}

fn addLabel(parser: *Parser, gpa: Allocator, air: *Air, label: Span) InnerError!void {
    if (parser.getLabelWithName(air, label.view(parser.source()))) |existing_label| {
        try parser.reporter().report(.redefined_label, .{
            .existing = existing_label,
            .new = label,
        }).abort();
    }

    if (try parser.tokenizer.nextMatching(.colon)) |colon| {
        try parser.reporter().report(.label_colon, .{
            .colon = colon.span,
        }).handle();
    }

    // Disallow two labels on same line
    // This should also be checked when the second label is parsed, but
    // this reports a more appropriate message
    if (try parser.tokenizer.nextMatching(.label)) |right| {
        try parser.reporter().report(.existing_label_left, .{
            .existing = label,
            .new = right.span,
        }).handle();
    }

    if (!case.isPascalCase(label.view(parser.source()))) {
        try parser.reporter().report(.unconventional_case, .{
            .token = label,
            .kind = .label,
        }).handle();
    }

    const index: u16 = @intCast(air.lines.items.len);

    if (getExistingLabelAbove(air, index)) |existing| {
        try parser.reporter().report(.existing_label_above, .{
            .existing = existing.span,
            .new = label,
        }).handle();
    }

    try air.labels.append(gpa, .new(
        index,
        label,
        label.view(parser.source()),
    ));
}

fn parseDirective(
    parser: *Parser,
    gpa: Allocator,
    air: *Air,
    directive: Token.Value.Directive,
    span: Span,
) InnerError!Control {
    switch (directive) {
        .end => {
            try parser.discardCurrentLabel(air, span);
            return .@"break";
        },

        .orig => {
            try parser.discardCurrentLabel(air, span);

            const origin = try parser.tokenizer.expectArgument(.word);
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
                    .first_token = parser.getFirstTokenSpan(),
                }).abort();
            }
        },

        .fill => {
            const word = try parser.tokenizer.expectArgument(.word);

            try parser.ensureCanAppendLines(air, 1, span);
            try air.lines.append(gpa, .{
                .statement = .{ .raw_word = word.value.underlying },
                .span = word.span,
            });
        },

        .blkw => {
            const size = try parser.tokenizer.expectArgument(.word);
            const size_value = size.value.underlying;
            if (size_value == 0)
                return .@"continue";
            try parser.ensureCanAppendLines(air, size_value, span);
            try air.lines.appendNTimes(gpa, .{
                .statement = .{ .raw_word = 0x0000 },
                .span = size.span,
            }, size_value);
        },

        .stringz => {
            const string = try parser.tokenizer.expectArgument(.string);
            const contents = string.value.in(string.span);
            const contents_string = contents.view(parser.source());

            // Check length and allocate lines before proper string iteration
            const length = Token.Escaped.validLength(.double, contents_string) + 1; // Include NUL
            try parser.ensureCanAppendLines(air, length, span);
            try air.lines.ensureUnusedCapacity(gpa, length);

            var escaped: Token.Escaped = .new(.double, contents_string);
            while (escaped.next()) |result| {
                const char = result catch {
                    try parser.reporter().report(.invalid_string_escape, .{
                        .string = string.span,
                        .sequence = .{
                            .offset = contents.offset + escaped.index - 2,
                            .len = 2,
                        },
                    }).handle();
                    continue;
                };

                air.lines.appendAssumeCapacity(.{
                    .statement = .{ .raw_word = char },
                    .span = string.span,
                });
            }

            // Null terminator
            air.lines.appendAssumeCapacity(.{
                .statement = .{ .raw_word = 0x0000 },
                .span = string.span,
            });
        },
    }

    return .@"continue";
}

fn parseInstructionOperands(
    parser: *Parser,
    mnemonic: Token.Value.Mnemonic,
    span: Span,
) error{Reported}!Instruction {
    switch (mnemonic) {
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
                        .mnemonic = span,
                        .kind = mnemonic,
                    }).handle();
                },
                else => {},
            }

            const Operands = @FieldType(Instruction, @tagName(regular));
            var operands: Operands = undefined;

            const fields = @typeInfo(Operands).@"struct".fields;
            inline for (fields, 0..) |field, i| {
                const operand = try parser.tokenizer.expectArgument(
                    .{ .operand = @FieldType(field.type, "value") },
                );
                @field(operands, field.name) = operand;

                if (i + 1 < fields.len)
                    if (try parser.tokenizer.nextMatching(.comma) == null) {
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
            const dest = try parser.tokenizer.expectArgument(.{
                .operand = Operand.value.PcOffset(9),
            });
            return .{ .br = .{
                .condition = .{ .span = span, .value = condition },
                .dest = dest,
            } };
        },
    }
}

fn getLabelWithName(parser: *const Parser, air: *Air, new_label: []const u8) ?Span {
    for (air.labels.items) |*label| {
        if (std.mem.eql(u8, label.span.view(parser.source()), new_label))
            return label.span;
    }
    return null;
}

fn getExistingLabelAbove(air: *Air, index: u16) ?*const Air.Label {
    for (air.labels.items) |*existing| {
        if (existing.index == index)
            return existing;
    }
    return null;
}

pub fn resolveLabelReferences(parser: *Parser, air: *Air) void {
    for (air.lines.items, 0..) |*line, index| {
        const instruction = switch (line.statement) {
            .raw_word => continue,
            .instruction => |*instruction| instruction,
        };
        parser.resolveLabelOperand(
            air,
            parser.source(),
            instruction,
            index + 1, // PC is at N+1 when instruction N is interpreted
        ) catch |err| switch (err) {
            error.Reported => continue,
        };
    }

    for (air.labels.items) |*label| {
        if (label.references == 0 and label.kind == .normal) {
            parser.reporter().report(.unused_label, .{
                .label = label.span,
            }).proceed();
        }
    }
}

pub fn resolveLabelOperand(
    parser: *Parser,
    air: *const Air,
    air_source: []const u8,
    instruction: *Instruction,
    index: usize,
) error{Reported}!void {
    return switch (instruction.*) {
        .br => |*operands| parser.resolveFieldLabel(air, air_source, &operands.dest, index),
        .jsr => |*operands| parser.resolveFieldLabel(air, air_source, &operands.dest, index),
        .ld => |*operands| parser.resolveFieldLabel(air, air_source, &operands.src, index),
        .ldi => |*operands| parser.resolveFieldLabel(air, air_source, &operands.src, index),
        .lea => |*operands| parser.resolveFieldLabel(air, air_source, &operands.src, index),
        .st => |*operands| parser.resolveFieldLabel(air, air_source, &operands.dest, index),
        .sti => |*operands| parser.resolveFieldLabel(air, air_source, &operands.dest, index),
        .call => |*operands| parser.resolveFieldLabel(air, air_source, &operands.dest, index),
        else => {},
    };
}

fn resolveFieldLabel(
    parser: *Parser,
    air: *const Air,
    air_source: []const u8,
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

    const definition =
        air.findLabel(string, .sensitive, air_source) orelse {
            const near_match = air.findLabel(string, .insensitive, air_source);
            try parser.reporter().report(.undefined_label, .{
                .reference = operand.span,
                .nearest = if (near_match) |label| label.span else null,
                .definition_source = air_source,
            }).abort();
        };

    const offset = calculateOffset(Int, definition.index, index) orelse {
        try parser.reporter().report(.offset_too_large, .{
            .reference = operand.span,
            .definition = definition.span,
            .offset = calculateOffset(i17, definition.index, index) orelse
                unreachable,
            .bits = @typeInfo(Int).int.bits,
            .definition_source = air_source,
        }).abort();
    };

    definition.references += 1;
    operand.value = .{ .resolved = .{ .integer = offset, .form = null } };
}

fn calculateOffset(comptime T: type, definition: usize, reference: usize) ?T {
    comptime assert(@typeInfo(T).int.signedness == .signed);
    return std.math.cast(
        T,
        std.math.sub(
            isize,
            @intCast(definition),
            @intCast(reference),
        ) catch
            return null,
    );
}
