const Span = @This();

offset: usize,
len: usize,

pub fn fromBounds(start: usize, end: usize) Span {
    return .{ .offset = start, .len = end - start };
}

pub fn resolve(span: Span, source: []const u8) []const u8 {
    return source[span.offset..][0..span.len];
}
