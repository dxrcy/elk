const Ctx = @This();

const std = @import("std");
const Io = std.Io;

const Span = @import("../compile/Span.zig");
const Parser = @import("../compile/parse/Parser.zig");
const Token = @import("../compile/parse/Token.zig");
const DebuggerCommand = @import("../emulate/debugger/Command.zig");
const reporting = @import("reporting.zig");
const Reporter = reporting.Reporter;
const Verbosity = reporting.Options.Verbosity;
const Level = reporting.Level;
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;
const TokenKinds = diagnostic.TokenKinds;

writer: *Io.Writer,
verbosity: Verbosity,
level: ?Level,
depth: usize,
item_count: ?*usize,
source: ?[]const u8,

const indent_width = 4;

pub fn new(
    writer: *Io.Writer,
    verbosity: Verbosity,
    level: ?Level,
    item_count: ?*usize,
    source: ?[]const u8,
) Ctx {
    return .{
        .writer = writer,
        .verbosity = verbosity,
        .level = level,
        .depth = 0,
        .item_count = item_count,
        .source = source,
    };
}

fn deepen(ctx: Ctx) Ctx {
    var new_ctx = ctx;
    new_ctx.depth += 1;
    return new_ctx;
}

fn withSource(ctx: Ctx, source: []const u8) Ctx {
    var new_ctx = ctx;
    new_ctx.source = source;
    return new_ctx;
}

fn incrementItemCount(ctx: *const Ctx) void {
    if (ctx.item_count) |count|
        count.* += 1;
}

fn writeDepth(ctx: Ctx) error{WriteFailed}!void {
    for (0..ctx.depth) |_|
        try ctx.writer.print(" " ** indent_width, .{});
}

fn writeTitle(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
) error{WriteFailed}!void {
    defer ctx.incrementItemCount();

    const level = ctx.level orelse
        unreachable;
    try ctx.writeDepth();
    switch (level) {
        .err => {
            try ctx.writer.print("\x1b[31m", .{});
            try ctx.writer.print("\x1b[1m", .{});
            try ctx.writer.print("Error: ", .{});
            try ctx.writer.print("\x1b[0m", .{});
        },
        .warn => {
            try ctx.writer.print("\x1b[33m", .{});
            try ctx.writer.print("\x1b[1m", .{});
            try ctx.writer.print("Warning: ", .{});
            try ctx.writer.print("\x1b[0m", .{});
        },
        .info => {
            try ctx.writer.print("\x1b[34m", .{});
            try ctx.writer.print("\x1b[1m", .{});
            try ctx.writer.print("Info: ", .{});
            try ctx.writer.print("\x1b[0m", .{});
        },
    }

    try ctx.writer.print(fmt, args);

    switch (ctx.verbosity) {
        .normal => {
            try ctx.writer.print("\n", .{});
        },
        .quiet => {},
    }
}

fn writeNote(ctx: Ctx, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
    defer ctx.incrementItemCount();

    switch (ctx.verbosity) {
        .normal => {},
        .quiet => return,
    }

    try ctx.writeDepth();
    try ctx.writer.print("\x1b[36m", .{});
    try ctx.writer.print("Note: ", .{});
    try ctx.writer.print("\x1b[0m", .{});
    try ctx.writer.print(fmt, args);
    try ctx.writer.print("\n", .{});
}

fn writeSourceNote(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
    span: Span,
) error{WriteFailed}!void {
    try ctx.writeNote(fmt ++ ": ", args);
    try ctx.writeSource(span);
}

fn writeSource(ctx: Ctx, span: Span) error{WriteFailed}!void {
    const source = ctx.source orelse
        unreachable;

    switch (ctx.verbosity) {
        .normal => {},
        .quiet => {
            // Scuffed!
            if (if (ctx.item_count) |count| count.* > 2 else true)
                return;

            const start_line = span.getLineNumber(source);
            const end_line = span.getEndLineNumber(source);
            const start_column = span.getColumnNumber(source);
            const end_column = span.getEndColumnNumber(source);

            try ctx.writer.print(" (Line {}:{}-{}:{})", .{
                start_line, start_column, end_line, end_column,
            });
            try ctx.writer.print("\n", .{});
            return;
        },
    }

    try writeSpanContext(ctx.writer, span, .{
        .indent = ctx.depth * indent_width,
        .max_line_width = 90,
    }, source);
}

pub fn writeSpanContext(
    writer: *std.Io.Writer,
    span: Span,
    config: struct {
        indent: usize = 0,
        max_context: usize = 1,
        max_line_width: usize = 80,
    },
    source: []const u8,
) error{WriteFailed}!void {
    const lines = span.getSurroundingLines(config.max_context, source);
    var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
    while (iter.next()) |line_string_full| {
        const line_string = line_string_full[0..@min(line_string_full.len, config.max_line_width)];
        const is_truncated = line_string_full.len > config.max_line_width;

        const line = Span.fromSlice(line_string, source);
        const line_number = line.getLineNumber(source);

        for (0..config.indent) |_|
            try writer.print(" ", .{});

        try writer.print("\x1b[2m", .{});
        try writer.print("{:3} ", .{line_number});
        try writer.print("| ", .{});
        try writer.print("\x1b[0m", .{});
        try writer.print("\x1b[3m", .{});
        try writer.print("\x1b[2m", .{});

        {
            var was_in_span = false;
            var was_non_valid = false;

            for (line_string, 0..) |char, i| {
                const index = line.offset + i;

                const in_span = span.containsIndex(index);
                if (in_span and !was_in_span)
                    try writer.print("\x1b[22m", .{})
                else if (!in_span and was_in_span)
                    try writer.print("\x1b[2m", .{});

                const non_valid = Token.isValidChar(char);
                if (!non_valid and was_non_valid)
                    try writer.print("\x1b[31m", .{})
                else if (non_valid and !was_non_valid)
                    try writer.print("\x1b[39m", .{});

                if (non_valid)
                    try writer.print("{c}", .{char})
                else
                    try writer.print("?", .{});

                was_in_span = in_span;
                was_non_valid = non_valid;
            }
        }

        if (is_truncated) {
            try writer.print("\x1b[0m", .{});
            try writer.print("\x1b[36;2m", .{});
            try writer.print("...", .{});
        }

        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});

        if (!line.overlaps(span) or
            std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0)
        {
            continue;
        }

        for (0..config.indent) |_|
            try writer.print(" ", .{});

        try writer.print("\x1b[2m", .{});
        try writer.print("    | ", .{});
        try writer.print("\x1b[22m", .{});
        try writer.print("\x1b[36m", .{});
        for (0..line_string.len + 1) |i| {
            const index = line.offset + i;
            if (span.containsIndex(index) or
                // Still highlight first character if len==0
                span.offset == index)
                try writer.print("^", .{})
            else
                try writer.print(" ", .{});
        }
        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});
    }
}

pub fn writeDiagnostic(ctx: Ctx, diag: Diagnostic) error{WriteFailed}!void {
    const source = ctx.source orelse
        unreachable;

    switch (diag) {
        .invalid_source_byte => |info| {
            try ctx.writeTitle("Assembly file contains invalid bytes", .{});
            try ctx.deepen().writeSourceNote("Byte", .{}, .{ .offset = info.byte, .len = 1 });
            try ctx.deepen().writeNote("Assembly file must only contain printable ASCII characters", .{});
            try ctx.deepen().writeNote("The assembler cannot read object files", .{});
        },
        .output_too_long => |info| {
            try ctx.writeTitle("Assembly file would emit too many words", .{});
            try ctx.deepen().writeSourceNote("Line", .{}, info.statement);
            try ctx.deepen().writeNote("Object files cannot contain more than 0xffff words", .{});
        },
        .line_too_long => |info| {
            try ctx.writeTitle("Line is longer than {} characters", .{Parser.max_line_width});
            try ctx.deepen().writeSourceNote("Characters past column limit", .{}, info.overflow);
        },

        .invalid_token => |info| {
            try ctx.writeTitle("Invalid token", .{});
            try ctx.deepen().writeSourceNote("Token", .{}, info.token);
            if (info.guess) |kind|
                try ctx.deepen().writeNote("Cannot parse as {s}", .{TokenKinds.name(kind)})
            else
                try ctx.deepen().writeNote("Cannot parse as any valid token", .{});
        },
        .unexpected_token_kind => |info| {
            try ctx.writeTitle("Unexpected {s}", .{TokenKinds.name(info.found.value)});
            try ctx.deepen().writeSourceNote("Token", .{}, info.found.span);
            try ctx.deepen().writeNote("Expected {f}", .{TokenKinds{ .kinds = info.expected }});
        },
        .unexpected_eol => |info| {
            try ctx.writeTitle("Unexpected end of line", .{});
            try ctx.deepen().writeSourceNote("Line ends too early", .{}, info.eol);
            try ctx.deepen().writeNote("Expected {f}", .{TokenKinds{ .kinds = info.expected }});
            try ctx.deepen().writeNote("Instructions cannot span multiple lines", .{});
        },
        .expected_eol => |info| {
            try ctx.writeTitle("Unexpected {s}", .{TokenKinds.name(info.found.value)});
            try ctx.deepen().writeSourceNote("Token", .{}, info.found.span);
            try ctx.deepen().writeNote("Expected end of line", .{});
        },
        .missing_operand_comma => |info| {
            try ctx.writeTitle("Missing comma `,` after operand", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.operand);
            try ctx.deepen().writeNote("Operands should be separated with commas", .{});
        },
        .whitespace_comma => |info| {
            try ctx.writeTitle("Unexpected comma `,`", .{});
            try ctx.deepen().writeSourceNote("Comma", .{}, info.comma);
            try ctx.deepen().writeNote("Commas should only appear between instruction operands", .{});
        },
        .unconventional_case => |info| switch (info.kind) {
            .mnemonic => {
                try ctx.writeTitle("Instruction mnemonic is not lowercase", .{});
                try ctx.deepen().writeSourceNote("Mnemonic", .{}, info.token);
            },
            .trap_alias => {
                try ctx.writeTitle("Trap instruction alias is not lowercase", .{});
                try ctx.deepen().writeSourceNote("Trap alias", .{}, info.token);
            },
            .directive => {
                try ctx.writeTitle("Directive name is not uppercase", .{});
                try ctx.deepen().writeSourceNote("Directive", .{}, info.token);
            },
            .label => {
                try ctx.writeTitle("Label name is not PascalCase", .{});
                try ctx.deepen().writeSourceNote("Label declared here", .{}, info.token);
            },
            .register => {
                try ctx.writeTitle("Register name is not lowercase", .{});
                try ctx.deepen().writeSourceNote("Register", .{}, info.token);
            },
            .integer_prefix => {
                try ctx.writeTitle("Integer prefix is not lowercase", .{});
                try ctx.deepen().writeSourceNote("Integer", .{}, info.token);
            },
            .integer_digits => {
                try ctx.writeTitle("Integer does not use uppercase letters", .{});
                try ctx.deepen().writeSourceNote("Integer", .{}, info.token);
            },
        },

        .unsupported_directive => |info| {
            try ctx.writeTitle("Directive is not supported", .{});
            try ctx.deepen().writeSourceNote("Tried to use directive here", .{}, info.directive);
        },
        .multiple_origins => |info| {
            try ctx.writeTitle("Multiple .ORIG directives", .{});
            try ctx.deepen().writeSourceNote("First declared here", .{}, info.existing);
            try ctx.deepen().writeSourceNote("Tried to redeclare here", .{}, info.new);
        },
        .late_origin => |info| {
            try ctx.writeTitle("Origin declared after statements", .{});
            try ctx.deepen().writeSourceNote("Origin declared here", .{}, info.origin);
            try ctx.deepen().writeSourceNote(
                "Origin must be declared at start of file",
                .{},
                info.first_token orelse .firstCharOf(source),
            );
        },
        .missing_origin => |info| {
            try ctx.writeTitle("Missing .ORIG directive", .{});
            try ctx.deepen().writeSourceNote(
                "Origin should be declared before any instructions",
                .{},
                info.first_token orelse .firstCharOf(source),
            );
        },
        .missing_end => |info| {
            try ctx.writeTitle("Missing .END directive", .{});
            try ctx.deepen().writeSourceNote(
                "End should be declared after included all instructions",
                .{},
                info.last_token orelse .lastCharOf(source),
            );
        },

        .existing_label_left => |info| {
            try ctx.writeTitle("Multiple labels cannot be declared on the same line", .{});
            try ctx.deepen().writeSourceNote("First label declared here", .{}, info.existing);
            try ctx.deepen().writeSourceNote("Another label declared on the same line", .{}, info.new);
        },
        .existing_label_above => |info| {
            try ctx.writeTitle("Line is annotated with multiple labels", .{});
            try ctx.deepen().writeSourceNote("First label declared here", .{}, info.existing);
            try ctx.deepen().writeSourceNote("Another label declared in the same position", .{}, info.new);
        },
        .invalid_label_target => |info| {
            try ctx.writeTitle("Label is useless in this position", .{});
            try ctx.deepen().writeSourceNote("Label declared here", .{}, info.label);
            if (info.target) |target|
                try ctx.deepen().writeSourceNote("Token cannot be annotated with label", .{}, target)
            else
                try ctx.deepen().writeSourceNote("Label is not followed by any token", .{}, .lastCharOf(source));
        },
        .label_colon => |info| {
            try ctx.writeTitle("Label followed by colon `:`", .{});
            try ctx.deepen().writeSourceNote("Colon", .{}, info.colon);
            try ctx.deepen().writeNote("A post-label colon is non-standard syntax", .{});
        },

        .redefined_label => |info| {
            try ctx.writeTitle("Label already declared", .{});
            try ctx.deepen().writeSourceNote("Label is first declared here", .{}, info.existing);
            try ctx.deepen().writeSourceNote("Tried to redeclare here", .{}, info.new);
        },
        .undefined_label => |info| {
            try ctx.writeTitle("Label is not declared", .{});
            try ctx.deepen().writeSourceNote("Label used here", .{}, info.reference);
            if (info.nearest) |close_match| {
                try ctx.deepen().withSource(info.definition_source)
                    .writeSourceNote("This label declaration is similar", .{}, close_match);
                try ctx.deepen().writeNote("Label names are case-sensitive", .{});
            }
        },
        .unused_label => |info| {
            try ctx.writeTitle("Label declaration is not used", .{});
            try ctx.deepen().writeSourceNote("Label declared here", .{}, info.label);
        },

        // TODO: Change "operand" to "argument", and elsewhere
        .malformed_integer => |info| {
            try ctx.writeTitle("Malformed integer operand", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
            try ctx.deepen().writeNote("Integer token is not in an valid form", .{});
        },
        .malformed_character => |info| {
            try ctx.writeTitle("Malformed character literal operand", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
            try ctx.deepen().writeNote("Character literal token is invalid", .{});
        },
        .expected_digit => |info| {
            try ctx.writeTitle("Expected digit in integer operand", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
            try ctx.deepen().writeNote("Integer token ended unexpectedly", .{});
        },
        .invalid_digit => |info| {
            try ctx.writeTitle("Invalid digit in integer operand", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
            try ctx.deepen().writeNote("Integer token contains a character which is not valid in the base", .{});
        },
        .unexpected_delimiter => |info| {
            try ctx.writeTitle("Unexpected digit delimiter in integer operand", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
            try ctx.deepen().writeNote("Delimiter character `_` must appear between digits", .{});
        },
        .nonstandard_integer_radix => |info| {
            try ctx.writeTitle("Integer uses non-standard base specifier '{t}'", .{info.radix});
            try ctx.deepen().writeSourceNote("Integer", .{}, info.integer);
        },
        .nonstandard_integer_form => |info| {
            try ctx.writeTitle("Integer uses non-standard syntax", .{});
            try ctx.deepen().writeSourceNote("Integer", .{}, info.integer);
            try ctx.deepen().writeNote("{s}", .{switch (info.reason) {
                .delimiter => "Delimiter character `_` is non-standard",
            }});
        },
        .undesirable_integer_form => |info| {
            try ctx.writeTitle("Integer uses undesirable syntax", .{});
            try ctx.deepen().writeSourceNote("Integer", .{}, info.integer);
            try ctx.deepen().writeNote("{s}", .{switch (info.reason) {
                .missing_zero => "Leading zero should appear before base specifier",
                .pre_radix_sign => "Sign character should appear after decimal base specifier",
                .post_radix_sign => "Sign character should appear before non-decimal base specifier",
                .implicit_radix => "Decimal integer literal should begin with `#`",
            }});
        },
        .character_integer => |info| {
            try ctx.writeTitle("Use of non-standard character literal token", .{});
            try ctx.deepen().writeSourceNote("Character", .{}, info.integer);
        },

        .integer_too_large => |info| {
            try ctx.writeTitle("Integer operand is too large", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
            try ctx.deepen().writeNote("Value cannot be represented in {} bits", .{info.type_info.bits});
            if (info.type_info.signedness == .signed) {
                try ctx.deepen().writeNote("Since the operand is a signed integer, the highest bit is reserved as the sign bit", .{});
            }
        },
        .offset_too_large => |info| {
            try ctx.writeTitle("Calculated label offset is too large", .{});
            try ctx.deepen().writeSourceNote("Label declared here", .{}, info.definition);
            try ctx.deepen().withSource(info.definition_source)
                .writeSourceNote("Label used here", .{}, info.reference);
            try ctx.deepen().writeNote("Address offset of {} words cannot be represented in {} bits", .{ info.offset, info.bits });
        },
        .unexpected_negative_integer => |info| {
            try ctx.writeTitle("Integer operand cannot be negative", .{});
            try ctx.deepen().writeSourceNote("Operand", .{}, info.integer);
        },

        .unmatched_quote => |info| {
            try ctx.writeTitle("String literal does not end with quote `\"`", .{});
            try ctx.deepen().writeSourceNote("String is used here", .{}, info.string);
            try ctx.deepen().writeNote("Strings do not automatically stop at end of line", .{});
        },
        .invalid_string_escape => |info| {
            try ctx.writeTitle("Invalid escape sequence", .{});
            try ctx.deepen().writeSourceNote("String", .{}, info.string);
            try ctx.deepen().writeSourceNote("Erroneous escape sequence", .{}, info.sequence);
        },
        .multiline_string => |info| {
            try ctx.writeTitle("String covers multiple lines", .{});
            try ctx.deepen().writeSourceNote("String", .{}, info.string);
        },

        .stack_instruction => |info| {
            try ctx.writeTitle("Use of non-standard stack instruction `{t}`", .{info.kind});
            try ctx.deepen().writeSourceNote("Instruction is an ISA extension", .{}, info.mnemonic);
        },
        .literal_pc_offset => |info| {
            try ctx.writeTitle("Address operand is a literal offset", .{});
            try ctx.deepen().writeSourceNote("Integer", .{}, info.integer);
            try ctx.deepen().writeNote("PC-offset operand should be a label reference, instead of hardcoded offset value", .{});
        },
        .explicit_trap_vect => |info| {
            try ctx.writeTitle("Use of trap instruction with explicit vector operand", .{});
            try ctx.deepen().writeSourceNote("Trap vector", .{}, info.vect);
            try ctx.deepen().writeNote("Consider using trap alias `{s}`", .{info.alias});
        },
        .undeclared_trap_vect => |info| {
            try ctx.writeTitle("Use of unknown trap vector 0x{x:02}", .{info.value});
            try ctx.deepen().writeSourceNote("Trap vector", .{}, info.vect);
            try ctx.deepen().writeNote("Traps vector 0x{x:02} is not recognized", .{info.value});
        },

        .emulate_exception => |info| {
            try ctx.writeTitle("Runtime exception: {t}", .{info.code});
            // TODO: Add additional information
        },

        .debugger_requires_assembly => |info| {
            try ctx.writeTitle("Command requires access to assembly", .{});
            try ctx.deepen().writeSourceNote("Command", .{}, info.command);
            try ctx.deepen().writeNote("Debugger does not have access to original assembly", .{});
        },
        .debugger_requires_state => |info| {
            try ctx.writeTitle("Command requires initial state to be set", .{});
            try ctx.deepen().writeSourceNote("Command", .{}, info.command);
            try ctx.deepen().writeNote("Debugger does not have access to initial emulator state", .{});
        },
        .debugger_address_not_in_assembly => |info| {
            try ctx.writeTitle("Address 0x{x:04} is not contained in assembly source", .{info.value});
            try ctx.deepen().writeNote("Largest address in assembly is 0x{x:04}", .{info.max});
        },
        .debugger_address_not_user_memory => |info| {
            try ctx.writeTitle("Address 0x{x:04} is not in user memory", .{info.value});
            try ctx.deepen().writeSourceNote("Address", .{}, info.address);
            try ctx.deepen().writeNote("Largest address in user memory is 0x{x:04}", .{info.max});
        },
        .debugger_label_partial_match => |info| {
            try ctx.writeTitle("Label reference does not use correct case", .{});
            try ctx.deepen().writeSourceNote("Label", .{}, info.reference);
            try ctx.deepen().withSource(info.definition_source)
                .writeSourceNote("This label declaration is similar", .{}, info.nearest);
            try ctx.deepen().writeNote("Label names are case-sensitive", .{});
        },
        .debugger_no_space => {
            try ctx.deepen().writeTitle("No space left", .{});
        },
        .debugger_invalid_argument_kind => |info| {
            try ctx.writeTitle("Invalid argument kind", .{});
            try ctx.deepen().writeSourceNote("Argument", .{}, info.found);
        },
        .debugger_invalid_command => |info| {
            try ctx.writeTitle("Invalid command name", .{});
            try ctx.deepen().writeSourceNote("Command", .{}, info.command);
            if (info.nearest) |nearest|
                try ctx.deepen().writeNote("Did you mean `{s}`?", .{DebuggerCommand.tagString(nearest)});
        },
        .debugger_missing_subcommand => |info| {
            try ctx.writeTitle("Missing subcommand for `{s}`", .{info.first.view(source)});
            try ctx.deepen().writeSourceNote("Command requires subcommand", .{}, info.eol);
        },
        .debugger_unexpected_eol => |info| {
            try ctx.writeTitle("Missing argument", .{});
            try ctx.deepen().writeSourceNote("Command ends too early", .{}, info.eol);
        },
        .debugger_expected_eol => |info| {
            try ctx.writeTitle("Unexpected argument", .{});
            try ctx.deepen().writeSourceNote("Argument", .{}, info.found);
            try ctx.deepen().writeNote("Expected end of command", .{});
        },
        .debugger_integer_too_small => |info| {
            try ctx.writeTitle("Integer argument is too small", .{});
            try ctx.deepen().writeSourceNote("Argument", .{}, info.integer);
            try ctx.deepen().writeNote("Minimum value is {}", .{info.minimum});
        },
    }

    const count = if (ctx.item_count) |count| count.* else 0;
    if (count > 1 and ctx.verbosity == .normal) {
        try ctx.writer.print("\n", .{});
    }
}
