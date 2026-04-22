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
