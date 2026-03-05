const std = @import("std");

const Policies = @import("../Policies.zig");
const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");
const Radix = @import("../compile/parse/integers.zig").Form.Radix;
const Reporter = @import("Reporter.zig");
const Ctx = @import("Ctx.zig");

pub const TokenKinds = struct {
    kinds: []const Kind,

    const Kind = std.meta.Tag(Token.Value);

    pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
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

    fn name(kind: Kind) []const u8 {
        return switch (kind) {
            .newline => "newline",
            .comma => "comma `,`",
            .colon => "colon `:`",
            .directive => "directive",
            .instruction => "instruction",
            .trap_alias => "trap alias",
            .label => "label",
            .register => "register",
            .integer => "integer literal",
            .string => "string literal",
        };
    }
};

fn strictnessResponse(options: Reporter.Options) Reporter.Response {
    return switch (options.strictness) {
        .strict => .major,
        .normal => .minor,
        .relaxed => .pass,
    };
}

fn policyResponse(
    options: Reporter.Options,
    comptime category: std.meta.FieldEnum(Policies),
    comptime name: std.meta.FieldEnum(@FieldType(Policies, @tagName(category))),
) Reporter.Response {
    const policy = @field(@field(options.policies, @tagName(category)), @tagName(name));
    if (policy == .permit)
        return .pass;
    return strictnessResponse(options);
}

pub const Diagnostic = union(enum) {
    // Assembly file
    invalid_source_byte: struct { byte: usize },
    output_too_long: struct { statement: Span },

    // Misc tokens, statements
    invalid_token: struct { token: Span, guess: ?TokenKinds.Kind },
    unexpected_token_kind: struct { found: Token, expected: []const TokenKinds.Kind },
    unexpected_eol: struct { eol: Span, expected: []const TokenKinds.Kind },
    expected_eol: struct { found: Token },
    missing_operand_comma: struct { operand: Span },
    whitespace_comma: struct { comma: Span },
    unconventional_case: struct { token: Span, kind: enum { directive, instruction, label, register, integer } },

    // Directives
    unsupported_directive: struct { directive: Span },
    multiple_origins: struct { existing: Span, new: Span },
    late_origin: struct { origin: Span, first_token: ?Span },
    missing_origin: struct { first_token: ?Span },
    missing_end: struct { last_token: ?Span },

    // Label syntax and resolution
    multiple_labels: struct { existing: Span, new: Span },
    invalid_label_target: struct { label: Span, target: ?Span },
    shadowed_label: struct { existing: Span, new: Span },
    label_colon: struct { colon: Span },
    redeclared_label: struct { existing: Span, new: Span },
    undeclared_label: struct { reference: Span, nearest: ?Span },

    // Integer syntax
    malformed_integer: struct { integer: Span },
    expected_digit: struct { integer: Span },
    invalid_digit: struct { integer: Span },
    unexpected_delimiter: struct { integer: Span },
    nonstandard_integer_radix: struct { integer: Span, radix: Radix },
    nonstandard_integer_form: struct { integer: Span, reason: enum { delimiter } },
    undesirable_integer_form: struct { integer: Span, reason: enum { missing_zero, pre_radix_sign, post_radix_sign, implicit_radix } },

    // Integer bounds
    integer_too_large: struct { integer: Span, type_info: std.builtin.Type.Int },
    offset_too_large: struct { definition: Span, reference: Span, offset: i17, bits: u16 },
    unexpected_negative_integer: struct { integer: Span },

    // Strings
    unmatched_quote: struct { string: Span },
    invalid_string_escape: struct { string: Span, sequence: Span },
    multiline_string: struct { string: Span },

    // Instruction-specific
    stack_instruction: struct { instruction: Span, kind: Token.Value.Instruction },
    literal_pc_offset: struct { integer: Span },
    explicit_trap_vect: struct { vect: Span, value: u8, alias: []const u8 },
    undeclared_trap_vect: struct { vect: Span, value: u8 },

    pub fn getResponse(diag: Diagnostic, options: Reporter.Options) Reporter.Response {
        return switch (diag) {
            .invalid_source_byte,
            .output_too_long,
            .invalid_token,
            .unexpected_token_kind,
            .unexpected_eol,
            .expected_eol,
            .unsupported_directive,
            .multiple_origins,
            .late_origin,
            .redeclared_label,
            .undeclared_label,
            .malformed_integer,
            .expected_digit,
            .invalid_digit,
            .unexpected_delimiter,
            .integer_too_large,
            .offset_too_large,
            .unexpected_negative_integer,
            .unmatched_quote,
            => .fatal,

            .multiple_labels => .major,

            .invalid_label_target,
            .shadowed_label,
            .invalid_string_escape,
            => strictnessResponse(options),

            .missing_origin => policyResponse(options, .extension, .implicit_origin),
            .missing_end => policyResponse(options, .extension, .implicit_end),
            .label_colon => policyResponse(options, .extension, .label_declaration_colons),
            .nonstandard_integer_radix => policyResponse(options, .extension, .more_integer_radixes),
            .nonstandard_integer_form => policyResponse(options, .extension, .more_integer_forms),
            .multiline_string => policyResponse(options, .extension, .multiline_strings),
            .stack_instruction => policyResponse(options, .extension, .stack_instructions),

            .literal_pc_offset => policyResponse(options, .smell, .pc_offset_literals),
            .explicit_trap_vect => policyResponse(options, .smell, .explicit_trap_instructions),
            .undeclared_trap_vect => policyResponse(options, .smell, .unknown_trap_vectors),

            .missing_operand_comma => policyResponse(options, .style, .missing_operand_commas),
            .whitespace_comma => policyResponse(options, .style, .whitespace_commas),
            .unconventional_case => |info| switch (info.kind) {
                .directive => policyResponse(options, .style, .unconventional_case_directives),
                .instruction => policyResponse(options, .style, .unconventional_case_instructions),
                .label => policyResponse(options, .style, .unconventional_case_labels),
                .register => policyResponse(options, .style, .unconventional_case_registers),
                .integer => policyResponse(options, .style, .unconventional_case_integers),
            },
            .undesirable_integer_form => policyResponse(options, .style, .undesirable_integer_forms),
        };
    }

    pub fn print(diag: Diagnostic, ctx: Ctx, source: []const u8) void {
        switch (diag) {
            .invalid_source_byte => |info| {
                ctx.printTitle("Assembly file contains invalid bytes", .{});
                ctx.deepen().printSourceNote("Byte", .{}, .{ .offset = info.byte, .len = 1 });
                ctx.deepen().printNote("Assembly file must only contain printable ASCII characters", .{});
                ctx.deepen().printNote("The assembler cannot read object files", .{});
            },
            .output_too_long => |info| {
                ctx.printTitle("Assembly file would emit too many words", .{});
                ctx.deepen().printSourceNote("Line", .{}, info.statement);
                ctx.deepen().printNote("Object files cannot contain more than 0xffff words", .{});
            },

            .invalid_token => |info| {
                ctx.printTitle("Invalid token", .{});
                ctx.deepen().printSourceNote("Token", .{}, info.token);
                if (info.guess) |kind|
                    ctx.deepen().printNote("Cannot parse as {s}", .{TokenKinds.name(kind)})
                else
                    ctx.deepen().printNote("Cannot parse as any valid token", .{});
            },
            .unexpected_token_kind => |info| {
                ctx.printTitle("Unexpected {s}", .{TokenKinds.name(info.found.value)});
                ctx.deepen().printSourceNote("Token", .{}, info.found.span);
                ctx.deepen().printNote("Expected {f}", .{TokenKinds{ .kinds = info.expected }});
            },
            .unexpected_eol => |info| {
                ctx.printTitle("Unexpected end of line", .{});
                ctx.deepen().printSourceNote("Line ends too early", .{}, info.eol);
                ctx.deepen().printNote("Expected {f}", .{TokenKinds{ .kinds = info.expected }});
                ctx.deepen().printNote("Instructions cannot span multiple lines", .{});
            },
            .expected_eol => |info| {
                ctx.printTitle("Unexpected {s}", .{TokenKinds.name(info.found.value)});
                ctx.deepen().printSourceNote("Token", .{}, info.found.span);
                ctx.deepen().printNote("Expected end of line", .{});
            },
            .missing_operand_comma => |info| {
                ctx.printTitle("Missing comma `,` after operand", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.operand);
                ctx.deepen().printNote("Operands should be separated with commas", .{});
            },
            .whitespace_comma => |info| {
                ctx.printTitle("Unexpected comma `,`", .{});
                ctx.deepen().printSourceNote("Comma", .{}, info.comma);
                ctx.deepen().printNote("Commas should only appear between instruction operands", .{});
            },
            .unconventional_case => |info| switch (info.kind) {
                .instruction => {
                    ctx.printTitle("Instruction mnemonic is not lowercase", .{});
                    ctx.deepen().printSourceNote("Mnemonic", .{}, info.token);
                },
                .directive => {
                    ctx.printTitle("Directive name is not uppercase", .{});
                    ctx.deepen().printSourceNote("Directive", .{}, info.token);
                },
                .label => {
                    ctx.printTitle("Label name is not PascalCase", .{});
                    ctx.deepen().printSourceNote("Label declared here", .{}, info.token);
                },
                .register => {
                    ctx.printTitle("Register name is not lowercase", .{});
                    ctx.deepen().printSourceNote("Register", .{}, info.token);
                },
                .integer => {
                    ctx.printTitle("Integer does not use lowercase letters", .{});
                    ctx.deepen().printSourceNote("Integer", .{}, info.token);
                },
            },

            .unsupported_directive => |info| {
                ctx.printTitle("Directive is not supported", .{});
                ctx.deepen().printSourceNote("Tried to use directive here", .{}, info.directive);
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
            .missing_origin => |info| {
                ctx.printTitle("Missing .ORIG directive", .{});
                ctx.deepen().printSourceNote(
                    "Origin should be declared before any instructions",
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

            .multiple_labels => |info| {
                ctx.printTitle("Multiple labels cannot be declared on the same line", .{});
                ctx.deepen().printSourceNote("First label declared here", .{}, info.existing);
                ctx.deepen().printSourceNote("Another label declared on the same line", .{}, info.new);
            },
            .invalid_label_target => |info| {
                ctx.printTitle("Label is useless in this position", .{});
                ctx.deepen().printSourceNote("Label declared here", .{}, info.label);
                if (info.target) |target|
                    ctx.deepen().printSourceNote("Token cannot be annotated with label", .{}, target)
                else
                    ctx.deepen().printSourceNote("Label is not followed by any token", .{}, .lastCharOf(source));
            },
            .shadowed_label => |info| {
                ctx.printTitle("Shadowed label has no use", .{});
                ctx.deepen().printSourceNote("First label declared here", .{}, info.existing);
                ctx.deepen().printSourceNote("Another label declared in the same position", .{}, info.new);
            },
            .label_colon => |info| {
                ctx.printTitle("Label followed by colon `:`", .{});
                ctx.deepen().printSourceNote("Colon", .{}, info.colon);
                ctx.deepen().printNote("A post-label colon is non-standard syntax", .{});
            },

            .redeclared_label => |info| {
                ctx.printTitle("Label already declared", .{});
                ctx.deepen().printSourceNote("Label is first declared here", .{}, info.existing);
                ctx.deepen().printSourceNote("Tried to redeclare here", .{}, info.new);
            },
            .undeclared_label => |info| {
                ctx.printTitle("Label is not declared", .{});
                ctx.deepen().printSourceNote("Label used here", .{}, info.reference);
                if (info.nearest) |close_match| {
                    ctx.deepen().printSourceNote("This label declaration is similar", .{}, close_match);
                    ctx.deepen().printNote("Label names are case-sensitive", .{});
                }
            },

            .malformed_integer => |info| {
                ctx.printTitle("Malformed integer operand", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.integer);
                ctx.deepen().printNote("Integer token is not in an valid form", .{});
            },
            .expected_digit => |info| {
                ctx.printTitle("Expected digit in integer operand", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.integer);
                ctx.deepen().printNote("Integer token ended unexpectedly", .{});
            },
            .invalid_digit => |info| {
                ctx.printTitle("Invalid digit in integer operand", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.integer);
                ctx.deepen().printNote("Integer token contains a character which is not valid in the base", .{});
            },
            .unexpected_delimiter => |info| {
                ctx.printTitle("Unexpected digit delimiter in integer operand", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.integer);
                ctx.deepen().printNote("Delimiter character `_` must appear between digits", .{});
            },
            .nonstandard_integer_radix => |info| {
                ctx.printTitle("Integer uses non-standard base specifier '{t}'", .{info.radix});
                ctx.deepen().printSourceNote("Integer", .{}, info.integer);
            },
            .nonstandard_integer_form => |info| {
                ctx.printTitle("Integer uses non-standard syntax", .{});
                ctx.deepen().printSourceNote("Integer", .{}, info.integer);
                ctx.deepen().printNote("{s}", .{switch (info.reason) {
                    .delimiter => "Delimiter character `_` is non-standard",
                }});
            },
            .undesirable_integer_form => |info| {
                ctx.printTitle("Integer uses undesirable syntax", .{});
                ctx.deepen().printSourceNote("Integer", .{}, info.integer);
                ctx.deepen().printNote("{s}", .{switch (info.reason) {
                    .missing_zero => "Leading zero should appear before base specifier",
                    .pre_radix_sign => "Sign character should appear after decimal base specifier",
                    .post_radix_sign => "Sign character should appear before non-decimal base specifier",
                    .implicit_radix => "Decimal integer literal should begin with `#`",
                }});
            },

            .integer_too_large => |info| {
                ctx.printTitle("Integer operand is too large", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.integer);
                ctx.deepen().printNote("Value cannot be represented in {} bits", .{info.type_info.bits});
                if (info.type_info.signedness == .signed) {
                    ctx.deepen().printNote("Since the operand is a signed integer, the highest bit is reserved as the sign bit", .{});
                }
            },
            .offset_too_large => |info| {
                ctx.printTitle("Calculated label offset is too large", .{});
                ctx.deepen().printSourceNote("Label declared here", .{}, info.definition);
                ctx.deepen().printSourceNote("Label used here", .{}, info.reference);
                ctx.deepen().printNote("Address offset of {} words cannot be represented in {} bits", .{ info.offset, info.bits });
            },
            .unexpected_negative_integer => |info| {
                ctx.printTitle("Integer operand cannot be negative", .{});
                ctx.deepen().printSourceNote("Operand", .{}, info.integer);
            },

            .unmatched_quote => |info| {
                ctx.printTitle("String literal does not end with quote `\"`", .{});
                ctx.deepen().printSourceNote("String is used here", .{}, info.string);
                ctx.deepen().printNote("Strings do not automatically stop at end of line", .{});
            },
            .invalid_string_escape => |info| {
                ctx.printTitle("Invalid escape sequence", .{});
                ctx.deepen().printSourceNote("String", .{}, info.string);
                ctx.deepen().printSourceNote("Erroneous escape sequence", .{}, info.sequence);
            },
            .multiline_string => |info| {
                ctx.printTitle("String covers multiple lines", .{});
                ctx.deepen().printSourceNote("String", .{}, info.string);
            },

            .stack_instruction => |info| {
                ctx.printTitle("Use of non-standard stack instruction `{t}`", .{info.kind});
                ctx.deepen().printSourceNote("Instruction is an ISA extension", .{}, info.instruction);
            },
            .literal_pc_offset => |info| {
                ctx.printTitle("Address operand is a literal offset", .{});
                ctx.deepen().printSourceNote("Integer", .{}, info.integer);
                ctx.deepen().printNote("PC-offset operand should be a label reference, instead of hardcoded offset value", .{});
            },
            .explicit_trap_vect => |info| {
                ctx.printTitle("Use of trap instruction with explicit vector operand", .{});
                ctx.deepen().printSourceNote("Trap vector", .{}, info.vect);
                ctx.deepen().printNote("Consider using trap alias `{s}`", .{info.alias});
            },
            .undeclared_trap_vect => |info| {
                ctx.printTitle("Use of unknown trap vector 0x{x:02}", .{info.value});
                ctx.deepen().printSourceNote("Trap vector", .{}, info.vect);
                ctx.deepen().printNote("Traps vector 0x{x:02} is not recognized", .{info.value});
            },
        }

        switch (ctx.reporter.verbosity) {
            .normal => {
                ctx.print("\n", .{});
            },
            .quiet => {},
        }
    }
};
