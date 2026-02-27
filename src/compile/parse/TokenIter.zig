const TokenIter = @This();

const std = @import("std");
const assert = std.debug.assert;

const Reporter = @import("../../Reporter.zig");
const Operand = @import("../Air.zig").Operand;
const Span = @import("../Span.zig");

const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const SourceInt = @import("integers.zig").SourceInt;

lexer: Lexer,
// Peek+peek or peek+next will parse same span as token multiple times, but this
// is okay as it avoids storing an error union.
peeked: ?Span,
/// Updated by `parseToken`.
latest: ?Span,

source: []const u8,
reporter: *Reporter,

const TokenKind = std.meta.Tag(Token.Value);

pub fn new(source: []const u8, reporter: *Reporter) TokenIter {
    return .{
        .source = source,
        .reporter = reporter,
        .lexer = Lexer.new(source),
        .peeked = null,
        .latest = null,
    };
}

pub fn getIndex(tokens: *const TokenIter) usize {
    // TODO: We might need to support this assertion being false
    assert(tokens.peeked == null);
    return tokens.lexer.index;
}

fn getNextSpan(tokens: *TokenIter) error{Eof}!Span {
    return tokens.peeked orelse
        tokens.lexer.next() orelse
        return error.Eof;
}

fn parseToken(tokens: *TokenIter, span: Span) Token.Error!Token {
    const token = try Token.from(span, tokens.source);
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

fn ensureSupported(tokens: *const TokenIter, token: Token) error{Reported}!void {
    var result: error{Reported}!void = {};
    switch (token.value) {
        .string => |string| {
            const value = string.in(token.span).view(tokens.source);
            if (std.mem.containsAtLeast(u8, value, 1, "\n")) {
                tokens.reporter.report(.multiline_string, .{
                    .string = token.span,
                }).collect(&result);
            }
        },
        .integer => |integer| {
            if (integer.form.radix) |radix| switch (radix) {
                .octal => {
                    tokens.reporter.report(.nonstandard_integer_radix, .{
                        .integer = token.span,
                        .radix = radix,
                    }).collect(&result);
                },
                else => {},
            };
            if (integer.form.sign) |sign| {
                if (sign.position == .post_radix) {
                    tokens.reporter.report(.nonstandard_integer_form, .{
                        .integer = token.span,
                        .reason = .post_radix_sign,
                    }).collect(&result);
                }
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
        },
        else => {},
    }
    return result;
}

pub fn nextExcluding(
    tokens: *TokenIter,
    comptime discards: []const TokenKind,
) error{ Reported, Eof }!Token {
    token: while (true) {
        const token = try tokens.nextAny();
        for (discards) |discard| {
            if (token.value == discard)
                continue :token;
        }
        try tokens.ensureSupported(token);
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
    try tokens.ensureSupported(token);
    return token;
}

pub fn discardOptional(tokens: *TokenIter, comptime discard: TokenKind) void {
    _ = nextMatching(tokens, discard) catch |err| switch (err) {
        // We are discarding this token regardless
        error.Reported => {},
    };
}

pub fn discardRemainingLine(tokens: *TokenIter) void {
    while (true) {
        const token = tokens.nextAny() catch |err| switch (err) {
            error.Reported => continue,
            // This can be handled by next token request
            error.Eof => break,
        };
        tokens.ensureSupported(token) catch |err| switch (err) {
            // We are discarding this token regardless
            error.Reported => {},
        };
        if (token.value == .newline)
            break;
    }
}

pub fn expectEol(tokens: *TokenIter) error{Reported}!void {
    const token = tokens.nextAny() catch |err| switch (err) {
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
    const token = try tokens.nextAny();
    const value = try argument.convert(token, tokens.reporter);
    try tokens.ensureSupported(token);
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
                Operand.Value.Register => switch (token.value) {
                    .register => |register| .{ .code = register },
                    else => try unexpected(reporter, token, &.{.register}),
                },

                Operand.Value.RegImm5 => switch (token.value) {
                    .register => |register| .{ .register = .{ .code = register } },
                    .integer => |integer| .{
                        // TODO: Allow +1 bit for unsigned literals, which will
                        // be later bitcast to negative. Warn for this!
                        // Same with Offset6, but probably not with PcOffset*
                        .immediate = try shrink(reporter, token.span, integer, i5),
                    },
                    else => try unexpected(reporter, token, &.{ .register, .integer }),
                },

                Operand.Value.TrapVect => switch (token.value) {
                    .integer => |integer| .{
                        .immediate = try shrink(reporter, token.span, integer, u8),
                    },
                    else => try unexpected(reporter, token, &.{.integer}),
                },

                Operand.Value.Offset6 => switch (token.value) {
                    .integer => |integer| .{
                        .immediate = try shrink(reporter, token.span, integer, i6),
                    },
                    else => try unexpected(reporter, token, &.{.integer}),
                },

                Operand.Value.PcOffset9 => switch (token.value) {
                    // TODO: Integer literals here may be non-standard; warn
                    .integer => |integer| .{
                        .resolved = try shrink(reporter, token.span, integer, i9),
                    },
                    .label => .unresolved,
                    else => try unexpected(reporter, token, &.{ .label, .integer }),
                },

                Operand.Value.PcOffset11 => switch (token.value) {
                    // TODO: Integer literals here may be non-standard; warn
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
        try reporter.report(.unexpected_token_kind, .{
            .token = token,
            .expected = expected,
        }).abort();
    }
};
