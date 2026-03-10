const Live = @This();

const std = @import("std");
const assert = std.debug.assert;

buffer: []u8,
length: usize,

pub fn getString(live: *const Live) []const u8 {
    return live.buffer[0..live.length];
}

pub fn copyFrom(live: *Live, string: []const u8) void {
    const length = @min(string.len, live.buffer.len);
    @memcpy(live.buffer[0..length], string[0..length]);
    live.length = length;
}

pub fn clear(live: *Live) void {
    live.length = 0;
}

pub fn insert(live: *Live, index: usize, char: u8) void {
    assert(live.length < live.buffer.len);
    assert(index <= live.length);

    // Shift characters up
    if (index < live.length) {
        var i = live.length;
        while (i > index) : (i -= 1)
            live.buffer[i] = live.buffer[i - 1];
    }

    live.buffer[index] = char;
    live.length += 1;
}

pub fn remove(live: *Live, index: usize) void {
    assert(live.length > 0);
    assert(index <= live.length);

    // Shift characters down
    if (index < live.length) {
        for (index..live.length) |i|
            live.buffer[i - 1] = live.buffer[i];
    }

    live.length -= 1;
}
