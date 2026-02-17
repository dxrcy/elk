const TokenIter = @This();

const std = @import("std");

const Operand = @import("Air.zig").Operand;
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Integer = @import("integers.zig").Integer;
const Reporter = @import("Reporter.zig");

lexer: Lexer,
token_peeked: ?Token,

source: []const u8,
reporter: *Reporter,

pub fn new(source: []const u8, reporter: *Reporter) TokenIter {
    return .{
        .source = source,
        .reporter = reporter,
        .lexer = Lexer.new(source),
        .token_peeked = null,
    };
}

pub fn discardRestOfLine(tokens: *TokenIter) void {
    while (true) {
        // TODO: Why using `nextToken` here ?
        const token = tokens.nextToken(&.{}) catch |err| switch (err) {
            // Ignore any other errors on this line
            error.Reported => continue,
        };
        if (token == null or token.?.value == .newline)
            break;
    }
}

pub fn nextToken(
    tokens: *TokenIter,
    comptime skip: []const std.meta.Tag(Token.Value),
) error{Reported}!?Token {
    token: while (true) {
        const token = try tokens.nextTokenAny() orelse
            return null;
        for (skip) |skip_kind| {
            if (token.value == skip_kind)
                continue :token;
        }
        return token;
    }
}

pub fn discardOptionalToken(tokens: *TokenIter, comptime kind: std.meta.Tag(Token.Value)) !void {
    if (try tokens.peekTokenAny()) |peeked| {
        if (peeked.value == kind) {
            _ = tokens.nextTokenAny() catch
                unreachable orelse
                unreachable;
        }
    }
}

fn peekTokenAny(tokens: *TokenIter) !?Token {
    if (tokens.token_peeked) |peeked| {
        return peeked;
    }
    tokens.token_peeked = try tokens.nextTokenAny();
    return tokens.token_peeked;
}

fn nextTokenAny(tokens: *TokenIter) !?Token {
    if (tokens.token_peeked) |peeked| {
        tokens.token_peeked = null;
        return peeked;
    }
    const span = tokens.lexer.next() orelse
        return null;
    return Token.from(span, tokens.source) catch |err| {
        try tokens.reporter.err(err, span);
    };
}

fn expectToken(tokens: *TokenIter) !Token {
    const token = try tokens.nextToken(&.{}) orelse {
        try tokens.reporter.err(error.UnexpectedEof, .emptyAt(tokens.source.len));
    };
    switch (token.value) {
        .newline => {
            try tokens.reporter.err(error.UnexpectedEol, .emptyAt(token.span.offset));
        },
        else => return token,
    }
}

pub const Argument = union(enum) {
    operand: type,
    word,
    string,

    pub fn asType(comptime argument: Argument) type {
        return switch (argument) {
            .operand => |operand| operand,
            .word => Integer(16),
            .string => Span,
        };
    }
};

pub fn expectArgument(
    tokens: *TokenIter,
    comptime argument: Argument,
) !Operand.Spanned(argument.asType()) {
    const token = try tokens.expectToken();
    const value = convertArgument(argument, token.value) catch |err| {
        try tokens.reporter.err(err, token.span);
    };
    return .{ .span = token.span, .value = value };
}

fn convertArgument(
    comptime argument: Argument,
    value: Token.Value,
) error{ UnexpectedTokenKind, IntegerTooLarge }!argument.asType() {
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
