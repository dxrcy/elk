const std = @import("std");

const Policies = @import("../policies.zig").Policies;
const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");
const Radix = @import("../compile/parse/integers.zig").Form.Radix;
const Exception = @import("../emulate/Runtime.zig").Exception;
const DebuggerCommand = @import("../emulate/debugger/Command.zig");
const reporting = @import("reporting.zig");
const Options = reporting.Options;
const Level = reporting.Level;
const Response = reporting.Response;

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

    pub fn name(kind: Kind) []const u8 {
        return switch (kind) {
            .newline => "newline",
            .comma => "comma `,`",
            .colon => "colon `:`",
            .directive => "directive",
            .mnemonic => "instruction mnemonic",
            .trap_alias => "trap alias",
            .label => "label",
            .register => "register",
            .integer => "integer literal",
            .string => "string literal",
        };
    }
};

fn strictnessResponse(options: Options) Response {
    return switch (options.strictness) {
        .strict => .major,
        .normal => .minor,
        .relaxed => .pass,
    };
}

fn policyResponse(
    options: Options,
    comptime category: std.meta.FieldEnum(Policies),
    comptime name: std.meta.FieldEnum(@FieldType(Policies, @tagName(category))),
) reporting.Response {
    const policy = @field(@field(options.policies, @tagName(category)), @tagName(name));
    if (policy == .permit)
        return .pass;
    return strictnessResponse(options);
}

pub const Diagnostic = union(enum) {
    // TODO: Prefix all fields with `compile_`, `debugger_`, etc ?????

    // Assembly file
    invalid_source_byte: struct { byte: usize },
    output_too_long: struct { statement: Span },
    line_too_long: struct { overflow: Span },

    // Misc tokens, statements
    invalid_token: struct { token: Span, guess: ?TokenKinds.Kind },
    // TODO: Replace `[]const TokenKinds.Kind` with `TokenKinds`, and elsewhere
    unexpected_token_kind: struct { found: Token, expected: []const TokenKinds.Kind },
    unexpected_eol: struct { eol: Span, expected: []const TokenKinds.Kind },
    expected_eol: struct { found: Token },
    missing_operand_comma: struct { operand: Span },
    whitespace_comma: struct { comma: Span },
    unconventional_case: struct { token: Span, kind: enum { directive, mnemonic, trap_alias, label, register, integer_prefix, integer_digits } },

    // Directives
    unsupported_directive: struct { directive: Span },
    multiple_origins: struct { existing: Span, new: Span },
    late_origin: struct { origin: Span, first_token: ?Span },
    missing_origin: struct { first_token: ?Span },
    missing_end: struct { last_token: ?Span },

    // Label syntax and resolution
    existing_label_left: struct { existing: Span, new: Span },
    existing_label_above: struct { existing: Span, new: Span },
    invalid_label_target: struct { label: Span, target: ?Span },
    label_colon: struct { colon: Span },
    redefined_label: struct { existing: Span, new: Span },
    undefined_label: struct { reference: Span, nearest: ?Span, definition_source: []const u8 },
    unused_label: struct { label: Span },

    // Integer syntax
    malformed_integer: struct { integer: Span },
    malformed_character: struct { integer: Span },
    expected_digit: struct { integer: Span },
    invalid_digit: struct { integer: Span },
    unexpected_delimiter: struct { integer: Span },
    nonstandard_integer_radix: struct { integer: Span, radix: Radix },
    nonstandard_integer_form: struct { integer: Span, reason: enum { delimiter } },
    undesirable_integer_form: struct { integer: Span, reason: enum { missing_zero, pre_radix_sign, post_radix_sign, implicit_radix } },
    character_integer: struct { integer: Span },

    // Integer bounds
    integer_too_large: struct { integer: Span, type_info: std.builtin.Type.Int },
    offset_too_large: struct { definition: Span, reference: Span, offset: i17, bits: u16, definition_source: []const u8 },
    unexpected_negative_integer: struct { integer: Span },

    // Strings
    unmatched_quote: struct { string: Span },
    invalid_string_escape: struct { string: Span, sequence: Span },
    multiline_string: struct { string: Span },

    // Instruction-specific
    stack_instruction: struct { mnemonic: Span, kind: Token.Value.Mnemonic },
    literal_pc_offset: struct { integer: Span },
    explicit_trap_vect: struct { vect: Span, value: u8, alias: []const u8 },
    undeclared_trap_vect: struct { vect: Span, value: u8 },

    // Emulator
    emulate_exception: struct { code: Exception },

    // Emulator debugger
    // TODO: Reorder
    // TODO: Distinguish command vs label
    debugger_requires_assembly: struct { command: Span },
    debugger_requires_state: struct { command: Span },
    debugger_address_not_in_assembly: struct { value: u16, max: u16 },
    debugger_address_not_user_memory: struct { address: Span, value: u16, max: u16 },
    debugger_label_partial_match: struct { reference: Span, nearest: Span, definition_source: []const u8 },
    debugger_no_space: struct {},
    // TODO: Add `expected` field (different type than `TokenKinds`), AND ELSEWHERE
    debugger_invalid_argument_kind: struct { found: Span },
    debugger_invalid_command: struct { command: Span, nearest: ?DebuggerCommand.Tag },
    debugger_missing_subcommand: struct { first: Span, eol: Span },
    // TODO: Rename ? not eol but end of command
    debugger_unexpected_eol: struct { eol: Span },
    debugger_expected_eol: struct { found: Span },
    debugger_integer_too_small: struct { integer: Span, minimum: u16 },

    pub fn getResponse(diag: Diagnostic, options: Options) Response {
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
            .redefined_label,
            .undefined_label,
            .malformed_integer,
            .malformed_character,
            .expected_digit,
            .invalid_digit,
            .unexpected_delimiter,
            .integer_too_large,
            .offset_too_large,
            .unexpected_negative_integer,
            .unmatched_quote,
            => .fatal,

            .existing_label_left => .major,

            .invalid_label_target,
            .invalid_string_escape,
            => strictnessResponse(options),

            .missing_origin => policyResponse(options, .extension, .implicit_origin),
            .missing_end => policyResponse(options, .extension, .implicit_end),
            .existing_label_above => policyResponse(options, .extension, .multiple_labels),
            .label_colon => policyResponse(options, .extension, .label_definition_colons),
            .nonstandard_integer_radix => policyResponse(options, .extension, .more_integer_radixes),
            .nonstandard_integer_form => policyResponse(options, .extension, .more_integer_forms),
            .multiline_string => policyResponse(options, .extension, .multiline_strings),
            .stack_instruction => policyResponse(options, .extension, .stack_instructions),
            .character_integer => policyResponse(options, .extension, .character_literals),

            .literal_pc_offset => policyResponse(options, .smell, .pc_offset_literals),
            .explicit_trap_vect => policyResponse(options, .smell, .explicit_trap_instructions),
            .undeclared_trap_vect => policyResponse(options, .smell, .unknown_trap_vectors),
            .unused_label => policyResponse(options, .smell, .unused_label_definitions),

            .missing_operand_comma => policyResponse(options, .style, .missing_operand_commas),
            .whitespace_comma => policyResponse(options, .style, .whitespace_commas),
            .unconventional_case => |info| switch (info.kind) {
                .directive => policyResponse(options, .case, .directives),
                .mnemonic => policyResponse(options, .case, .mnemonics),
                .trap_alias => policyResponse(options, .case, .trap_aliases),
                .label => policyResponse(options, .case, .labels),
                .register => policyResponse(options, .case, .registers),
                .integer_prefix, .integer_digits => policyResponse(options, .case, .integers),
            },
            .undesirable_integer_form => policyResponse(options, .style, .undesirable_integer_forms),
            .line_too_long => policyResponse(options, .style, .line_too_long),

            .emulate_exception => .fatal,

            .debugger_requires_assembly => .fatal,
            .debugger_requires_state => .fatal,
            .debugger_address_not_in_assembly => .fatal,
            .debugger_address_not_user_memory => .fatal,
            .debugger_label_partial_match => .major,
            .debugger_no_space => .fatal,
            .debugger_invalid_argument_kind => .fatal,
            .debugger_invalid_command => .fatal,
            .debugger_missing_subcommand => .fatal,
            .debugger_unexpected_eol => .fatal,
            .debugger_expected_eol => .fatal,
            .debugger_integer_too_small => .fatal,
        };
    }
};
