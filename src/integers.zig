const std = @import("std");
const math = std.math;
const Signedness = std.builtin.Signedness;
const testing = std.testing;
const assert = std.debug.assert;

pub const Error = error{
    InvalidDigit,
    MalformedInteger,
    ExpectedDigit,
    IntegerTooLarge,
};

pub fn SourceInt(comptime bits: u16) type {
    return struct {
        const Self = @This();

        /// Do not use without considering `signedness`.
        underlying: Unsigned,
        signedness: Signedness,
        radix: ?Radix,
        // TODO: Add field for whether integer uses 'extension' syntax. Eg. `x-1`

        const Unsigned = @Int(.unsigned, bits);
        const Signed = @Int(.signed, bits);
        const Oversize = @Int(.signed, bits + 1);

        fn asUnsigned(integer: Self) Unsigned {
            assert(integer.signedness == .unsigned);
            return integer.underlying;
        }

        fn asSigned(integer: Self) Signed {
            assert(integer.signedness == .signed);
            return @as(Signed, @bitCast(integer.underlying));
        }

        pub fn castToUnsigned(integer: Self) ?Unsigned {
            return switch (integer.signedness) {
                .unsigned => integer.asUnsigned(),
                .signed => math.cast(Unsigned, integer.asSigned()),
            };
        }

        pub fn castToSmaller(integer: Self, comptime T: type) error{IntegerTooLarge}!T {
            assert(@typeInfo(T).int.bits < bits);
            return switch (integer.signedness) {
                .unsigned => math.cast(T, integer.asUnsigned()),
                .signed => math.cast(T, integer.asSigned()),
            } orelse
                return error.IntegerTooLarge;
        }
    };
}

const Word = SourceInt(16);

const Sign = enum(i2) {
    negative = -1,
    positive = 1,
};

const Prefix = struct {
    radix: ?Radix,
    leading_zeros: bool,
};

pub const Radix = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hex = 16,

    pub const default: Radix = .decimal;

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

pub fn tryInteger(string: []const u8) Error!?Word {
    if (string.len == 0)
        return null;

    var chars = CharIter.new(string);

    const first_sign = takeSign(&chars);
    const prefix = switch (try takePrefix(&chars)) {
        .regular => |prefix| prefix,
        .single_zero => {
            return try makeWord(0, null, null);
        },
        .non_integer => {
            // Initial sign always indicates an integer
            if (first_sign != null)
                return error.InvalidDigit;
            return null;
        },
        .empty => {
            // Initial sign always indicates an integer
            if (first_sign != null)
                return error.ExpectedDigit;
            return null;
        },
    };

    const second_sign = takeSign(&chars);
    const sign = try reconcileSigns(first_sign, second_sign);

    // Check if anything follows prefix (also covers "" case)
    // Otherwise loop would be skipped and value assumed to be `0`
    if (chars.peek() == null)
        return endOfInteger(sign, prefix, null);

    var oversize: Word.Oversize = 0;
    const real_radix = prefix.radix orelse Radix.default;

    while (chars.next()) |char| {
        const digit = real_radix.parse_digit(char) orelse
            return endOfInteger(sign, prefix, char);
        appendDigit(&oversize, real_radix, digit) catch
            return error.IntegerTooLarge;
    }

    return try makeWord(oversize, sign, prefix.radix);
}

fn appendDigit(
    oversize: *Word.Oversize,
    radix: Radix,
    digit: u8,
) error{Overflow}!void {
    oversize.* = try math.mul(Word.Oversize, oversize.*, @intFromEnum(radix));
    oversize.* = try math.add(Word.Oversize, oversize.*, digit);
}

fn makeWord(oversize: Word.Oversize, sign: ?Sign, radix: ?Radix) Error!Word {
    // Always represent `0` as unsigned.
    const signedness: Signedness =
        if (sign == .negative and oversize != 0) .signed else .unsigned;

    // Try to fit in the appropriate `SourceInt` variant
    const underlying: Word.Unsigned = switch (signedness) {
        .unsigned => @bitCast(math.cast(Word.Unsigned, oversize) orelse
            return error.IntegerTooLarge),
        .signed => @bitCast(math.cast(Word.Signed, -1 * oversize) orelse
            return error.IntegerTooLarge),
    };

    return .{
        .underlying = underlying,
        .signedness = signedness,
        .radix = radix,
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
    empty,
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
        return if (leading_zeros) .single_zero else .empty;

    const radix: ?Radix, const next_char = switch (peeked) {
        'b', 'B' => .{ .binary, true },
        'o', 'O' => .{ .octal, true },
        'x', 'X' => .{ .hex, true },

        '#' => if (leading_zeros)
            return error.MalformedInteger // Disallow "0#..."
        else
            .{ .decimal, true },

        // No prefix, caller can handle this character
        '0'...'9' => .{ null, false },

        // Disallow "0-..." and "0+..." as well as "--...", "-+...", etc.
        // Caller should have already consumed any sign character before prefix.
        '-', '+' => return error.MalformedInteger,

        else => return if (leading_zeros)
            // Leading zero always indicates an integer
            error.InvalidDigit
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
        return if (second_opt) |_| error.MalformedInteger else first;
    } else {
        return if (second_opt) |second| second else null;
    }
}

fn endOfInteger(sign: ?Sign, prefix: Prefix, char: ?u8) !?Word {
    // Any of these conditions indicate an invalid integer token (as opposed to
    // a possibly-valid non-integer token)
    // Note that a leading decimal digit (`^[0-9]`) will lead to a pre-prefix
    // zero, or an implicit decimal radix
    if (sign != null or
        prefix.leading_zeros or
        (prefix.radix orelse .decimal) == .decimal)
    {
        return if (char == null) error.ExpectedDigit else error.InvalidDigit;
    } else {
        return null;
    }
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
        .{ "00", "0", .{ .regular = .{ .radix = null, .leading_zeros = true } } },
        .{ "123", "123", .{ .regular = .{ .radix = null, .leading_zeros = false } } },
        .{ "0123", "123", .{ .regular = .{ .radix = null, .leading_zeros = true } } },
        .{ "00#01", "0#01", .{ .regular = .{ .radix = null, .leading_zeros = true } } },
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
        Error!?Word,
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
        .{ "0", .{ .underlying = 0, .signedness = .unsigned, .radix = null } },
        .{ "00", .{ .underlying = 0, .signedness = .unsigned, .radix = null } },
        .{ "#0", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "#00", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "-#0", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "+#0", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "-#00", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "#-0", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "#+0", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "#-00", .{ .underlying = 0, .signedness = .unsigned, .radix = .decimal } },
        .{ "4", .{ .underlying = 4, .signedness = .unsigned, .radix = null } },
        .{ "+4", .{ .underlying = 4, .signedness = .unsigned, .radix = null } },
        .{ "4284", .{ .underlying = 4284, .signedness = .unsigned, .radix = null } },
        .{ "004284", .{ .underlying = 4284, .signedness = .unsigned, .radix = null } },
        .{ "#4", .{ .underlying = 4, .signedness = .unsigned, .radix = .decimal } },
        .{ "#4284", .{ .underlying = 4284, .signedness = .unsigned, .radix = .decimal } },
        .{ "#004284", .{ .underlying = 4284, .signedness = .unsigned, .radix = .decimal } },
        .{ "-4", .{ .underlying = @bitCast(@as(i16, -4)), .signedness = .signed, .radix = null } },
        .{ "-4284", .{ .underlying = @bitCast(@as(i16, -4284)), .signedness = .signed, .radix = null } },
        .{ "-004284", .{ .underlying = @bitCast(@as(i16, -4284)), .signedness = .signed, .radix = null } },
        .{ "-#4", .{ .underlying = @bitCast(@as(i16, -4)), .signedness = .signed, .radix = .decimal } },
        .{ "+#4", .{ .underlying = 4, .signedness = .unsigned, .radix = .decimal } },
        .{ "-#4284", .{ .underlying = @bitCast(@as(i16, -4284)), .signedness = .signed, .radix = .decimal } },
        .{ "-#004284", .{ .underlying = @bitCast(@as(i16, -4284)), .signedness = .signed, .radix = .decimal } },
        .{ "#-4", .{ .underlying = @bitCast(@as(i16, -4)), .signedness = .signed, .radix = .decimal } },
        .{ "#+4", .{ .underlying = 4, .signedness = .unsigned, .radix = .decimal } },
        .{ "#-4284", .{ .underlying = @bitCast(@as(i16, -4284)), .signedness = .signed, .radix = .decimal } },
        .{ "#-004284", .{ .underlying = @bitCast(@as(i16, -4284)), .signedness = .signed, .radix = .decimal } },
        // // Hex
        .{ "x0", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "x00", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "0x0", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "0x00", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "-x0", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "+x0", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "-x00", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "0x-0", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "0x-00", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "-0x0", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "-0x00", .{ .underlying = 0x0, .signedness = .unsigned, .radix = .hex } },
        .{ "x4", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "x004", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "x429", .{ .underlying = 0x429, .signedness = .unsigned, .radix = .hex } },
        .{ "0x4", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "0x004", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "0x429", .{ .underlying = 0x429, .signedness = .unsigned, .radix = .hex } },
        .{ "-x4", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "+x4", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "-x004", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "-x429", .{ .underlying = @bitCast(@as(i16, -0x429)), .signedness = .signed, .radix = .hex } },
        .{ "-0x4", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "+0x4", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "-0x004", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "-0x429", .{ .underlying = @bitCast(@as(i16, -0x429)), .signedness = .signed, .radix = .hex } },
        .{ "x-4", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "x-004", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "x+004", .{ .underlying = 0x4, .signedness = .unsigned, .radix = .hex } },
        .{ "x-429", .{ .underlying = @bitCast(@as(i16, -0x429)), .signedness = .signed, .radix = .hex } },
        .{ "-0x4", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "-0x004", .{ .underlying = @bitCast(@as(i16, -0x4)), .signedness = .signed, .radix = .hex } },
        .{ "-0x4af", .{ .underlying = @bitCast(@as(i16, -0x4af)), .signedness = .signed, .radix = .hex } },
        .{ "+0x4af", .{ .underlying = 0x4af, .signedness = .unsigned, .radix = .hex } },
        // // Octal
        .{ "o0", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "o00", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "0o0", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "0o00", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "-o0", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "-o00", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "o-0", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "o-00", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "-0o0", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "-0o00", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "0o-0", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "0o-00", .{ .underlying = 0o0, .signedness = .unsigned, .radix = .octal } },
        .{ "o4", .{ .underlying = 0o4, .signedness = .unsigned, .radix = .octal } },
        .{ "o004", .{ .underlying = 0o4, .signedness = .unsigned, .radix = .octal } },
        .{ "o427", .{ .underlying = 0o427, .signedness = .unsigned, .radix = .octal } },
        .{ "0o4", .{ .underlying = 0o4, .signedness = .unsigned, .radix = .octal } },
        .{ "0o004", .{ .underlying = 0o4, .signedness = .unsigned, .radix = .octal } },
        .{ "0o427", .{ .underlying = 0o427, .signedness = .unsigned, .radix = .octal } },
        .{ "-o4", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "-o004", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "-o427", .{ .underlying = @bitCast(@as(i16, -0o427)), .signedness = .signed, .radix = .octal } },
        .{ "-0o4", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "-0o004", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "-0o427", .{ .underlying = @bitCast(@as(i16, -0o427)), .signedness = .signed, .radix = .octal } },
        .{ "o-4", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "o-004", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "o-427", .{ .underlying = @bitCast(@as(i16, -0o427)), .signedness = .signed, .radix = .octal } },
        .{ "0o-4", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "0o-004", .{ .underlying = @bitCast(@as(i16, -0o4)), .signedness = .signed, .radix = .octal } },
        .{ "0o-427", .{ .underlying = @bitCast(@as(i16, -0o427)), .signedness = .signed, .radix = .octal } },
        // // Binary
        .{ "b0", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "b00", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "0b0", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "0b00", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "-b0", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "-b00", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "b-0", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "b-00", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "-0b0", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "-0b00", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "0b-0", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "0b-00", .{ .underlying = 0b0, .signedness = .unsigned, .radix = .binary } },
        .{ "b1", .{ .underlying = 0b1, .signedness = .unsigned, .radix = .binary } },
        .{ "b101", .{ .underlying = 0b101, .signedness = .unsigned, .radix = .binary } },
        .{ "b00101", .{ .underlying = 0b101, .signedness = .unsigned, .radix = .binary } },
        .{ "0b1", .{ .underlying = 0b1, .signedness = .unsigned, .radix = .binary } },
        .{ "0b101", .{ .underlying = 0b101, .signedness = .unsigned, .radix = .binary } },
        .{ "0b00101", .{ .underlying = 0b101, .signedness = .unsigned, .radix = .binary } },
        .{ "-b1", .{ .underlying = @bitCast(@as(i16, -0b1)), .signedness = .signed, .radix = .binary } },
        .{ "-b101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "-b00101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "b-1", .{ .underlying = @bitCast(@as(i16, -0b1)), .signedness = .signed, .radix = .binary } },
        .{ "b-101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "b-00101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "-0b1", .{ .underlying = @bitCast(@as(i16, -0b1)), .signedness = .signed, .radix = .binary } },
        .{ "-0b101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "-0b00101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "0b-1", .{ .underlying = @bitCast(@as(i16, -0b1)), .signedness = .signed, .radix = .binary } },
        .{ "0b-101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        .{ "0b-00101", .{ .underlying = @bitCast(@as(i16, -0b101)), .signedness = .signed, .radix = .binary } },
        // // Bounds checking
        .{ "0xffff", .{ .underlying = 0xffff, .signedness = .unsigned, .radix = .hex } },
        .{ "65535", .{ .underlying = 0xffff, .signedness = .unsigned, .radix = null } },
        .{ "0x10000", error.InvalidInteger },
        .{ "65536", error.InvalidInteger },
        .{ "-0x8000", .{ .underlying = @bitCast(@as(i16, -0x8000)), .signedness = .signed, .radix = .hex } },
        .{ "-32768", .{ .underlying = @bitCast(@as(i16, -32768)), .signedness = .signed, .radix = null } },
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
