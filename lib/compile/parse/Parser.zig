const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const elk = @import("../../root.zig");
const Span = elk.Span;
const Source = elk.Source;
const Reporter = elk.reporting.Primary;
const Air = elk.Air;
const Instruction = Air.Instruction;
const Operand = Instruction.Operand;
const Tokenizer = @import("Tokenizer.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const case = @import("case.zig");

pub const max_line_width = 80;
pub const max_label_length = 20;

tokenizer: Tokenizer,
origin: ?Span,
symbols: elk.Provider.Symbols,

pub const parseInteger = @import("integers.zig").tryInteger;

pub fn new(
    traps: *const elk.Traps,
    source_: Source,
    reporter_: *Reporter,
) error{Reported}!Parser {
    for (source_.text, 0..) |char, i| {
        if (!Token.isValidChar(char)) {
            try reporter_.report(.invalid_source_byte, .{
                .byte = i,
            }).abort();
        }
    }

    return .{
        .tokenizer = .new(traps, source_, reporter_),
        .origin = null,
        .symbols = .empty,
    };
}

fn source(parser: *const Parser) Source {
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

/// Symbol entry strings have same lifetime as parser source.
/// Generated symbol table is not yet offset by `.ORIG`.
pub fn createSymbolTable(
    parser: *Parser,
    gpa: Allocator,
    symbols: *std.ArrayList(elk.Provider.Symbols.Entry),
) Allocator.Error!void {
    assert(symbols.items.len == 0);

    parser.tokenizer.reset();
    var index: u16 = 0;
    while (true) {
        const label_opt = parser.tokenizer.nextMatchingExcluding(
            .label,
            &.{.newline},
        ) catch |err| switch (err) {
            error.Reported => null, // Should be reported later
        };

        const token_opt = parser.tokenizer.nextExcluding(&.{.newline}) catch |err| switch (err) {
            error.Reported => null, // Should be reported later
            error.Eof => null,
        };

        if (label_opt) |label| {
            assert(label.value == .label);
            try symbols.append(gpa, .{ .address = index, .name = label.span.view(parser.source()) });
        }

        if (token_opt) |token| {
            switch (token.value) {
                .mnemonic => {
                    index += 1;
                },
                .directive => |directive| {
                    // TODO: Make this nicer
                    switch (directive) {
                        .fill => {
                            index += 1;
                        },
                        .blkw => {
                            if (parser.tokenizer.expectArgument(.unsigned_word)) |size| {
                                index += size.value;
                            } else |err| switch (err) {
                                error.Reported => {}, // Should be reported later
                            }
                        },
                        .stringz => {
                            if (parser.tokenizer.expectArgument(.string)) |string| {
                                const contents = string.value.in(string.span);
                                const contents_string = contents.view(parser.source());
                                const length = Token.Escaped.validLength(.double, contents_string) + 1; // Include NUL
                                index += @intCast(length);
                            } else |err| switch (err) {
                                error.Reported => {}, // Should be reported later
                            }
                        },
                        .orig => {},
                        .end => {},
                    }
                },
                // Invalid token, should be reported later
                .newline, .comma, .colon, .trap_alias, .label, .register, .integer, .string => {},
            }
        }

        parser.tokenizer.discardRemainingLine();
        if (token_opt == null)
            break;
    }

    parser.symbols = .{ .items = symbols.items };
}

pub fn parseAir(parser: *Parser, gpa: Allocator, air: *Air) Allocator.Error!void {
    var missing_end = false;

    parser.tokenizer.reset();
    while (true) {
        const control = parser.parseLine(gpa, air) catch |err| switch (err) {
            error.Reported => {
                parser.tokenizer.discardRemainingLine();
                // FIXME: Re-implement this behavior
                // _ = parser.removeCurrentLabel(air);
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

    if (parser.reporter().isLevelAtMost(.warn)) {
        if (parser.origin == null) {
            parser.reporter().report(.missing_origin, .{
                .first_token = parser.getFirstTokenSpan(),
            }).proceed(); // Can't return `error.Reported`
        }

        if (missing_end) {
            parser.reporter().report(.missing_end, .{
                .last_token = parser.tokenizer.latest,
            }).proceed(); // Can't return `error.Reported`
        }

        parser.checkLineWidths() catch
            {}; // Can't return `error.Reported`
    }

    air.assertLabelOrder();
}

fn checkLineWidths(parser: *Parser) error{Reported}!void {
    var result: error{Reported}!void = {};
    var lines = std.mem.splitScalar(u8, parser.source().text, '\n');
    while (lines.next()) |line| {
        if (line.len <= max_line_width)
            continue;
        const overflow = line[max_line_width..];

        parser.reporter().report(.line_too_long, .{
            .overflow = .{
                .offset = overflow.ptr - parser.source().text.ptr,
                .len = overflow.len,
            },
        }).collect(&result);
    }

    return result;
}

fn getFirstTokenSpan(parser: *const Parser) ?Span {
    var lexer: Lexer = .new(parser.source().text, true);
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
        .label => {},

        .directive => |directive| {
            const control = try parser.parseDirective(gpa, air, directive, token.span);
            try parser.tokenizer.expectEol();
            return control;
        },

        .mnemonic => |mnemonic| {
            var instruction = try parser.parseInstructionOperands(mnemonic, token.span);

            try elk.Provider.resolveOperand(
                .{ .symbols = parser.symbols },
                &instruction,
                air.lines.items.len,
                parser.source(),
                parser.reporter(),
            );

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
pub fn parseInstruction(parser: *Parser, index: usize) error{Reported}!Instruction {
    const token = parser.tokenizer.nextExcluding(&.{.newline}) catch |err| switch (err) {
        error.Reported => return error.Reported,
        error.Eof => unreachable,
    };

    switch (token.value) {
        .mnemonic => |mnemonic| {
            var instruction = try parser.parseInstructionOperands(mnemonic, token.span);

            try elk.Provider.resolveOperand(
                .{ .symbols = parser.symbols },
                &instruction,
                index,
                parser.source(),
                parser.reporter(),
            );

            try parser.tokenizer.expectEol();
            return instruction;
        },

        .trap_alias => |vect| {
            const instruction = Instruction{
                .trap = .{
                    .vect = .{
                        .span = token.span,
                        .value = .{
                            .immediate = .{ .integer = vect, .form = null },
                        },
                    },
                },
            };
            try parser.tokenizer.expectEol();
            return instruction;
        },

        else => {
            try parser.reporter().report(.unexpected_token_kind, .{
                .found = token,
                .expected = &.{.mnemonic},
            }).abort();
        },
    }
}

fn ensureCanAppendLines(parser: *Parser, air: *Air, n: usize, span: Span) error{TooLong}!void {
    if (air.origin + air.lines.items.len + n >= elk.Runtime.memory_size) {
        parser.reporter().report(.output_too_long, .{
            .statement = span,
        }).abort() catch
            return error.TooLong;
    }
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
            return .@"break";
        },

        .orig => {
            // FIXME: Re-implement this behavior
            // try parser.addLabel(gpa, air, token.span);
            // if (parser.removeCurrentLabel(air)) |label| {
            //     try parser.reporter().report(.invalid_label_target, .{
            //         .label = label,
            //         .target = span,
            //     }).handle();
            // }

            const origin = try parser.tokenizer.expectArgument(.unsigned_word);
            if (parser.origin) |existing| {
                try parser.reporter().report(.multiple_origins, .{
                    .existing = existing,
                    .new = origin.span,
                }).abort();
            }
            air.origin = origin.value;
            parser.origin = origin.span;

            if (air.lines.items.len > 0) {
                try parser.reporter().report(.late_origin, .{
                    .origin = origin.span,
                    .first_token = parser.getFirstTokenSpan(),
                }).abort();
            }
        },

        .fill => {
            const argument = try parser.tokenizer.expectArgument(.word_or_label);

            try parser.ensureCanAppendLines(air, 1, span);
            try air.lines.append(gpa, .{
                .statement = switch (argument.value) {
                    .word => |word| .{ .raw_word = word.underlying },
                    .label => .{ .unresolved_word = argument.span },
                },
                .span = argument.span,
            });
        },

        .blkw => {
            const size = try parser.tokenizer.expectArgument(.unsigned_word);
            if (size.value == 0)
                return .@"continue";
            try parser.ensureCanAppendLines(air, size.value, span);
            try air.lines.appendNTimes(gpa, .{
                .statement = .{ .raw_word = 0x0000 },
                .span = size.span,
            }, size.value);
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
