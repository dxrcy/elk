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

// Naive implementation.
// Time: `O(2^(n+m))`, space: `O(nm)`.
// PERF: Can use a far more efficient algorithm
pub fn editDistance(a: []const u8, b: []const u8, max: usize) usize {
    // Skip unnecessary (expensive!) calculation
    if (diff(a.len, b.len) > max)
        return std.math.maxInt(usize);
    return editDistanceInner(a, b);
}

fn editDistanceInner(a: []const u8, b: []const u8) usize {
    if (a.len == 0)
        return b.len;
    if (b.len == 0)
        return a.len;
    if (std.ascii.toLower(a[0]) == std.ascii.toLower(b[0]))
        return editDistanceInner(a[1..], b[1..]);
    return 1 + @min(
        editDistanceInner(a, b[1..]),
        editDistanceInner(a[1..], b),
        editDistanceInner(a[1..], b[1..]),
    );
}

fn diff(a: usize, b: usize) usize {
    return @max(a, b) - @min(a, b);
}
