const std = @import("std");
const assert = std.debug.assert;

const Token = @import("Token.zig");

pub fn tryRegister(string: []const u8) ?u3 {
    assert(string.len > 0);
    if (string.len != 2)
        return null;
    switch (string[0]) {
        'r', 'R' => {},
        else => return null,
    }
    return switch (string[1]) {
        '0'...'7' => |char| @intCast(char - '0'),
        else => return null,
    };
}

pub fn isLabel(string: []const u8) error{InvalidLabel}!bool {
    assert(string.len > 0);
    if (!isIdent(string[0..1]))
        return false;
    if (!isIdent(string))
        return error.InvalidLabel;
    return true;
}

pub fn isIdent(string: []const u8) bool {
    for (string, 0..) |char, i| {
        switch (char) {
            'a'...'z', 'A'...'Z', '_' => {},
            '0'...'9' => if (i == 0) return false,
            else => return false,
        }
    }
    return true;
}

/// Time: `O(a.len*b.len)`, space: `O(b.len)`.
/// Uses `u8` instead of `usize` to save memory... a larger integer type is not necessary.
/// Asserts that buffer can hold `b.len + 1` items.
/// Asserts that calculated distances can fit in `u8`.
pub fn editDistance(a: []const u8, b: []const u8, buffer: []u8) u8 {
    assert(buffer.len >= b.len + 1);
    assert(@max(a.len, b.len) <= std.math.maxInt(u8));

    for (0..b.len + 1) |j|
        buffer[j] = @intCast(j);

    var previous: u8 = 0;
    for (1..a.len + 1) |i| {
        previous = buffer[0];
        buffer[0] = @intCast(i);

        for (1..b.len + 1) |j| {
            const temp = buffer[j];
            if (a[i - 1] == b[j - 1]) {
                buffer[j] = previous;
            } else {
                buffer[j] = 1 + @min(
                    buffer[j - 1],
                    previous,
                    buffer[j],
                );
            }
            previous = temp;
        }
    }
    return buffer[b.len];
}

test {
    const expect = std.testing.expect;

    const cases = [_]struct { []const u8, []const u8, usize }{
        .{ "kitten", "sitting", 3 },
        .{ "kitten", "kitten", 0 },
        .{ "", "", 0 },
        .{ "meilenstein", "levenshtein", 4 },
        .{ "levenshtein", "frankenstein", 6 },
        .{ "confide", "deceit", 6 },
        .{ "xxxsperrxxx", "conspiracy", 8 },
    };

    var buffer: [20]u8 = undefined;

    for (cases) |case| {
        const a, const b, const expected = case;
        const actual = editDistance(a, b, &buffer);
        std.log.info("[{s}]\t[{s}]\t{}\t{}", .{ a, b, expected, actual });
        try expect(actual == expected);
    }
}
