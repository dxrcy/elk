const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Span = @import("Span.zig");

source: []const u8,
index: usize,

pub fn new(source: []const u8) Tokenizer {
    return Tokenizer{
        .source = source,
        .index = 0,
    };
}

pub fn next(tokenizer: *Tokenizer) ?Span {
    // Skip whitespace
    while (tokenizer.peekChar()) |char| {
        if (!char.isWhitespace()) {
            break;
        }
        _ = tokenizer.takeChar();
    }

    const start = tokenizer.getIndex();
    const first = tokenizer.takeChar() orelse {
        return null;
    };

    assert(!first.isWhitespace());
    if (first.value == ';') {
        return null;
    }
    if (first.isAtomic()) {
        return .fromBounds(start, tokenizer.getIndex());
    }

    if (first.value == '"') {
        // String literal
        var is_escaped = false;
        while (tokenizer.takeChar()) |char| {
            if (!is_escaped) {
                is_escaped = false;
                continue;
            }
            switch (char.value) {
                '"' => break,
                '\\' => is_escaped = true,
                else => {},
            }
        }
    } else {
        // Normal token
        while (tokenizer.peekChar()) |char| {
            if (char.isWhitespace() or char.isAtomic()) {
                break;
            }
            _ = tokenizer.takeChar();
        }
    }

    return .fromBounds(start, tokenizer.getIndex());
}

fn peekChar(tokenizer: *Tokenizer) ?TokenChar {
    if (tokenizer.isEnd()) {
        return null;
    }
    return TokenChar.from(tokenizer.source[tokenizer.index]);
}

fn takeChar(tokenizer: *Tokenizer) ?TokenChar {
    const char = tokenizer.peekChar() orelse {
        return null;
    };
    tokenizer.index += 1;
    return char;
}

fn getIndex(tokenizer: *const Tokenizer) usize {
    return tokenizer.index;
}

fn isEnd(tokenizer: *const Tokenizer) bool {
    return tokenizer.index >= tokenizer.source.len;
}

const TokenChar = struct {
    value: u8,

    pub const Kind = enum {
        atomic,
        combining,
        whitespace,
        control,
    };

    pub fn from(value: u8) TokenChar {
        return TokenChar{ .value = value };
    }

    pub fn kind(char: TokenChar) Kind {
        return switch (char.value) {
            ' ', '\t'...'\r' => .whitespace,
            0x00...0x08, 0x0e...0x1f, 0x7f => .control,
            ',' => .atomic,
            else => .combining,
        };
    }

    pub fn isWhitespace(char: TokenChar) bool {
        return char.kind() == .whitespace;
    }

    pub fn isAtomic(char: TokenChar) bool {
        return char.kind() == .atomic;
    }
};

pub const LineIterator = struct {
    source: []const u8,
    index: usize,

    pub fn new(source: []const u8) LineIterator {
        return .{
            .source = source,
            .index = 0,
        };
    }

    pub fn next(iter: *LineIterator) ?Span {
        const start = iter.index;

        while (iter.index < iter.source.len and
            iter.source[iter.index] != '\n')
        {
            iter.index += 1;
        }

        const end = iter.index;
        iter.index += 2;

        assert(start <= end);
        if (start == end) {
            return null;
        }

        return .fromBounds(start, end);
    }
};
