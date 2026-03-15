const std = @import("std");
const math = std.math;
const testing = std.testing;
const assert = std.debug.assert;

pub const Error = error{
    MalformedInteger,
    ExpectedDigit,
    InvalidDigit,
    UnexpectedDelimiter,
    IntegerTooLarge,
};

const Word = SourceInt(16);

pub fn SourceInt(comptime bits: u16) type {
    return struct {
        const Self = @This();

        /// Do not use without considering `getSign()`.
        underlying: Unsigned,
        form: Form,

        const Unsigned = @Int(.unsigned, bits);
        const Signed = @Int(.signed, bits);
        const Oversize = @Int(.signed, bits + 1);

        fn from(oversize: Oversize, form: Form) Error!Self {
            const sign =
                (if (oversize != 0) // Always represent `0` as positive.
                    form.signValue()
                else
                    null) orelse .positive;

            // Try to fit in the appropriate `SourceInt` variant
            const underlying: Unsigned = switch (sign) {
                .positive => @bitCast(math.cast(Unsigned, oversize) orelse
                    return error.IntegerTooLarge),
                .negative => @bitCast(math.cast(Signed, -1 * oversize) orelse
                    return error.IntegerTooLarge),
            };

            return .{
                .underlying = underlying,
                .form = form,
            };
        }

        fn getSign(integer: Self) Form.Sign {
            return integer.form.signValue() orelse .positive;
        }

        fn asPositive(integer: Self) Unsigned {
            assert(integer.getSign() == .positive);
            return integer.underlying;
        }

        fn asNegative(integer: Self) Signed {
            assert(integer.getSign() == .negative);
            return @as(Signed, @bitCast(integer.underlying));
        }

        pub fn castToUnsigned(integer: Self) ?Unsigned {
            return switch (integer.getSign()) {
                .positive => integer.asPositive(),
                .negative => math.cast(Unsigned, integer.asNegative()),
            };
        }

        pub fn castToSmaller(integer: Self, comptime T: type) error{IntegerTooLarge}!T {
            comptime switch (@typeInfo(T).int.signedness) {
                .unsigned => assert(@typeInfo(T).int.bits < bits),
                .signed => assert(@typeInfo(T).int.bits - 1 < bits),
            };

            return switch (integer.getSign()) {
                .positive => math.cast(T, integer.asPositive()),
                .negative => math.cast(T, integer.asNegative()),
            } orelse
                return error.IntegerTooLarge;
        }
    };
}

pub const Form = struct {
    radix: ?Radix,
    sign: ?SignInfo,
    /// Pre-radix leading zero (or any leading zero, if `radix==null`).
    /// Not affected by post-radix leading zeros.
    /// Note that `zero==false` for `"0"`, but not for `"00"`, `"000"`, etc.
    zero: bool,
    /// Contains at least one `_` character.
    delimited: bool,

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

    pub const Sign = enum(i2) {
        negative = -1,
        positive = 1,
    };

    pub const SignInfo = struct {
        value: Sign,
        /// Note that `position==.pre_radix` when `radix==null`.
        position: enum { pre_radix, post_radix },

        fn fromSingle(pre_radix: ?Form.Sign) ?Form.SignInfo {
            const value = pre_radix orelse
                return null;
            return .{
                .value = value,
                .position = .pre_radix,
            };
        }

        fn fromPair(pre_radix: ?Form.Sign, post_radix: ?Form.Sign) !?Form.SignInfo {
            if (pre_radix) |first| {
                if (post_radix) |_|
                    // Disallow multiple sign characters: "-x-...", "++...", etc
                    return error.MalformedInteger
                else
                    return .{ .value = first, .position = .pre_radix };
            } else {
                if (post_radix) |second|
                    return .{ .value = second, .position = .post_radix }
                else
                    return null;
            }
        }
    };

    pub fn signValue(form: Form) ?Sign {
        return (form.sign orelse
            return null).value;
    }
};

const Prefix = struct {
    radix: ?Form.Radix,
    zero: bool,
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
            // This early return is necessary since this zero was consumed as a
            // leading zero. If we continue with the remaining empty string, it
            // will incorrectly fail as an invalid integer.
            return try Word.from(0, .{
                .radix = null,
                .sign = Form.SignInfo.fromSingle(first_sign),
                .zero = false,
                .delimited = false,
            });
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
    const sign = try Form.SignInfo.fromPair(first_sign, second_sign);

    var form: Form = .{
        .radix = prefix.radix,
        .sign = sign,
        .zero = prefix.zero,
        .delimited = false,
    };

    // Check if anything follows prefix (also covers "" case)
    // Otherwise loop would be skipped and value assumed to be `0`
    if (chars.peek() == null)
        return endOfInteger(form, null);

    var oversize: Word.Oversize = 0;
    var last_char: enum { digit, delimiter, none } = .none;
    const real_radix = prefix.radix orelse Form.Radix.default;

    while (chars.next()) |char| {
        switch (char) {
            '_' => {
                switch (last_char) {
                    .digit => {},
                    .delimiter => return error.UnexpectedDelimiter,
                    .none => {
                        return endOfInteger(form, '_');
                    },
                }
                last_char = .delimiter;
                form.delimited = true;
                continue;
            },
            else => {
                // Non-delimiter, but may be invalid character, which will be handled next
                last_char = .digit;
            },
        }

        const digit = real_radix.parse_digit(char) orelse
            return endOfInteger(form, char);
        appendDigit(&oversize, real_radix, digit) catch
            return error.IntegerTooLarge;
    }

    switch (last_char) {
        .digit => {},
        .delimiter => return error.UnexpectedDelimiter,
        // After prefix:
        // "" is already handled
        // "_" is already handled
        .none => unreachable,
    }

    return try Word.from(oversize, form);
}

fn appendDigit(oversize: *Word.Oversize, radix: Form.Radix, digit: u8) error{Overflow}!void {
    oversize.* = try math.mul(Word.Oversize, oversize.*, @intFromEnum(radix));
    oversize.* = try math.add(Word.Oversize, oversize.*, digit);
}

fn endOfInteger(form: Form, char: ?u8) !?Word {
    // Any of these conditions indicate an invalid integer token (as opposed to
    // a possibly-valid non-integer token)
    // Note that a leading decimal digit (`^[0-9]`) will lead to a pre-prefix
    // zero, or an implicit decimal radix
    if (form.signValue() != null or
        form.zero or
        (form.radix orelse .decimal) == .decimal)
    {
        return if (char) |c| switch (c) {
            '_' => error.UnexpectedDelimiter,
            else => error.InvalidDigit,
        } else error.ExpectedDigit;
    } else {
        return null;
    }
}

fn takeSign(chars: *CharIter) ?Form.Sign {
    const char = chars.peek() orelse
        return null;
    const sign: Form.Sign = switch (char) {
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
    const zero =
        if (chars.peek() == '0') blk: {
            _ = chars.next();
            break :blk true;
        } else false;

    // "0" or ""
    const peeked = chars.peek() orelse
        return if (zero) .single_zero else .empty;

    const radix: ?Form.Radix, const next_char = switch (peeked) {
        'b', 'B' => .{ .binary, true },
        'o', 'O' => .{ .octal, true },
        'x', 'X' => .{ .hex, true },

        '#' => if (zero)
            return error.MalformedInteger // Disallow "0#..."
        else
            .{ .decimal, true },

        // No prefix, caller can handle this character
        '0'...'9' => .{ null, false },

        // Disallow "0-..." and "0+..." as well as "--...", "-+...", etc.
        // Caller should have already consumed any sign character before prefix.
        '-', '+' => return error.MalformedInteger,

        else => return if (zero)
            // Leading zero always indicates an integer
            error.InvalidDigit
        else
            .non_integer,
    };

    if (next_char)
        _ = chars.next();

    return .{ .regular = .{
        .radix = radix,
        .zero = zero,
    } };
}

test takeSign {
    const cases = [_]struct { []const u8, []const u8, ?Form.Sign }{
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
        .{ "0#", "", error.MalformedInteger },
        .{ "0#01", "", error.MalformedInteger },
        .{ "-1", "", error.MalformedInteger },
        .{ "0-", "", error.MalformedInteger },
        .{ "0+1", "", error.MalformedInteger },
        .{ "", "", .empty },
        .{ "a", "a", .non_integer },
        .{ "ax", "ax", .non_integer },
        .{ "no", "no", .non_integer },
        .{ "!@#", "!@#", .non_integer },
        .{ "0", "", .single_zero },
        .{ "00", "0", .{ .regular = .{ .radix = null, .zero = true } } },
        .{ "123", "123", .{ .regular = .{ .radix = null, .zero = false } } },
        .{ "0123", "123", .{ .regular = .{ .radix = null, .zero = true } } },
        .{ "00#01", "0#01", .{ .regular = .{ .radix = null, .zero = true } } },
        .{ "#abc", "abc", .{ .regular = .{ .radix = .decimal, .zero = false } } },
        .{ "x", "", .{ .regular = .{ .radix = .hex, .zero = false } } },
        .{ "0x", "", .{ .regular = .{ .radix = .hex, .zero = true } } },
        .{ "0x12", "12", .{ .regular = .{ .radix = .hex, .zero = true } } },
        .{ "xaaa", "aaa", .{ .regular = .{ .radix = .hex, .zero = false } } },
        .{ "ooo", "oo", .{ .regular = .{ .radix = .octal, .zero = false } } },
        .{ "0b0101", "0101", .{ .regular = .{ .radix = .binary, .zero = true } } },
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

    const cast = struct {
        fn cast(signed: i16) u16 {
            return @bitCast(signed);
        }
    }.cast;

    const cases = [_]struct {
        []const u8,
        Error!?Word,
    }{
        // Non-integer
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
        .{ "_", null },
        .{ "_123", null },
        .{ "x_", null },
        .{ "x_1", null },
        .{ "x_hh", null },
        .{ "o_99", null },
        // Invalid integers
        .{ "-", error.ExpectedDigit },
        .{ "+", error.ExpectedDigit },
        .{ "#", error.ExpectedDigit },
        .{ "#-", error.ExpectedDigit },
        .{ "-#", error.ExpectedDigit },
        .{ "-#-", error.MalformedInteger },
        .{ "-#-24", error.MalformedInteger },
        .{ "0#0", error.MalformedInteger },
        .{ "0#24", error.MalformedInteger },
        .{ "-0#24", error.MalformedInteger },
        .{ "0#-24", error.MalformedInteger },
        .{ "-0#-24", error.MalformedInteger },
        .{ "x-", error.ExpectedDigit },
        .{ "-x", error.ExpectedDigit },
        .{ "-x-", error.MalformedInteger },
        .{ "-x-24", error.MalformedInteger },
        .{ "0x", error.ExpectedDigit },
        .{ "0x-", error.ExpectedDigit },
        .{ "-0x", error.ExpectedDigit },
        .{ "-0x-", error.MalformedInteger },
        .{ "-0x-24", error.MalformedInteger },
        .{ "0-x24", error.MalformedInteger },
        .{ "00x4", error.InvalidDigit },
        .{ "0f", error.InvalidDigit },
        .{ "0x", error.ExpectedDigit },
        .{ "0xx", error.InvalidDigit },
        .{ "000x", error.InvalidDigit },
        .{ "000xx", error.InvalidDigit },
        .{ "000a", error.InvalidDigit },
        .{ "000aaa", error.InvalidDigit },
        .{ "000xhh", error.InvalidDigit },
        .{ "1xx", error.InvalidDigit },
        .{ "123x", error.InvalidDigit },
        .{ "123xx", error.InvalidDigit },
        .{ "123a", error.InvalidDigit },
        .{ "123aaa", error.InvalidDigit },
        .{ "123xhh", error.InvalidDigit },
        .{ "##", error.InvalidDigit },
        .{ "-##", error.InvalidDigit },
        .{ "#b", error.InvalidDigit },
        .{ "#-b", error.InvalidDigit },
        .{ "-#b", error.InvalidDigit },
        .{ "0b2", error.InvalidDigit },
        .{ "0o8", error.InvalidDigit },
        .{ "0xg", error.InvalidDigit },
        .{ "-b2", error.InvalidDigit },
        .{ "-o8", error.InvalidDigit },
        .{ "-xg", error.InvalidDigit },
        .{ "b-2", error.InvalidDigit },
        .{ "o-8", error.InvalidDigit },
        .{ "x-g", error.InvalidDigit },
        .{ "--4", error.MalformedInteger },
        .{ "-+4", error.MalformedInteger },
        .{ "++4", error.MalformedInteger },
        .{ "+-4", error.MalformedInteger },
        .{ "#--4", error.InvalidDigit },
        .{ "#-+4", error.InvalidDigit },
        .{ "#++4", error.InvalidDigit },
        .{ "#+-4", error.InvalidDigit },
        .{ "-#-4", error.MalformedInteger },
        .{ "-#+4", error.MalformedInteger },
        .{ "+#+4", error.MalformedInteger },
        .{ "+#-4", error.MalformedInteger },
        .{ "--#4", error.MalformedInteger },
        .{ "-+#4", error.MalformedInteger },
        .{ "++#4", error.MalformedInteger },
        .{ "+-#4", error.MalformedInteger },
        .{ "1_", error.UnexpectedDelimiter },
        .{ "123_", error.UnexpectedDelimiter },
        .{ "0x_", error.UnexpectedDelimiter },
        .{ "x123_", error.UnexpectedDelimiter },
        .{ "0x_123", error.UnexpectedDelimiter },
        .{ "1__23", error.UnexpectedDelimiter },
        .{ "#_23", error.UnexpectedDelimiter },
        .{ "#_2__3_", error.UnexpectedDelimiter },
        // Decimal
        .{ "0", .{ .underlying = 0, .form = .{ .radix = null, .sign = null, .zero = false, .delimited = false } } },
        .{ "00", .{ .underlying = 0, .form = .{ .radix = null, .sign = null, .zero = true, .delimited = false } } },
        .{ "-0", .{ .underlying = 0, .form = .{ .radix = null, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "#0", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = null, .zero = false, .delimited = false } } },
        .{ "#00", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = null, .zero = false, .delimited = false } } },
        .{ "-#0", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+#0", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+#00", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "#-0", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "#+0", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = .{ .value = .positive, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "#-00", .{ .underlying = 0, .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "4", .{ .underlying = 4, .form = .{ .radix = null, .sign = null, .zero = false, .delimited = false } } },
        .{ "+4", .{ .underlying = 4, .form = .{ .radix = null, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "4284", .{ .underlying = 4284, .form = .{ .radix = null, .sign = null, .zero = false, .delimited = false } } },
        .{ "004_2_84", .{ .underlying = 4284, .form = .{ .radix = null, .sign = null, .zero = true, .delimited = true } } },
        .{ "#4", .{ .underlying = 4, .form = .{ .radix = .decimal, .sign = null, .zero = false, .delimited = false } } },
        .{ "#4284", .{ .underlying = 4284, .form = .{ .radix = .decimal, .sign = null, .zero = false, .delimited = false } } },
        .{ "#0_04284", .{ .underlying = 4284, .form = .{ .radix = .decimal, .sign = null, .zero = false, .delimited = true } } },
        .{ "-4", .{ .underlying = cast(-4), .form = .{ .radix = null, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-4284", .{ .underlying = cast(-4284), .form = .{ .radix = null, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-004284", .{ .underlying = cast(-4284), .form = .{ .radix = null, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "-#4", .{ .underlying = cast(-4), .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+#4", .{ .underlying = 4, .form = .{ .radix = .decimal, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-#4284", .{ .underlying = cast(-4284), .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-#004284", .{ .underlying = cast(-4284), .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "#-4", .{ .underlying = cast(-4), .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "#+4", .{ .underlying = 4, .form = .{ .radix = .decimal, .sign = .{ .value = .positive, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "#-4284", .{ .underlying = cast(-4284), .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "#-004284", .{ .underlying = cast(-4284), .form = .{ .radix = .decimal, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        // Hex
        .{ "x0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = null, .zero = false, .delimited = false } } },
        .{ "0x0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = null, .zero = true, .delimited = false } } },
        .{ "x00", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = null, .zero = false, .delimited = false } } },
        .{ "0x00", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = null, .zero = true, .delimited = false } } },
        .{ "-x0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-0x0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "+x0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+0x0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "+x00", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+0x00", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "x-0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "0x-0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = true, .delimited = false } } },
        .{ "x+0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "0x+0", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .post_radix }, .zero = true, .delimited = false } } },
        .{ "x-00", .{ .underlying = 0x0, .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "x4", .{ .underlying = 0x4, .form = .{ .radix = .hex, .sign = null, .zero = false, .delimited = false } } },
        .{ "x4ac", .{ .underlying = 0x4ac, .form = .{ .radix = .hex, .sign = null, .zero = false, .delimited = false } } },
        .{ "x004_ac", .{ .underlying = 0x4ac, .form = .{ .radix = .hex, .sign = null, .zero = false, .delimited = true } } },
        .{ "0x004ac", .{ .underlying = 0x4ac, .form = .{ .radix = .hex, .sign = null, .zero = true, .delimited = false } } },
        .{ "-x4", .{ .underlying = cast(-0x4), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+x4", .{ .underlying = 0x4, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-x4ac", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-0x4ac", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "-x0_04a_c", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = true } } },
        .{ "-0x004ac", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "x-4", .{ .underlying = cast(-0x4), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "x+4", .{ .underlying = 0x4, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "0x+4", .{ .underlying = 0x4, .form = .{ .radix = .hex, .sign = .{ .value = .positive, .position = .post_radix }, .zero = true, .delimited = false } } },
        .{ "x-4ac", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "x-004ac", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = false, .delimited = false } } },
        .{ "0x-004ac", .{ .underlying = cast(-0x4ac), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .post_radix }, .zero = true, .delimited = false } } },
        // Octal, binary
        .{ "o0", .{ .underlying = 0o0, .form = .{ .radix = .octal, .sign = null, .zero = false, .delimited = false } } },
        .{ "0o77", .{ .underlying = 0o77, .form = .{ .radix = .octal, .sign = null, .zero = true, .delimited = false } } },
        .{ "-o077", .{ .underlying = cast(-0o77), .form = .{ .radix = .octal, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+0o77", .{ .underlying = 0o77, .form = .{ .radix = .octal, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "b0", .{ .underlying = 0b0, .form = .{ .radix = .binary, .sign = null, .zero = false, .delimited = false } } },
        .{ "0b101", .{ .underlying = 0b101, .form = .{ .radix = .binary, .sign = null, .zero = true, .delimited = false } } },
        .{ "-b0101", .{ .underlying = cast(-0b101), .form = .{ .radix = .binary, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "+0b10_1", .{ .underlying = 0b101, .form = .{ .radix = .binary, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = true, .delimited = true } } },
        // Bounds checking
        .{ "0xffff", .{ .underlying = 0xffff, .form = .{ .radix = .hex, .sign = null, .zero = true, .delimited = false } } },
        .{ "+65535", .{ .underlying = 0xffff, .form = .{ .radix = null, .sign = .{ .value = .positive, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "0x10000", error.IntegerTooLarge },
        .{ "65536", error.IntegerTooLarge },
        .{ "-0x8000", .{ .underlying = cast(-0x8000), .form = .{ .radix = .hex, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = true, .delimited = false } } },
        .{ "-32768", .{ .underlying = cast(-0x8000), .form = .{ .radix = null, .sign = .{ .value = .negative, .position = .pre_radix }, .zero = false, .delimited = false } } },
        .{ "-0x8001", error.IntegerTooLarge },
        .{ "-32769", error.IntegerTooLarge },
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
