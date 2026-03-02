const Mask = @This();

const std = @import("std");
const Signedness = std.builtin.Signedness;
const assert = std.debug.assert;

signedness: Signedness,
lowest: u4,
highest: u4,
size: u16,

pub fn new(
    comptime signedness: Signedness,
    comptime lowest: u4,
    comptime highest: u4,
    comptime assert_size: u16,
) Mask {
    comptime {
        assert(lowest <= highest);
        const size = @as(u16, highest) - lowest + 1;
        assert(size == assert_size);
        return .{
            .signedness = signedness,
            .lowest = lowest,
            .highest = highest,
            .size = size,
        };
    }
}

pub fn apply(comptime mask: Mask, word: u16) @Int(mask.signedness, mask.size) {
    const unsigned: @Int(.unsigned, mask.size) = @truncate(word >> mask.lowest);
    return @bitCast(unsigned);
}

test apply {
    const expect = std.testing.expect;

    try expect(apply(.new(.unsigned, 0, 15, 16), 0b1010_1010_0101_0101) == 0b1010_1010_0101_0101);
    try expect(apply(.new(.unsigned, 0, 0, 1), 0b1010_1010_0101_0101) == 0b1);
    try expect(apply(.new(.unsigned, 0, 1, 2), 0b1010_1010_0101_0101) == 0b01);
    try expect(apply(.new(.unsigned, 0, 2, 3), 0b1010_1010_0101_0101) == 0b101);
    try expect(apply(.new(.unsigned, 0, 3, 4), 0b1010_1010_0101_0101) == 0b0101);
    try expect(apply(.new(.unsigned, 0, 4, 5), 0b1010_1010_0101_0101) == 0b10101);
    try expect(apply(.new(.unsigned, 15, 15, 1), 0b1010_1010_0101_0101) == 0b1);
    try expect(apply(.new(.unsigned, 13, 15, 3), 0b1010_1010_0101_0101) == 0b101);
    try expect(apply(.new(.unsigned, 12, 15, 4), 0b1010_1010_0101_0101) == 0b1010);
    try expect(apply(.new(.unsigned, 1, 4, 4), 0b1010_1010_0101_0101) == 0b1010);
    try expect(apply(.new(.unsigned, 2, 4, 3), 0b1010_1010_0101_0101) == 0b101);
    try expect(apply(.new(.unsigned, 11, 14, 4), 0b1010_1010_0101_0101) == 0b0101);
    try expect(apply(.new(.unsigned, 11, 13, 3), 0b1010_1010_0101_0101) == 0b101);

    try expect(apply(.new(.signed, 0, 15, 16), 0b1010_1010_0101_0101) == -0b101_0101_1010_1011);
    try expect(apply(.new(.signed, 0, 0, 1), 0b1010_1010_0101_0101) == -0b1);
    try expect(apply(.new(.signed, 0, 1, 2), 0b1010_1010_0101_0101) == 0b01);
    try expect(apply(.new(.signed, 0, 2, 3), 0b1010_1010_0101_0101) == -0b011);
    try expect(apply(.new(.signed, 0, 3, 4), 0b1010_1010_0101_0101) == 0b0101);
    try expect(apply(.new(.signed, 0, 4, 5), 0b1010_1010_0101_0101) == -0b01011);
    try expect(apply(.new(.signed, 15, 15, 1), 0b1010_1010_0101_0101) == -0b1);
    try expect(apply(.new(.signed, 13, 15, 3), 0b1010_1010_0101_0101) == -0b011);
    try expect(apply(.new(.signed, 12, 15, 4), 0b1010_1010_0101_0101) == -0b0110);
    try expect(apply(.new(.signed, 1, 4, 4), 0b1010_1010_0101_0101) == -0b0110);
    try expect(apply(.new(.signed, 2, 4, 3), 0b1010_1010_0101_0101) == -0b011);
    try expect(apply(.new(.signed, 11, 14, 4), 0b1010_1010_0101_0101) == 0b0101);
    try expect(apply(.new(.signed, 11, 13, 3), 0b1010_1010_0101_0101) == -0b011);
}
