const TokenIter = @This();

const std = @import("std");
const assert = std.debug.assert;

const Traps = @import("../../Traps.zig");
const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../Air.zig");
const Span = @import("../Span.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const SourceInt = @import("integers.zig").SourceInt;
const case = @import("case.zig");
const Operand = Air.Operand;

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
) TokenIter {
    for (traps.entries) |entry| {
        if (entry.alias) |alias|
            assert(case.isLowercaseAlpha(alias));
    }

    return .{
        .lexer = Lexer.new(source),
        .peeked = null,
        .latest = null,
        .traps = traps,
        .source = source,
        .reporter = reporter,
    };
}

pub fn getIndex(tokens: *const TokenIter) usize {
    // We currently have no need to support 'getting index when token has been peeked'
    assert(tokens.peeked == null);
    return tokens.lexer.index;
}

fn getNextSpan(tokens: *TokenIter) error{Eof}!Span {
    return tokens.peeked orelse
        tokens.lexer.next() orelse
        return error.Eof;
}

fn parseToken(tokens: *TokenIter, span: Span) Token.Error!Token {
    const token = try Token.from(span, tokens.source, tokens.traps);
    if (token.value != .newline)
        tokens.latest = token.span;
    return token;
}

/// Note that token may **not** be supported in the current mode; use
/// `ensureSupported` before using.
fn nextAny(tokens: *TokenIter) error{ Reported, Eof }!Token {
    const span = try tokens.getNextSpan();
    tokens.peeked = null;
    return tokens.parseToken(span) catch |err| {
        switch (err) {
            inline error.InvalidLabel,
            error.InvalidDirective,
            error.InvalidToken,
            => |err2| {
                try tokens.reporter.report(.invalid_token, .{
                    .token = span,
                    .kind = switch (err2) {
                        error.InvalidLabel => .label,
                        error.InvalidDirective => .directive,
                        error.InvalidToken => null,
                        else => comptime unreachable,
                    },
                }).abort();
            },
            error.UnknownDirective => {
                try tokens.reporter.report(.unknown_directive, .{
                    .directive = span,
                }).abort();
            },
            error.UnmatchedQuote => {
                try tokens.reporter.report(.unmatched_quote, .{
                    .string = span,
                }).abort();
            },

            error.MalformedInteger => {
                try tokens.reporter.report(.malformed_integer, .{
                    .integer = span,
                }).abort();
            },
            error.ExpectedDigit => {
                try tokens.reporter.report(.expected_digit, .{
                    .integer = span,
                }).abort();
            },
            error.InvalidDigit => {
                try tokens.reporter.report(.invalid_digit, .{
                    .integer = span,
                }).abort();
            },
            error.UnexpectedDelimiter => {
                try tokens.reporter.report(.unexpected_delimiter, .{
                    .integer = span,
                }).abort();
            },
            error.IntegerTooLarge => {
                try tokens.reporter.report(.integer_too_large, .{
                    .integer = span,
                    .bits = 16,
                }).abort();
            },
        }
    };
}

/// Does **not** report failure to parse token.
/// Note that token may **not** be supported in the current mode; use
/// `ensureSupported` before using.
fn peekAny(tokens: *TokenIter) error{ InvalidTokenPeeked, Eof }!Token {
    const span = try tokens.getNextSpan();
    tokens.peeked = span;
    return tokens.parseToken(span) catch
        return error.InvalidTokenPeeked;
}

fn nextAfterComma(tokens: *TokenIter) error{ Reported, Eof }!Token {
    while (true) {
        const token = try tokens.nextAny();
        if (token.value == .comma) {
            try tokens.reporter.report(.whitespace_comma, .{
                .comma = token.span,
            }).handle();
            continue;
        }
        return token;
    }
}

pub fn nextExcluding(
    tokens: *TokenIter,
    comptime discards: []const TokenKind,
) error{ Reported, Eof }!Token {
    token: while (true) {
        const token = try tokens.nextAfterComma();
        for (discards) |discard| {
            if (token.value == discard)
                continue :token;
        }
        try tokens.ensureSupported(token, null);
        return token;
    }
    comptime unreachable;
}

pub fn nextMatching(
    tokens: *TokenIter,
    comptime match: TokenKind,
) error{Reported}!?Token {
    const token = tokens.peekAny() catch |err| switch (err) {
        // These can be handled by next token request
        error.InvalidTokenPeeked, error.Eof => return null,
    };
    if (token.value != match)
        return null;
    assert(tokens.peeked != null);
    tokens.peeked = null;
    try tokens.ensureSupported(token, null);
    return token;
}

pub fn discardRemainingLine(tokens: *TokenIter) void {
    while (true) {
        const token = tokens.nextAny() catch |err| switch (err) {
            error.Reported => continue,
            // This can be handled by next token request
            error.Eof => break,
        };
        tokens.ensureSupported(token, null) catch |err| switch (err) {
            // We are discarding this token regardless
            error.Reported => {},
        };
        if (token.value == .newline)
            break;
    }
}

pub fn expectEol(tokens: *TokenIter) error{Reported}!void {
    const token = tokens.nextAfterComma() catch |err| switch (err) {
        error.Reported => return error.Reported,
        // These can be handled by next token request
        error.Eof => return,
    };
    if (token.value != .newline) {
        try tokens.reporter.report(.unexpected_token, .{
            .token = token,
        }).abort();
    }
}

pub fn expectArgument(
    tokens: *TokenIter,
    comptime argument: Argument,
) error{ Reported, Eof }!Operand.Spanned(argument.Value()) {
    const token = try tokens.nextAfterComma();
    const value = try argument.convert(token, tokens.reporter);
    try tokens.ensureSupported(token, argument);
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
                else => try unexpected(reporter, token, &.{.integer}),
            },

            .string => return switch (token.value) {
                .string => |string| string,
                else => try unexpected(reporter, token, &.{.string}),
            },

            .operand => |operand| switch (operand) {
                Operand.value.Register => switch (token.value) {
                    .register => |register| .{ .code = register },
                    else => try unexpected(reporter, token, &.{.register}),
                },

                Operand.value.RegImm5 => switch (token.value) {
                    .register => |register| .{ .register = .{ .code = register } },
                    .integer => |integer| .{
                        // TODO: Allow +1 bit for unsigned literals, which will
                        // be later bitcast to negative. Warn for this!
                        // Same with Offset6, but probably not with PcOffset(_)
                        .immediate = try shrink(reporter, token.span, integer, i5),
                    },
                    else => try unexpected(reporter, token, &.{ .register, .integer }),
                },

                Operand.value.TrapVect => switch (token.value) {
                    .integer => |integer| .{
                        .immediate = try shrink(reporter, token.span, integer, u8),
                    },
                    else => try unexpected(reporter, token, &.{.integer}),
                },

                Operand.value.Offset6 => switch (token.value) {
                    .integer => |integer| .{
                        .immediate = try shrink(reporter, token.span, integer, i6),
                    },
                    else => try unexpected(reporter, token, &.{.integer}),
                },

                Operand.value.PcOffset(9) => switch (token.value) {
                    .integer => |integer| .{
                        .resolved = try shrink(reporter, token.span, integer, i9),
                    },
                    .label => .unresolved,
                    else => try unexpected(reporter, token, &.{ .label, .integer }),
                },

                Operand.value.PcOffset(10) => switch (token.value) {
                    .integer => |integer| .{
                        .resolved = try shrink(reporter, token.span, integer, i10),
                    },
                    .label => .unresolved,
                    else => try unexpected(reporter, token, &.{ .label, .integer }),
                },

                Operand.value.PcOffset(11) => switch (token.value) {
                    .integer => |integer| .{
                        .resolved = try shrink(reporter, token.span, integer, i11),
                    },
                    .label => .unresolved,
                    else => try unexpected(reporter, token, &.{ .label, .integer }),
                },

                else => comptime unreachable,
            },
        };
    }

    fn shrink(
        reporter: *Reporter,
        span: Span,
        integer: SourceInt(16),
        comptime T: type,
    ) error{Reported}!T {
        return integer.castToSmaller(T) catch |err| switch (err) {
            error.IntegerTooLarge => {
                try reporter.report(.integer_too_large, .{
                    .integer = span,
                    .bits = @typeInfo(T).int.bits,
                }).abort();
            },
        };
    }

    fn unexpected(
        reporter: *Reporter,
        token: Token,
        expected: []const TokenKind,
    ) error{Reported}!noreturn {
        if (token.value == .newline) {
            try reporter.report(.unexpected_line_end, .{
                .span = token.span,
                .expected = expected,
            }).abort();
        } else {
            try reporter.report(.unexpected_token_kind, .{
                .token = token,
                .expected = expected,
            }).abort();
        }
    }
};

fn ensureSupported(
    tokens: *const TokenIter,
    token: Token,
    comptime argument_opt: ?Argument,
) error{Reported}!void {
    var result: error{Reported}!void = {};

    switch (token.value) {
        .directive => {
            // Don't include initial `.`
            const string = token.span.view(tokens.source)[1..];
            if (!case.isUppercaseAlpha(string)) {
                tokens.reporter.report(.unconventional_case_ident, .{
                    .ident = token.span,
                    .kind = .directive,
                }).collect(&result);
            }
        },

        .instruction => {
            if (!case.isLowercaseAlpha(token.span.view(tokens.source))) {
                tokens.reporter.report(.unconventional_case_ident, .{
                    .ident = token.span,
                    .kind = .instruction,
                }).collect(&result);
            }
        },

        // Conventional case check should handled by `Parser`
        // Since we only want to report label declarations, not references
        .label => {},

        .string => |string| {
            const value = string.in(token.span).view(tokens.source);
            if (std.mem.containsAtLeast(u8, value, 1, "\n")) {
                tokens.reporter.report(.multiline_string, .{
                    .string = token.span,
                }).collect(&result);
            }
        },

        .integer => |integer| {
            if (argument_opt) |argument| switch (argument) {
                .operand => |operand| switch (operand) {
                    Operand.value.PcOffset(9),
                    Operand.value.PcOffset(10),
                    Operand.value.PcOffset(11),
                    => {
                        tokens.reporter.report(.literal_pc_offset, .{
                            .integer = token.span,
                        }).collect(&result);
                    },
                    else => {},
                },
                else => {},
            };
            if (integer.form.radix) |radix| switch (radix) {
                .octal => {
                    tokens.reporter.report(.nonstandard_integer_radix, .{
                        .integer = token.span,
                        .radix = radix,
                    }).collect(&result);
                },
                else => {},
            };
            if (integer.form.radix) |radix| switch (radix) {
                .decimal => if (integer.form.sign) |sign| {
                    if (sign.position == .pre_radix) {
                        tokens.reporter.report(.undesirable_integer_form, .{
                            .integer = token.span,
                            .reason = .pre_radix_sign,
                        }).collect(&result);
                    }
                },
                .hex, .octal, .binary => if (integer.form.sign) |sign| {
                    if (sign.position == .post_radix) {
                        tokens.reporter.report(.undesirable_integer_form, .{
                            .integer = token.span,
                            .reason = .post_radix_sign,
                        }).collect(&result);
                    }
                },
            };
            if (integer.form.delimited) {
                tokens.reporter.report(.nonstandard_integer_form, .{
                    .integer = token.span,
                    .reason = .delimiter,
                }).collect(&result);
            }
            if (integer.form.radix) |radix| switch (radix) {
                .hex, .octal, .binary => if (!integer.form.zero) {
                    tokens.reporter.report(.undesirable_integer_form, .{
                        .integer = token.span,
                        .reason = .missing_zero,
                    }).collect(&result);
                },
                else => assert(!integer.form.zero),
            };
            if (integer.form.radix == null) {
                tokens.reporter.report(.undesirable_integer_form, .{
                    .integer = token.span,
                    .reason = .implicit_radix,
                }).collect(&result);
            }
        },

        else => {},
    }
    return result;
}
