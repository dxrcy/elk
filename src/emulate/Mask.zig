const Mask = @This();

const std = @import("std");
const assert = std.debug.assert;

lowest: u4,
highest: u4,
// TODO: Add `signedness` field

// TODO: Add `size` field which is checked against bounds
pub fn new(lowest: u4, highest: u4) Mask {
    return .{ .lowest = lowest, .highest = highest };
}

pub fn apply(comptime mask: Mask, word: u16) @Int(
    .unsigned,
    @as(u16, mask.highest) - mask.lowest + 1,
) {
    assert(mask.lowest <= mask.highest);
    return @truncate(word >> mask.lowest);
}

pub fn applySigned(comptime mask: Mask, word: u16) @Int(
    .signed,
    @as(u16, mask.highest) - mask.lowest + 1,
) {
    return @bitCast(mask.apply(word));
}

pub fn applySext(comptime mask: Mask, word: u16) u16 {
    return signExtend(apply(mask, word));
}

pub // TODO: Need this to be public ?
fn signExtend(value: anytype) u16 {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    const Signed = @Int(.signed, bits);
    return @bitCast(@as(i16, @as(Signed, @bitCast(value))));
}

test signExtend {
    const expect = std.testing.expect;

    try expect(signExtend(@as(u1, 0b1)) == 0b1111_1111_1111_1111);
    try expect(signExtend(@as(u2, 0b01)) == 0b0000_0000_0000_0001);
    try expect(signExtend(@as(u3, 0b101)) == 0b1111_1111_1111_1101);
    try expect(signExtend(@as(u4, 0b0101)) == 0b0000_0000_0000_0101);
}

test apply {
    const expect = std.testing.expect;

    try expect(apply(.new(0, 15), 0b1010_1010_0101_0101) == 0b1010_1010_0101_0101);

    try expect(apply(.new(0, 0), 0b1010_1010_0101_0101) == 0b1);
    try expect(apply(.new(0, 1), 0b1010_1010_0101_0101) == 0b01);
    try expect(apply(.new(0, 2), 0b1010_1010_0101_0101) == 0b101);
    try expect(apply(.new(0, 3), 0b1010_1010_0101_0101) == 0b0101);
    try expect(apply(.new(0, 4), 0b1010_1010_0101_0101) == 0b10101);

    try expect(apply(.new(15, 15), 0b1010_1010_0101_0101) == 0b1);
    try expect(apply(.new(13, 15), 0b1010_1010_0101_0101) == 0b101);
    try expect(apply(.new(12, 15), 0b1010_1010_0101_0101) == 0b1010);

    try expect(apply(.new(1, 4), 0b1010_1010_0101_0101) == 0b1010);
    try expect(apply(.new(2, 4), 0b1010_1010_0101_0101) == 0b101);
    try expect(apply(.new(11, 14), 0b1010_1010_0101_0101) == 0b0101);
    try expect(apply(.new(11, 13), 0b1010_1010_0101_0101) == 0b101);
}

test applySext {
    const expect = std.testing.expect;

    try expect(applySext(.new(0, 15), 0b1010_1010_0101_0101) == 0b1010_1010_0101_0101);

    try expect(applySext(.new(0, 0), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1111);
    try expect(applySext(.new(0, 1), 0b1010_1010_0101_0101) == 0b0000_0000_0000_0001);
    try expect(applySext(.new(0, 2), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
    try expect(applySext(.new(0, 3), 0b1010_1010_0101_0101) == 0b0000_0000_0000_0101);
    try expect(applySext(.new(0, 4), 0b1010_1010_0101_0101) == 0b1111_1111_1111_0101);

    try expect(applySext(.new(15, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1111);
    try expect(applySext(.new(14, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1110);
    try expect(applySext(.new(13, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
    try expect(applySext(.new(12, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1010);

    try expect(applySext(.new(1, 4), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1010);
    try expect(applySext(.new(2, 4), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
    try expect(applySext(.new(11, 14), 0b1010_1010_0101_0101) == 0b0000_0000_0000_0101);
    try expect(applySext(.new(11, 13), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
}
