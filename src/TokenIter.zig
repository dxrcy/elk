const TokenIter = @This();

const std = @import("std");
const assert = std.debug.assert;

const Operand = @import("Air.zig").Operand;
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Integer = @import("integers.zig").Integer;
const Reporter = @import("Reporter.zig");

lexer: Lexer,
// Peek+peek or peek+next will parse same span as token multiple times, but this
// is okay as it avoids storing an error union.
peeked: ?Span,

source: []const u8,
reporter: *Reporter,

const TokenTag = std.meta.Tag(Token.Value);

pub fn new(source: []const u8, reporter: *Reporter) TokenIter {
    return .{
        .source = source,
        .reporter = reporter,
        .lexer = Lexer.new(source),
        .peeked = null,
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

fn nextAny(tokens: *TokenIter) error{ Reported, Eof }!Token {
    const span = try tokens.getNextSpan();
    tokens.peeked = null;

    return Token.from(span, tokens.source) catch |err| {
        try tokens.reporter.err(err, span);
    };
}

/// Does **not** report failure to parse token.
fn peekAny(tokens: *TokenIter) error{ InvalidTokenPeeked, Eof }!Token {
    const span = try tokens.getNextSpan();
    tokens.peeked = span;

    return Token.from(span, tokens.source) catch
        return error.InvalidTokenPeeked;
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
        return token;
    }
    comptime unreachable;
}

// TODO: Rename
pub fn nextMatching(tokens: *TokenIter, comptime match: TokenTag) ?Token {
    const token = tokens.peekAny() catch |err| switch (err) {
        // These can be handled by next token request
        error.InvalidTokenPeeked, error.Eof => return null,
    };
    if (token.value != match)
        return null;
    assert(tokens.peeked != null);
    tokens.peeked = null;
    return token;
}

pub fn discardOptional(tokens: *TokenIter, comptime discard: TokenTag) void {
    _ = nextMatching(tokens, discard);
}

pub fn discardRemainingLine(tokens: *TokenIter) void {
    while (true) {
        const token = tokens.nextAny() catch |err| switch (err) {
            error.Reported => continue,
            // This can be handled by next token request
            error.Eof => break,
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
    if (token.value != .newline)
        try tokens.reporter.err(error.UnexpectedToken, token.span);
}

pub fn expectArgument(
    tokens: *TokenIter,
    comptime argument: Argument,
) error{ Reported, Eof }!Operand.Spanned(argument.Value()) {
    const token = try tokens.nextAny();
    const value = argument.convert(token.value) catch |err| {
        try tokens.reporter.err(err, token.span);
    };
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
                    .integer => |integer| .{ .immediate = try integer.castTo(u5) },
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.Offset6 => switch (value) {
                    .integer => |integer| .{ .inner = try integer.castTo(i6) },
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.PCOffset9 => switch (value) {
                    .integer => |integer| .{ .resolved = try integer.castTo(i9) },
                    .label => .unresolved,
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.PCOffset11 => switch (value) {
                    .integer => |integer| .{ .resolved = try integer.castTo(i11) },
                    .label => .unresolved,
                    else => error.UnexpectedTokenKind,
                },
                Operand.Value.TrapVect => switch (value) {
                    .integer => |integer| .{ .inner = try integer.castTo(u8) },
                    else => error.UnexpectedTokenKind,
                },
                else => comptime unreachable,
            },
        };
    }
};
