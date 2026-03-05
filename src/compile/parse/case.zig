const std = @import("std");
const assert = std.debug.assert;

pub fn isLowercaseAlpha(string: []const u8) bool {
    assert(string.len > 0);
    for (string) |char| {
        if (!std.ascii.isLower(char))
            return false;
    }
    return true;
}

pub fn isUppercaseAlpha(string: []const u8) bool {
    assert(string.len > 0);
    for (string) |char| {
        if (!std.ascii.isUpper(char))
            return false;
    }
    return true;
}

pub fn hasUppercaseAlpha(string: []const u8) bool {
    assert(string.len > 0);
    for (string) |char| {
        if (std.ascii.isUpper(char))
            return true;
    }
    return false;
}

/// Allows single `_` to delimit words.
/// Allows `[0-9]` in any place uppercase OR lowercase is allowed, but not BEFORE lowercase.
pub fn isPascalCase(string: []const u8) bool {
    assert(string.len > 0);

    const Char = enum { none, upper, lower, digit, delim };
    var previous: Char = .none;

    for (string) |char| {
        const current: Char = switch (char) {
            'A'...'Z' => .upper,
            'a'...'z' => .lower,
            '0'...'9' => .digit,
            '_' => .delim,
            else => return false,
        };

        switch (previous) {
            .none, .delim => switch (current) {
                .lower, .delim => return false,
                else => {},
            },
            .upper => switch (current) {
                .upper => return false,
                else => {},
            },
            .lower => {},
            .digit => switch (current) {
                .lower => return false,
                else => {},
            },
        }

        previous = current;
    }

    switch (previous) {
        .none => unreachable,
        .delim => return false,
        else => {},
    }

    return true;
}

test isPascalCase {
    const expect = std.testing.expect;

    try expect(isPascalCase("A"));
    try expect(isPascalCase("Abc"));
    try expect(isPascalCase("AbcDef"));
    try expect(isPascalCase("AbcDefGhi"));
    try expect(isPascalCase("Abc_Def_Ghi"));
    try expect(isPascalCase("AbcDef_Ghi"));
    try expect(isPascalCase("Abc12"));
    try expect(isPascalCase("Abc_12"));
    try expect(isPascalCase("Abc_12Def"));
    try expect(isPascalCase("Abc12Def"));
    try expect(isPascalCase("12")); // whatever
    try expect(isPascalCase("12_12"));

    try expect(!isPascalCase("a"));
    try expect(!isPascalCase("abc"));
    try expect(!isPascalCase("Abc_def"));
    try expect(!isPascalCase("abc_Def"));
    try expect(!isPascalCase("_"));
    try expect(!isPascalCase("Abc_"));
    try expect(!isPascalCase("Abc__"));
    try expect(!isPascalCase("_Abc"));
    try expect(!isPascalCase("Abc__Def"));
    try expect(!isPascalCase("Abc___Def"));
    try expect(!isPascalCase("Abc12def"));
    try expect(!isPascalCase("12def"));
}
