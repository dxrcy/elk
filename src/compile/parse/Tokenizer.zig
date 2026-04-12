const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Traps = @import("../../Traps.zig");
const Reporter = @import("../../reporting/reporting.zig").Primary;
const Operand = @import("../Operand.zig");
const Span = @import("../Span.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const SourceInt = @import("integers.zig").SourceInt;
const case = @import("case.zig");

lexer: Lexer,
// Peek+peek or peek+next will parse same span as token multiple times, but this
// is okay as it avoids storing an error union.
peeked: ?Span,
/// Updated by `parseToken`.
latest: ?Span,

traps: *const Traps,
source: []const u8,
reporter: *Reporter,

const TokenKind = std.meta.Tag(Token.Value);

pub fn new(
    traps: *const Traps,
    source: []const u8,
    reporter: *Reporter,
) Tokenizer {
    for (traps.entries) |entry| {
        if (entry.alias) |alias|
            assert(case.isLowercaseAlpha(alias));
    }

    for (source) |char|
        assert(Token.isValidChar(char));

    return .{
        .lexer = Lexer.new(source, true),
        .peeked = null,
        .latest = null,
        .traps = traps,
        .source = source,
        .reporter = reporter,
    };
}

pub fn getIndex(tokenizer: *const Tokenizer) usize {
    // We currently have no need to support 'getting index when token has been peeked'
    assert(tokenizer.peeked == null);
    return tokenizer.lexer.index;
}

fn getNextSpan(tokenizer: *Tokenizer) error{Eof}!Span {
    return tokenizer.peeked orelse
        tokenizer.lexer.next() orelse
        return error.Eof;
}

fn parseToken(tokenizer: *Tokenizer, span: Span) Token.Error!Token {
    const token = try Token.from(span, tokenizer.source, tokenizer.traps);
    if (token.value != .newline)
        tokenizer.latest = token.span;
    return token;
}

/// Note that token may **not** be supported in the current mode; use
/// `ensureSupported` before using.
fn nextAny(tokenizer: *Tokenizer) error{ Reported, Eof }!Token {
    const span = try tokenizer.getNextSpan();
    tokenizer.peeked = null;
    return tokenizer.parseToken(span) catch |err| {
        switch (err) {
            inline error.InvalidLabel,
            error.InvalidDirective,
            error.InvalidToken,
            => |err2| {
                try tokenizer.reporter.report(.invalid_token, .{
                    .token = span,
                    .guess = switch (err2) {
                        error.InvalidLabel => .label,
                        error.InvalidDirective => .directive,
                        error.InvalidToken => null,
                        else => comptime unreachable,
                    },
                }).abort();
            },
            error.UnknownDirective => {
                try tokenizer.reporter.report(.unsupported_directive, .{
                    .directive = span,
                }).abort();
            },
            error.UnmatchedQuote => {
                try tokenizer.reporter.report(.unmatched_quote, .{
                    .string = span,
                }).abort();
            },

            error.MalformedInteger => {
                try tokenizer.reporter.report(.malformed_integer, .{
                    .integer = span,
                }).abort();
            },
            error.ExpectedDigit => {
                try tokenizer.reporter.report(.expected_digit, .{
                    .integer = span,
                }).abort();
            },
            error.InvalidDigit => {
                try tokenizer.reporter.report(.invalid_digit, .{
                    .integer = span,
                }).abort();
            },
            error.UnexpectedDelimiter => {
                try tokenizer.reporter.report(.unexpected_delimiter, .{
                    .integer = span,
                }).abort();
            },
            error.IntegerTooLarge => {
                try tokenizer.reporter.report(.integer_too_large, .{
                    .integer = span,
                    .type_info = @typeInfo(u16).int,
                }).abort();
            },
            error.MalformedCharacter => {
                try tokenizer.reporter.report(.malformed_character, .{
                    .integer = span,
                }).abort();
            },
        }
    };
}

/// Does **not** report failure to parse token.
/// Note that token may **not** be supported in the current mode; use
/// `ensureSupported` before using.
fn peekAny(tokenizer: *Tokenizer) error{ InvalidTokenPeeked, Eof }!Token {
    const span = try tokenizer.getNextSpan();
    tokenizer.peeked = span;
    return tokenizer.parseToken(span) catch
        return error.InvalidTokenPeeked;
}

fn nextAfterComma(tokenizer: *Tokenizer) error{ Reported, Eof }!Token {
    while (true) {
        const token = try tokenizer.nextAny();
        if (token.value == .comma) {
            try tokenizer.reporter.report(.whitespace_comma, .{
                .comma = token.span,
            }).handle();
            continue;
        }
        return token;
    }
}

pub fn nextExcluding(
    tokenizer: *Tokenizer,
    comptime discards: []const TokenKind,
) error{ Reported, Eof }!Token {
    token: while (true) {
        const token = try tokenizer.nextAfterComma();
        for (discards) |discard| {
            if (token.value == discard)
                continue :token;
        }
        try tokenizer.ensureSupported(token, null);
        return token;
    }
    comptime unreachable;
}

pub fn nextMatching(
    tokenizer: *Tokenizer,
    comptime match: TokenKind,
) error{Reported}!?Token {
    const token = tokenizer.peekAny() catch |err| switch (err) {
        // These can be handled by next token request
        error.InvalidTokenPeeked, error.Eof => return null,
    };
    if (token.value != match)
        return null;
    assert(tokenizer.peeked != null);
    tokenizer.peeked = null;
    try tokenizer.ensureSupported(token, null);
    return token;
}

pub fn discardRemainingLine(tokenizer: *Tokenizer) void {
    while (true) {
        const token = tokenizer.nextAny() catch |err| switch (err) {
            error.Reported => continue,
            // This can be handled by next token request
            error.Eof => break,
        };
        tokenizer.ensureSupported(token, null) catch |err| switch (err) {
            // We are discarding this token regardless
            error.Reported => {},
        };
        if (token.value == .newline)
            break;
    }
}

pub fn expectEol(tokenizer: *Tokenizer) error{Reported}!void {
    const token = tokenizer.nextAfterComma() catch |err| switch (err) {
        error.Reported => return error.Reported,
        // These can be handled by next token request
        error.Eof => return,
    };
    if (token.value != .newline) {
        try tokenizer.reporter.report(.expected_eol, .{
            .found = token,
        }).abort();
    }
}

pub fn expectArgument(
    tokenizer: *Tokenizer,
    comptime argument: Argument,
) error{Reported}!Operand.Spanned(argument.Value()) {
    const token: Token = tokenizer.nextAfterComma() catch |err| switch (err) {
        error.Reported => return error.Reported,
        error.Eof => .{
            .value = .newline,
            .span = .emptyAt(tokenizer.source.len),
        },
    };
    const value = try argument.convert(token, tokenizer.reporter);
    try tokenizer.ensureSupported(token, argument);
    return .{ .span = token.span, .value = value };
}

pub const Argument = union(enum) {
    operand: type,
    word,
    string,

    pub fn Value(comptime argument: Argument) type {
        return switch (argument) {
            .operand => |operand| operand,
            .word => SourceInt(16),
            .string => Span,
        };
    }

    pub fn convert(
        comptime argument: Argument,
        token: Token,
        reporter: *Reporter,
    ) error{Reported}!argument.Value() {
        return switch (argument) {
            .word => return switch (token.value) {
                .integer => |integer| integer,
                else => try unexpected(token, &.{.integer}, reporter),
            },

            .string => return switch (token.value) {
                .string => |string| string,
                else => try unexpected(token, &.{.string}, reporter),
            },

            .operand => |operand| switch (operand) {
                Operand.value.Register => switch (token.value) {
                    .register => |register| .{ .code = register },
                    else => try unexpected(token, &.{.register}, reporter),
                },

                Operand.value.RegImm5 => switch (token.value) {
                    .register => |register| .{ .register = .{ .code = register } },
                    .integer => |integer| .{
                        .immediate = try shrink(i5, integer, token.span, reporter),
                    },
                    else => try unexpected(token, &.{ .register, .integer }, reporter),
                },

                Operand.value.TrapVect => switch (token.value) {
                    .integer => |integer| .{
                        .immediate = try shrink(u8, integer, token.span, reporter),
                    },
                    else => try unexpected(token, &.{.integer}, reporter),
                },

                Operand.value.Offset6 => switch (token.value) {
                    .integer => |integer| .{
                        .immediate = try shrink(i6, integer, token.span, reporter),
                    },
                    else => try unexpected(token, &.{.integer}, reporter),
                },

                Operand.value.PcOffset(9) => switch (token.value) {
                    .integer => |integer| .{
                        .resolved = try shrink(i9, integer, token.span, reporter),
                    },
                    .label => .unresolved,
                    else => try unexpected(token, &.{ .label, .integer }, reporter),
                },

                Operand.value.PcOffset(10) => switch (token.value) {
                    .integer => |integer| .{
                        .resolved = try shrink(i10, integer, token.span, reporter),
                    },
                    .label => .unresolved,
                    else => try unexpected(token, &.{ .label, .integer }, reporter),
                },

                Operand.value.PcOffset(11) => switch (token.value) {
                    .integer => |integer| .{
                        .resolved = try shrink(i11, integer, token.span, reporter),
                    },
                    .label => .unresolved,
                    else => try unexpected(token, &.{ .label, .integer }, reporter),
                },

                else => comptime unreachable,
            },
        };
    }

    fn shrink(
        comptime T: type,
        integer: SourceInt(16),
        span: Span,
        reporter: *Reporter,
    ) error{Reported}!Operand.Formed(T) {
        const value = integer.castToSmaller(T) catch |err| switch (err) {
            error.IntegerTooLarge => {
                try reporter.report(.integer_too_large, .{
                    .integer = span,
                    .type_info = @typeInfo(T).int,
                }).abort();
            },
        };
        return .{
            .integer = value,
            .form = integer.form,
        };
    }

    fn unexpected(
        token: Token,
        expected: []const TokenKind,
        reporter: *Reporter,
    ) error{Reported}!noreturn {
        if (token.value == .newline) {
            try reporter.report(.unexpected_eol, .{
                .eol = token.span,
                .expected = expected,
            }).abort();
        } else {
            try reporter.report(.unexpected_token_kind, .{
                .found = token,
                .expected = expected,
            }).abort();
        }
    }
};

fn ensureSupported(
    tokenizer: *const Tokenizer,
    token: Token,
    comptime argument_opt: ?Argument,
) error{Reported}!void {
    var result: error{Reported}!void = {};

    switch (token.value) {
        .directive => {
            // Don't include initial `.`
            const string = token.span.view(tokenizer.source)[1..];
            if (!case.isUppercaseAlpha(string)) {
                tokenizer.reporter.report(.unconventional_case, .{
                    .token = token.span,
                    .kind = .directive,
                }).collect(&result);
            }
        },

        .mnemonic => {
            if (!case.isLowercaseAlpha(token.span.view(tokenizer.source))) {
                tokenizer.reporter.report(.unconventional_case, .{
                    .token = token.span,
                    .kind = .mnemonic,
                }).collect(&result);
            }
        },

        .trap_alias => {
            if (!case.isLowercaseAlpha(token.span.view(tokenizer.source))) {
                tokenizer.reporter.report(.unconventional_case, .{
                    .token = token.span,
                    .kind = .trap_alias,
                }).collect(&result);
            }
        },

        // Conventional case check should handled by `Parser`
        // Since we only want to report label definitions, not references
        .label => {},

        .string => |string| {
            const value = string.in(token.span).view(tokenizer.source);
            if (std.mem.containsAtLeast(u8, value, 1, "\n")) {
                tokenizer.reporter.report(.multiline_string, .{
                    .string = token.span,
                }).collect(&result);
            }
        },

        .register => {
            const string = token.span.view(tokenizer.source);
            assert(string.len == 2);
            switch (string[0]) {
                'r' => {},
                'R' => {
                    tokenizer.reporter.report(.unconventional_case, .{
                        .token = token.span,
                        .kind = .register,
                    }).collect(&result);
                },
                else => unreachable,
            }
        },

        .integer => |integer| if (integer.form.char) {
            tokenizer.reporter.report(.character_integer, .{
                .integer = token.span,
            }).collect(&result);
        } else {
            if (case.hasUppercaseAlpha(token.span.view(tokenizer.source))) {
                tokenizer.reporter.report(.unconventional_case, .{
                    .token = token.span,
                    .kind = .integer,
                }).collect(&result);
            }

            if (argument_opt) |argument| switch (argument) {
                .operand => |operand| switch (operand) {
                    Operand.value.PcOffset(9),
                    Operand.value.PcOffset(10),
                    Operand.value.PcOffset(11),
                    => {
                        tokenizer.reporter.report(.literal_pc_offset, .{
                            .integer = token.span,
                        }).collect(&result);
                    },
                    Operand.value.TrapVect => {
                        // If vect is too big, it will be reported elsewhere
                        if (integer.castToSmaller(u8) catch null) |vect| {
                            const entry = tokenizer.traps.entries[vect];
                            if (entry.alias) |alias| {
                                tokenizer.reporter.report(.explicit_trap_vect, .{
                                    .vect = token.span,
                                    .value = vect,
                                    .alias = alias,
                                }).collect(&result);
                            } else if (entry.callback == null) {
                                tokenizer.reporter.report(.undeclared_trap_vect, .{
                                    .vect = token.span,
                                    .value = vect,
                                }).collect(&result);
                            } else {
                                // Should use explicit vector; it's the only way
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            };
            if (integer.form.radix) |radix| switch (radix) {
                .octal => {
                    tokenizer.reporter.report(.nonstandard_integer_radix, .{
                        .integer = token.span,
                        .radix = radix,
                    }).collect(&result);
                },
                else => {},
            };
            if (integer.form.radix) |radix| switch (radix) {
                .decimal => if (integer.form.sign) |sign| {
                    if (sign.position == .pre_radix) {
                        tokenizer.reporter.report(.undesirable_integer_form, .{
                            .integer = token.span,
                            .reason = .pre_radix_sign,
                        }).collect(&result);
                    }
                },
                .hex, .octal, .binary => if (integer.form.sign) |sign| {
                    if (sign.position == .post_radix) {
                        tokenizer.reporter.report(.undesirable_integer_form, .{
                            .integer = token.span,
                            .reason = .post_radix_sign,
                        }).collect(&result);
                    }
                },
            };
            if (integer.form.delimited) {
                tokenizer.reporter.report(.nonstandard_integer_form, .{
                    .integer = token.span,
                    .reason = .delimiter,
                }).collect(&result);
            }
            if (integer.form.radix) |radix| switch (radix) {
                .hex, .octal, .binary => if (!integer.form.zero) {
                    tokenizer.reporter.report(.undesirable_integer_form, .{
                        .integer = token.span,
                        .reason = .missing_zero,
                    }).collect(&result);
                },
                else => assert(!integer.form.zero),
            };
            if (integer.form.radix == null) {
                tokenizer.reporter.report(.undesirable_integer_form, .{
                    .integer = token.span,
                    .reason = .implicit_radix,
                }).collect(&result);
            }
        },

        else => {},
    }
    return result;
}
