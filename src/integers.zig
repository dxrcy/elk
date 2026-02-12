const std = @import("std");
const math = std.math;
const testing = std.testing;
const assert = std.debug.assert;

// TODO: Add more variants
const Error = error{InvalidInteger};

pub fn Integer(comptime bits: u16) type {
    // TODO: Maybe should repr as
    // struct {
    //     is_signed: bool,
    //     underlying: u16,
    // }

    return union(enum) {
        unsigned: Unsigned,
        signed: Signed,

        const Unsigned = @Int(.unsigned, bits);
        const Signed = @Int(.signed, bits);
        const Oversize = @Int(.signed, bits + 1);

        pub fn asUnsigned(integer: @This()) ?Unsigned {
            return switch (integer) {
                .unsigned => |unsigned| unsigned,
                .signed => |signed| std.math.cast(Unsigned, signed),
            };
        }

        // TODO: Rename (misleading)
        pub fn castTo(integer: @This(), comptime T: type) ?T {
            const info = @typeInfo(T).int;
            assert(info.signedness == .unsigned);

            return switch (integer) {
                .unsigned => |unsigned| std.math.cast(T, unsigned),
                .signed => |signed| @bitCast(
                    std.math.cast(@Int(.signed, info.bits), signed) orelse
                        return null,
                ),
            };
        }
    };
}

const Sign = enum(i2) {
    negative = -1,
    positive = 1,
};

const Prefix = struct {
    radix: Radix,
    leading_zeros: bool,

    const Radix = enum(u8) {
        binary = 2,
        octal = 8,
        decimal = 10,
        hex = 16,

        pub fn parse_digit(radix: Radix, char: u8) ?u8 {
            return switch (radix) {
                .binary => switch (char) {
                    '0' => 0,
                    '1' => 1,
                    else => null,
                },
                .octal => switch (char) {
                    '0'...'7' => char - '0',
                    else => null,
                },
                .decimal => switch (char) {
                    '0'...'9' => char - '0',
                    else => null,
                },
                .hex => switch (char) {
                    '0'...'9' => char - '0',
                    'A'...'F' => char - 'A' + 10,
                    'a'...'f' => char - 'a' + 10,
                    else => null,
                },
            };
        }
    };
};

const CharIter = struct {
    string: []const u8,

    pub fn new(string: []const u8) CharIter {
        return .{ .string = string };
    }

    pub fn next(iter: *CharIter) ?u8 {
        const char = iter.peek() orelse
            return null;
        iter.string = iter.string[1..];
        return char;
    }

    pub fn peek(iter: *const CharIter) ?u8 {
        if (iter.string.len == 0)
            return null;
        return iter.string[0];
    }
};

pub fn tryInteger(string: []const u8) Error!?Integer(16) {
    if (string.len == 0)
        return null;

    var chars = CharIter.new(string);

    const first_sign = takeSign(&chars);

    const prefix = switch (try takePrefix(&chars)) {
        .regular => |prefix| prefix,
        .single_zero => return .{ .unsigned = 0 },
        .non_integer => {
            // Initial sign always indicates an integer
            if (first_sign != null)
                return error.InvalidInteger;
            return null;
        },
    };

    const second_sign = takeSign(&chars);

    const sign = try reconcileSigns(first_sign, second_sign);

    // Check if anything follows prefix (also covers "" case)
    // Otherwise loop would be skipped and value assumed to be `0`
    if (chars.peek() == null)
        return endOfInteger(sign, prefix);

    var integer: Integer(16).Oversize = 0;

    while (chars.next()) |char| {
        const digit = prefix.radix.parse_digit(char) orelse
            return endOfInteger(sign, prefix);

        integer = math.mul(Integer(16).Oversize, integer, @intFromEnum(prefix.radix)) catch
            return error.InvalidInteger;
        integer = math.add(Integer(16).Oversize, integer, digit) catch
            return error.InvalidInteger;
    }

    // Try to fit in the appropriate `Integer` variant
    // Always represent `0` as unsigned.
    return if (sign == .negative and integer != 0) .{
        .signed = math.cast(Integer(16).Signed, -1 * integer) orelse
            return error.InvalidInteger,
    } else .{
        .unsigned = math.cast(Integer(16).Unsigned, integer) orelse
            return error.InvalidInteger,
    };
}

fn takeSign(chars: *CharIter) ?Sign {
    const char = chars.peek() orelse
        return null;
    const sign: Sign = switch (char) {
        '+' => .positive,
        '-' => .negative,
        else => return null,
    };
    _ = chars.next();
    return sign;
}

fn takePrefix(chars: *CharIter) !union(enum) {
    regular: Prefix,
    single_zero,
    non_integer,
} {
    // Only take ONE leading zero here
    // Caller can disallow "00x..." etc.
    const leading_zeros =
        if (chars.peek() == '0') blk: {
            _ = chars.next();
            break :blk true;
        } else false;

    // "0" or ""
    const peeked = chars.peek() orelse
        return if (leading_zeros) .single_zero else .non_integer;

    const radix: Prefix.Radix, const next_char = switch (peeked) {
        'b', 'B' => .{ .binary, true },
        'o', 'O' => .{ .octal, true },
        'x', 'X' => .{ .hex, true },

        '#' => if (leading_zeros)
            return error.InvalidInteger // Disallow "0#..."
        else
            .{ .decimal, true },

        // No prefix, caller can handle this character
        '0'...'9' => .{ .decimal, false },

        // Disallow "0-..." and "0+..." as well as "--...", "-+...", etc.
        // Caller should have already consumed any sign character before
        // prefix.
        '-', '+' => return error.InvalidInteger,

        else => return if (leading_zeros)
            // Leading zero always indicates an integer
            error.InvalidInteger
        else
            .non_integer,
    };

    if (next_char)
        _ = chars.next();

    return .{ .regular = .{
        .radix = radix,
        .leading_zeros = leading_zeros,
    } };
}

fn reconcileSigns(first_opt: ?Sign, second_opt: ?Sign) !?Sign {
    if (first_opt) |first| {
        // Disallow multiple sign characters: "-x-...", "++...", etc
        return if (second_opt) |_| error.InvalidInteger else first;
    } else {
        return if (second_opt) |second| second else null;
    }
}

fn endOfInteger(sign: ?Sign, prefix: Prefix) !?Integer(16) {
    // Any of these conditions indicate an invalid integer token (as opposed to
    // a possibly-valid non-integer token)
    // Note that a leading decimal digit (`^[0-9]`) will lead to a pre-prefix
    // zero, or an implicit decimal radix
    return if (sign != null or
        prefix.leading_zeros or
        prefix.radix == .decimal) error.InvalidInteger else null;
}

test takeSign {
    const cases = [_]struct { []const u8, []const u8, ?Sign }{
        .{ "", "", null },
        .{ "123", "123", null },
        .{ "-", "", .negative },
        .{ "+-", "-", .positive },
        .{ "-123", "123", .negative },
        .{ "+123", "123", .positive },
    };
    for (cases) |case| {
        const input, const expected_rest, const expected_result = case;
        var chars: CharIter = .new(input);
        const result = takeSign(&chars);
        try testing.expect(std.mem.eql(u8, expected_rest, chars.string));
        try testing.expect(expected_result == result);
    }
}

test takePrefix {
    const log = std.log.scoped(.takePrefix);

    const cases = [_]struct {
        []const u8,
        []const u8,
        @typeInfo(@TypeOf(takePrefix)).@"fn".return_type.?,
    }{
        .{ "0#", "", error.InvalidInteger },
        .{ "0#01", "", error.InvalidInteger },
        .{ "-1", "", error.InvalidInteger },
        .{ "0-", "", error.InvalidInteger },
        .{ "0+1", "", error.InvalidInteger },
        .{ "", "", .non_integer },
        .{ "a", "a", .non_integer },
        .{ "ax", "ax", .non_integer },
        .{ "no", "no", .non_integer },
        .{ "!@#", "!@#", .non_integer },
        .{ "0", "", .single_zero },
        .{ "00", "0", .{ .regular = .{ .radix = .decimal, .leading_zeros = true } } },
        .{ "123", "123", .{ .regular = .{ .radix = .decimal, .leading_zeros = false } } },
        .{ "0123", "123", .{ .regular = .{ .radix = .decimal, .leading_zeros = true } } },
        .{ "00#01", "0#01", .{ .regular = .{ .radix = .decimal, .leading_zeros = true } } },
        .{ "#abc", "abc", .{ .regular = .{ .radix = .decimal, .leading_zeros = false } } },
        .{ "x", "", .{ .regular = .{ .radix = .hex, .leading_zeros = false } } },
        .{ "0x", "", .{ .regular = .{ .radix = .hex, .leading_zeros = true } } },
        .{ "0x12", "12", .{ .regular = .{ .radix = .hex, .leading_zeros = true } } },
        .{ "xaaa", "aaa", .{ .regular = .{ .radix = .hex, .leading_zeros = false } } },
        .{ "ooo", "oo", .{ .regular = .{ .radix = .octal, .leading_zeros = false } } },
        .{ "0b0101", "0101", .{ .regular = .{ .radix = .binary, .leading_zeros = true } } },
    };

    for (cases) |case| {
        const input, const expected_rest, const expected_result = case;
        log.info("INPUT:   \t\"{s}\"", .{input});
        log.info("EXPECTED:\t\"{s}\"\t{!}", .{ expected_rest, expected_result });
        var chars: CharIter = .new(input);
        const result = takePrefix(&chars);
        log.info("ACTUAL:  \t\"{s}\"\t{!}", .{ chars.string, result });
        if (!std.meta.isError(result))
            try testing.expect(std.mem.eql(u8, expected_rest, chars.string));
        try testing.expect(std.meta.eql(expected_result, result));
    }
}

test tryInteger {
    const log = std.log.scoped(.tryInteger);

    const cases = [_]struct {
        []const u8,
        Error!?Integer(16),
    }{
        // Non-integer and invalid
        .{ "", null },
        .{ "a", null },
        .{ "z", null },
        .{ "&", null },
        .{ ",", null },
        .{ "b2", null },
        .{ "o8", null },
        .{ "xg", null },
        .{ "x1g", null },
        .{ "xag", null },
        .{ "O18", null },
        .{ "b", null },
        .{ "o", null },
        .{ "x", null },
        .{ "-", error.InvalidInteger },
        .{ "+", error.InvalidInteger },
        .{ "#", error.InvalidInteger },
        .{ "#-", error.InvalidInteger },
        .{ "-#", error.InvalidInteger },
        .{ "-#-", error.InvalidInteger },
        .{ "-#-24", error.InvalidInteger },
        .{ "0#0", error.InvalidInteger },
        .{ "0#24", error.InvalidInteger },
        .{ "-0#24", error.InvalidInteger },
        .{ "0#-24", error.InvalidInteger },
        .{ "-0#-24", error.InvalidInteger },
        .{ "x-", error.InvalidInteger },
        .{ "-x", error.InvalidInteger },
        .{ "-x-", error.InvalidInteger },
        .{ "-x-24", error.InvalidInteger },
        .{ "0x", error.InvalidInteger },
        .{ "0x-", error.InvalidInteger },
        .{ "-0x", error.InvalidInteger },
        .{ "-0x-", error.InvalidInteger },
        .{ "-0x-24", error.InvalidInteger },
        .{ "0-x24", error.InvalidInteger },
        .{ "00x4", error.InvalidInteger },
        .{ "0f", error.InvalidInteger },
        .{ "0x", error.InvalidInteger },
        .{ "0xx", error.InvalidInteger },
        .{ "000x", error.InvalidInteger },
        .{ "000xx", error.InvalidInteger },
        .{ "000a", error.InvalidInteger },
        .{ "000aaa", error.InvalidInteger },
        .{ "000xhh", error.InvalidInteger },
        .{ "1xx", error.InvalidInteger },
        .{ "123x", error.InvalidInteger },
        .{ "123xx", error.InvalidInteger },
        .{ "123a", error.InvalidInteger },
        .{ "123aaa", error.InvalidInteger },
        .{ "123xhh", error.InvalidInteger },
        .{ "##", error.InvalidInteger },
        .{ "-##", error.InvalidInteger },
        .{ "#b", error.InvalidInteger },
        .{ "#-b", error.InvalidInteger },
        .{ "-#b", error.InvalidInteger },
        .{ "0b2", error.InvalidInteger },
        .{ "0o8", error.InvalidInteger },
        .{ "0xg", error.InvalidInteger },
        .{ "-b2", error.InvalidInteger },
        .{ "-o8", error.InvalidInteger },
        .{ "-xg", error.InvalidInteger },
        .{ "b-2", error.InvalidInteger },
        .{ "o-8", error.InvalidInteger },
        .{ "x-g", error.InvalidInteger },
        .{ "--4", error.InvalidInteger },
        .{ "-+4", error.InvalidInteger },
        .{ "++4", error.InvalidInteger },
        .{ "+-4", error.InvalidInteger },
        .{ "#--4", error.InvalidInteger },
        .{ "#-+4", error.InvalidInteger },
        .{ "#++4", error.InvalidInteger },
        .{ "#+-4", error.InvalidInteger },
        .{ "-#-4", error.InvalidInteger },
        .{ "-#+4", error.InvalidInteger },
        .{ "+#+4", error.InvalidInteger },
        .{ "+#-4", error.InvalidInteger },
        .{ "--#4", error.InvalidInteger },
        .{ "-+#4", error.InvalidInteger },
        .{ "++#4", error.InvalidInteger },
        .{ "+-#4", error.InvalidInteger },
        // Decimal
        .{ "0", .{ .unsigned = 0 } },
        .{ "00", .{ .unsigned = 0 } },
        .{ "#0", .{ .unsigned = 0 } },
        .{ "#00", .{ .unsigned = 0 } },
        .{ "-#0", .{ .unsigned = 0 } },
        .{ "+#0", .{ .unsigned = 0 } },
        .{ "-#00", .{ .unsigned = 0 } },
        .{ "#-0", .{ .unsigned = 0 } },
        .{ "#+0", .{ .unsigned = 0 } },
        .{ "#-00", .{ .unsigned = 0 } },
        .{ "4", .{ .unsigned = 4 } },
        .{ "+4", .{ .unsigned = 4 } },
        .{ "4284", .{ .unsigned = 4284 } },
        .{ "004284", .{ .unsigned = 4284 } },
        .{ "#4", .{ .unsigned = 4 } },
        .{ "#4284", .{ .unsigned = 4284 } },
        .{ "#004284", .{ .unsigned = 4284 } },
        .{ "-4", .{ .signed = -4 } },
        .{ "+4", .{ .unsigned = 4 } },
        .{ "-4284", .{ .signed = -4284 } },
        .{ "-004284", .{ .signed = -4284 } },
        .{ "-#4", .{ .signed = -4 } },
        .{ "+#4", .{ .unsigned = 4 } },
        .{ "-#4284", .{ .signed = -4284 } },
        .{ "-#004284", .{ .signed = -4284 } },
        .{ "#-4", .{ .signed = -4 } },
        .{ "#+4", .{ .unsigned = 4 } },
        .{ "#-4284", .{ .signed = -4284 } },
        .{ "#-004284", .{ .signed = -4284 } },
        .{ "-4", .{ .signed = -4 } },
        .{ "+4", .{ .unsigned = 4 } },
        .{ "-4284", .{ .signed = -4284 } },
        .{ "-004284", .{ .signed = -4284 } },
        .{ "-#4", .{ .signed = -4 } },
        .{ "+#4", .{ .unsigned = 4 } },
        .{ "-#4284", .{ .signed = -4284 } },
        .{ "-#004284", .{ .signed = -4284 } },
        // Hex
        .{ "x0", .{ .unsigned = 0x0 } },
        .{ "x00", .{ .unsigned = 0x0 } },
        .{ "0x0", .{ .unsigned = 0x0 } },
        .{ "0x00", .{ .unsigned = 0x0 } },
        .{ "-x0", .{ .unsigned = 0x0 } },
        .{ "+x0", .{ .unsigned = 0x0 } },
        .{ "-x00", .{ .unsigned = 0x0 } },
        .{ "0x-0", .{ .unsigned = 0x0 } },
        .{ "0x-00", .{ .unsigned = 0x0 } },
        .{ "-0x0", .{ .unsigned = 0x0 } },
        .{ "-0x00", .{ .unsigned = 0x0 } },
        .{ "x4", .{ .unsigned = 0x4 } },
        .{ "x004", .{ .unsigned = 0x4 } },
        .{ "x429", .{ .unsigned = 0x429 } },
        .{ "0x4", .{ .unsigned = 0x4 } },
        .{ "0x004", .{ .unsigned = 0x4 } },
        .{ "0x429", .{ .unsigned = 0x429 } },
        .{ "-x4", .{ .signed = -0x4 } },
        .{ "+x4", .{ .unsigned = 0x4 } },
        .{ "-x004", .{ .signed = -0x4 } },
        .{ "-x429", .{ .signed = -0x429 } },
        .{ "-0x4", .{ .signed = -0x4 } },
        .{ "+0x4", .{ .unsigned = 0x4 } },
        .{ "-0x004", .{ .signed = -0x4 } },
        .{ "-0x429", .{ .signed = -0x429 } },
        .{ "x-4", .{ .signed = -0x4 } },
        .{ "x-004", .{ .signed = -0x4 } },
        .{ "x+004", .{ .unsigned = 0x4 } },
        .{ "x-429", .{ .signed = -0x429 } },
        .{ "-0x4", .{ .signed = -0x4 } },
        .{ "-0x004", .{ .signed = -0x4 } },
        .{ "-0x4af", .{ .signed = -0x4af } },
        .{ "+0x4af", .{ .unsigned = 0x4af } },
        // Octal
        .{ "o0", .{ .unsigned = 0x0 } },
        .{ "o00", .{ .unsigned = 0x0 } },
        .{ "0o0", .{ .unsigned = 0x0 } },
        .{ "0o00", .{ .unsigned = 0x0 } },
        .{ "-o0", .{ .unsigned = 0x0 } },
        .{ "-o00", .{ .unsigned = 0x0 } },
        .{ "o-0", .{ .unsigned = 0x0 } },
        .{ "o-00", .{ .unsigned = 0x0 } },
        .{ "-0o0", .{ .unsigned = 0x0 } },
        .{ "-0o00", .{ .unsigned = 0x0 } },
        .{ "0o-0", .{ .unsigned = 0x0 } },
        .{ "0o-00", .{ .unsigned = 0x0 } },
        .{ "o4", .{ .unsigned = 0x4 } },
        .{ "o004", .{ .unsigned = 0x4 } },
        .{ "o427", .{ .unsigned = 0x117 } },
        .{ "0o4", .{ .unsigned = 0x4 } },
        .{ "0o004", .{ .unsigned = 0x4 } },
        .{ "0o427", .{ .unsigned = 0x117 } },
        .{ "-o4", .{ .signed = -0x4 } },
        .{ "-o004", .{ .signed = -0x4 } },
        .{ "-o427", .{ .signed = -0x117 } },
        .{ "-0o4", .{ .signed = -0x4 } },
        .{ "-0o004", .{ .signed = -0x4 } },
        .{ "-0o427", .{ .signed = -0x117 } },
        .{ "o-4", .{ .signed = -0x4 } },
        .{ "o-004", .{ .signed = -0x4 } },
        .{ "o-427", .{ .signed = -0x117 } },
        .{ "0o-4", .{ .signed = -0x4 } },
        .{ "0o-004", .{ .signed = -0x4 } },
        .{ "0o-427", .{ .signed = -0x117 } },
        // Binary
        .{ "b0", .{ .unsigned = 0b0 } },
        .{ "b00", .{ .unsigned = 0b0 } },
        .{ "0b0", .{ .unsigned = 0b0 } },
        .{ "0b00", .{ .unsigned = 0b0 } },
        .{ "-b0", .{ .unsigned = 0b0 } },
        .{ "-b00", .{ .unsigned = 0b0 } },
        .{ "b-0", .{ .unsigned = 0b0 } },
        .{ "b-00", .{ .unsigned = 0b0 } },
        .{ "-0b0", .{ .unsigned = 0b0 } },
        .{ "-0b00", .{ .unsigned = 0b0 } },
        .{ "0b-0", .{ .unsigned = 0b0 } },
        .{ "0b-00", .{ .unsigned = 0b0 } },
        .{ "b1", .{ .unsigned = 0b1 } },
        .{ "b101", .{ .unsigned = 0b101 } },
        .{ "b00101", .{ .unsigned = 0b101 } },
        .{ "0b1", .{ .unsigned = 0b1 } },
        .{ "0b101", .{ .unsigned = 0b101 } },
        .{ "0b00101", .{ .unsigned = 0b101 } },
        .{ "-b1", .{ .signed = -0b1 } },
        .{ "-b101", .{ .signed = -0b101 } },
        .{ "-b00101", .{ .signed = -0b101 } },
        .{ "b-1", .{ .signed = -0b1 } },
        .{ "b-101", .{ .signed = -0b101 } },
        .{ "b-00101", .{ .signed = -0b101 } },
        .{ "-0b1", .{ .signed = -0b1 } },
        .{ "-0b101", .{ .signed = -0b101 } },
        .{ "-0b00101", .{ .signed = -0b101 } },
        .{ "0b-1", .{ .signed = -0b1 } },
        .{ "0b-101", .{ .signed = -0b101 } },
        .{ "0b-00101", .{ .signed = -0b101 } },
        // Bounds checking
        .{ "0xffff", .{ .unsigned = 0xffff } },
        .{ "65535", .{ .unsigned = 0xffff } },
        .{ "0x10000", error.InvalidInteger },
        .{ "65536", error.InvalidInteger },
        .{ "-0x8000", .{ .signed = -0x8000 } },
        .{ "-32768", .{ .signed = -0x8000 } },
        .{ "-0x8001", error.InvalidInteger },
        .{ "-32769", error.InvalidInteger },
    };

    for (cases) |case| {
        const input, const expected_result = case;
        log.info("INPUT:   \t\"{s}\"", .{input});
        log.info("EXPECTED:\t{!?}", .{expected_result});
        const result = tryInteger(input);
        log.info("ACTUAL:  \t{!?}", .{result});
        try testing.expect(std.meta.eql(expected_result, result));
    }
}
