const Lexer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Span = @import("../Span.zig");

source: []const u8,
index: usize,

pub fn new(source: []const u8) Lexer {
    return Lexer{ .source = source, .index = 0 };
}

pub fn next(lexer: *Lexer) ?Span {
    lexer.discardWhitespaceAndComments();

    const start = lexer.getIndex();
    const first = lexer.takeChar() orelse
        return null;

    assert(first.kind != .whitespace);
    assert(first.value != ';');
    if (first.kind == .atomic)
        return .fromBounds(start, lexer.getIndex());

    if (first.value == '"')
        lexer.consumeStringLiteral()
    else
        lexer.consumeNormal();

    return .fromBounds(start, lexer.getIndex());
}

fn discardWhitespaceAndComments(lexer: *Lexer) void {
    while (lexer.peekChar()) |char| {
        if (char.value == ';') {
            lexer.discardComment();
            continue;
        }
        if (char.kind != .whitespace)
            break;
        _ = lexer.takeChar();
    }
}

fn discardComment(lexer: *Lexer) void {
    const first = lexer.takeChar();
    assert(first.?.value == ';');

    while (lexer.peekChar()) |char| {
        if (char.value == '\n')
            break;
        _ = lexer.takeChar();
    }
}

fn consumeStringLiteral(lexer: *Lexer) void {
    var is_escaped = false;
    while (lexer.takeChar()) |char| {
        if (is_escaped) {
            is_escaped = false;
            continue;
        }
        switch (char.value) {
            '"' => break,
            '\\' => is_escaped = true,
            else => {},
        }
    }
}

fn consumeNormal(lexer: *Lexer) void {
    while (lexer.peekChar()) |char| {
        if (char.kind == .whitespace or char.kind == .atomic)
            break;
        _ = lexer.takeChar();
    }
}

fn peekChar(lexer: *Lexer) ?Char {
    if (lexer.isEnd())
        return null;
    return .from(lexer.source[lexer.index]);
}

fn takeChar(lexer: *Lexer) ?Char {
    const char = lexer.peekChar() orelse
        return null;
    lexer.index += 1;
    return char;
}

// This is used to allow index to be calculated from a line span in the future.
fn getIndex(lexer: *const Lexer) usize {
    return lexer.index;
}

fn isEnd(lexer: *const Lexer) bool {
    return lexer.index >= lexer.source.len;
}

const Char = struct {
    value: u8,
    kind: Kind,

    pub const Kind = enum {
        atomic,
        combining,
        whitespace,
        control,
    };

    pub fn from(value: u8) Char {
        const kind: Kind = switch (value) {
            ' ', '\t', '\r' => .whitespace,
            0x00...0x08, 0x0e...0x1f, 0x7f => .control,
            '\n', ';', ',', ':' => .atomic,
            else => .combining,
        };
        return Char{
            .value = value,
            .kind = kind,
        };
    }
};
