const TokenIter = @This();

const std = @import("std");
const assert = std.debug.assert;

const Operand = @import("Air.zig").Operand;
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Integer = @import("integers.zig").SourceInt;
const Reporter = @import("Reporter.zig");

lexer: Lexer,
// Peek+peek or peek+next will parse same span as token multiple times, but this
// is okay as it avoids storing an error union.
peeked: ?Span,
/// Updated by `parseToken`.
latest: ?Span,

source: []const u8,
reporter: *Reporter,

const TokenTag = std.meta.Tag(Token.Value);

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
        try tokens.reporter.report(.generic, .{
            .code = err,
            .span = span,
        }).abort();
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
    switch (token.value) {
        .string => |string| {
            const value = string.in(token.span).view(tokens.source);
            if (std.mem.containsAtLeast(u8, value, 1, "\n")) {
                try tokens.reporter.report(.multiline_string, .{
                    .string = token.span,
                }).handle();
            }
        },
        .integer => |integer| {
            if (integer.radix) |radix| switch (radix) {
                .binary, .octal => {
                    try tokens.reporter.report(.nonstandard_integer_radix, .{
                        .integer = token.span,
                        .radix = radix,
                    }).handle();
                },
                else => {},
            };
        },
        else => {},
    }
}

pub fn nextExcluding(
    tokens: *TokenIter,
    comptime discards: []const TokenTag,
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

// TODO: Rename
pub fn nextMatching(
    tokens: *TokenIter,
    comptime match: TokenTag,
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

pub fn discardOptional(tokens: *TokenIter, comptime discard: TokenTag) void {
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
    const value = argument.convert(token.value) catch |err| {
        try tokens.reporter.report(.generic, .{
            .code = err,
            .span = token.span,
        }).abort();
    };
    try tokens.ensureSupported(token);
    return .{ .span = token.span, .value = value };
}

pub const Argument = union(enum) {
    operand: type,
    word,
    string,

    fn Value(comptime argument: Argument) type {
        return switch (argument) {
            .operand => |operand| operand,
            .word => Integer(16),
            .string => Span,
        };
    }

    const ConvertError = error{
        UnexpectedTokenKind,
        IntegerTooLarge,
    };

    fn convert(
        comptime argument: Argument,
        value: Token.Value,
    ) ConvertError!argument.Value() {
        return switch (argument) {
            .word => return switch (value) {
                .integer => |integer| integer,
                else => error.UnexpectedTokenKind,
            },
            .string => return switch (value) {
                .string => |string| string,
                else => error.UnexpectedTokenKind,
            },
            .operand => |operand| switch (operand) {
                Operand.Value.Register => switch (value) {
                    .register => |register| .{ .inner = register },
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.RegImm5 => switch (value) {
                    .register => |register| .{ .register = register },
                    .integer => |integer| .{ .immediate = try integer.shrink(5) },
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.Offset6 => switch (value) {
                    .integer => |integer| .{ .inner = try integer.shrink(6) },
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.PCOffset9 => switch (value) {
                    .integer => |integer| .{ .resolved = try integer.castToSmaller(i9) },
                    .label => .unresolved,
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.PCOffset11 => switch (value) {
                    .integer => |integer| .{ .resolved = try integer.castToSmaller(i11) },
                    .label => .unresolved,
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.TrapVect => switch (value) {
                    .integer => |integer| .{ .inner = try integer.castToSmaller(u8) },
                    else => error.UnexpectedTokenKind,
                },
                else => comptime unreachable,
            },
        };
    }
};
