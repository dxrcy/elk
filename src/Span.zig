const Span = @This();

const std = @import("std");
const assert = std.debug.assert;

offset: usize,
len: usize,

pub const dummy: Span = .{ .offset = 0, .len = 0 };

pub fn fromBounds(start: usize, end_: usize) Span {
    return .{ .offset = start, .len = end_ - start };
}

pub fn emptyAt(offset: usize) Span {
    return .{ .offset = offset, .len = 0 };
}

pub fn end(span: Span) usize {
    return span.offset + span.len;
}

pub fn in(inner: Span, containing: Span) Span {
    assert(inner.end() < containing.end());
    return .{
        .offset = containing.offset + inner.offset,
        .len = inner.len,
    };
}

pub fn resolve(span: Span, source: []const u8) []const u8 {
    return source[span.offset..][0..span.len];
}
