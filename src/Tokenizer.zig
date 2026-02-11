const Tokenizer = @This();

const std = @import("std");
const assert = std.debug.assert;

const Span = @import("Span.zig");

source: []const u8,
index: usize,

pub fn new(source: []const u8) Tokenizer {
    return Tokenizer{ .source = source, .index = 0 };
}

pub fn next(tokenizer: *Tokenizer) ?Span {
    // Skip whitespace
    while (tokenizer.peekChar()) |char| {
        if (char.kind != .whitespace)
            break;
        _ = tokenizer.takeChar();
    }

    const start = tokenizer.getIndex();
    const first = tokenizer.takeChar() orelse
        return null;

    assert(first.kind != .whitespace);
    // FIXME: Discard characters until \n
    if (first.value == ';')
        return null;
    if (first.kind == .atomic)
        return .fromBounds(start, tokenizer.getIndex());

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
            if (char.kind == .whitespace or char.kind == .atomic)
                break;
            _ = tokenizer.takeChar();
        }
    }

    return .fromBounds(start, tokenizer.getIndex());
}

fn peekChar(tokenizer: *Tokenizer) ?TokenChar {
    if (tokenizer.isEnd())
        return null;
    return .from(tokenizer.source[tokenizer.index]);
}

fn takeChar(tokenizer: *Tokenizer) ?TokenChar {
    const char = tokenizer.peekChar() orelse
        return null;
    tokenizer.index += 1;
    return char;
}

// This is used to allow index to be calculated from a line span in the future.
fn getIndex(tokenizer: *const Tokenizer) usize {
    return tokenizer.index;
}

fn isEnd(tokenizer: *const Tokenizer) bool {
    return tokenizer.index >= tokenizer.source.len;
}

const TokenChar = struct {
    value: u8,
    kind: Kind,

    pub const Kind = enum {
        atomic,
        combining,
        whitespace,
        control,
    };

    pub fn from(value: u8) TokenChar {
        const kind: Kind = switch (value) {
            ' ', '\t', '\r' => .whitespace,
            0x00...0x08, 0x0e...0x1f, 0x7f => .control,
            '\n', ',' => .atomic,
            else => .combining,
        };
        return TokenChar{
            .value = value,
            .kind = kind,
        };
    }
};
