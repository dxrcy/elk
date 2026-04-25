const Span = @This();

const std = @import("std");
const assert = std.debug.assert;

const Source = @import("Source.zig");

offset: usize,
len: usize,

pub fn fromBounds(start: usize, end_: usize) Span {
    return .{ .offset = start, .len = end_ - start };
}

pub fn endOf(source: Source) Span {
    return .{ .offset = source.text.len, .len = 0 };
}

pub fn fromSlice(slice: []const u8, source: []const u8) Span {
    return .{ .offset = slice.ptr - source.ptr, .len = slice.len };
}

pub fn join(lhs: Span, rhs: Span) Span {
    assert(!lhs.overlaps(rhs));
    assert(lhs.offset <= rhs.offset);
    return .fromBounds(lhs.offset, rhs.end());
}

pub fn firstCharOf(source: []const u8) Span {
    var offset: usize = 0;
    while (offset < source.len) : (offset += 1) {
        if (!std.ascii.isWhitespace(source[offset]))
            break;
    }
    return .{ .offset = offset, .len = 0 };
}

pub fn lastCharOf(source: []const u8) Span {
    var offset: usize = source.len -| 1;
    while (offset > 0) : (offset -= 1) {
        if (!std.ascii.isWhitespace(source[offset]))
            break;
    }
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

pub fn viewString(span: Span, source: []const u8) []const u8 {
    return source[span.offset..][0..span.len];
}

pub fn view(span: Span, source: Source) []const u8 {
    return span.viewString(source.text);
}

pub fn overlaps(lhs: Span, rhs: Span) bool {
    return (lhs.offset >= rhs.end() and
        lhs.end() <= rhs.offset) or
        (lhs.offset <= rhs.end() and
            lhs.end() >= rhs.offset);
}

pub fn containsIndex(span: Span, index: usize) bool {
    return index >= span.offset and index < span.end();
}

pub fn getLineNumber(span: Span, source: []const u8) usize {
    var count: usize = 1;
    for (source[0..span.offset]) |char| {
        if (char == '\n')
            count += 1;
    }
    return count;
}

pub fn getEndLineNumber(span: Span, source: []const u8) usize {
    var count: usize = 1;
    for (source[0..(span.offset + span.len)]) |char| {
        if (char == '\n')
            count += 1;
    }
    return count;
}

pub fn getColumnNumber(span: Span, source: []const u8) usize {
    var column: usize = 1;
    var i: usize = span.offset;

    while (i > 0) {
        i -= 1;
        if (source[i] == '\n') break;
        column += 1;
    }

    return column;
}

pub fn getEndColumnNumber(span: Span, source: []const u8) usize {
    var column: usize = 1;
    var i: usize = span.offset + span.len;

    while (i > 0) {
        i -= 1;
        if (source[i] == '\n') break;
        column += 1;
    }

    return column;
}

pub fn getSurroundingLines(span: Span, max_context: usize, source: []const u8) Span {
    const containing = span.getContainingLines(source);

    var start = containing.offset;
    var end_ = containing.end();

    // Widen span on each side, by searching for next newline in respective direction
    for (0..max_context) |_| {
        const before = source[0..start -| 1];
        start = if (std.mem.findLastLinear(u8, before, "\n")) |index| index + 1 else 0;
        end_ = std.mem.findPosLinear(u8, source, end_ + 1, "\n") orelse source.len;
    }

    // Don't treat trailing newline in file as an extra empty line
    if (end_ == source.len and source.len > 0 and source[source.len - 1] == '\n')
        end_ -= 1;

    return .fromBounds(start, end_);
}

pub fn getContainingLines(span: Span, source: []const u8) Span {
    assert(span.end() <= source.len);

    var start = span.offset;
    var end_ = span.offset;

    if (span.len > 0) {
        if (start >= source.len or
            (source[start] == '\n' and (start > 0 and source[start - 1] != '\n')))
        {
            start -= 1;
        }

        end_ = span.end() - 1;
        if (start < span.offset and source[end_] == '\n') {
            end_ -= 1;
        }
    }

    assert(start <= end_);
    assert(end_ <= source.len);

    while (start > 0) : (start -= 1) {
        if (source[start - 1] == '\n')
            break;
    }
    while (end_ < source.len) : (end_ += 1) {
        if (source[end_] == '\n')
            break;
    }

    return .fromBounds(start, end_);
}

test getContainingLines {
    const expect = std.testing.expect;
    const log = std.log.scoped(.getContainingLines);

    const source = "abcde\nfgh\n\nijkl";
    //..............012345 6789 0 1234
    comptime assert(source.len == 15);

    const cases = [_]struct { Span, []const u8, []const u8 }{
        .{ .{ .offset = 0, .len = 0 }, "", "abcde" },
        .{ .{ .offset = 0, .len = 5 }, "abcde", "abcde" },
        .{ .{ .offset = 3, .len = 0 }, "", "abcde" },
        .{ .{ .offset = 3, .len = 1 }, "d", "abcde" },
        .{ .{ .offset = 3, .len = 2 }, "de", "abcde" },
        .{ .{ .offset = 5, .len = 0 }, "", "abcde" },
        .{ .{ .offset = 6, .len = 3 }, "fgh", "fgh" },
        .{ .{ .offset = 7, .len = 0 }, "", "fgh" },
        .{ .{ .offset = 7, .len = 1 }, "g", "fgh" },
        .{ .{ .offset = 9, .len = 0 }, "", "fgh" },
        .{ .{ .offset = 10, .len = 0 }, "", "" },
        .{ .{ .offset = 10, .len = 1 }, "\n", "" },
        .{ .{ .offset = 11, .len = 0 }, "", "ijkl" },
        .{ .{ .offset = 11, .len = 1 }, "i", "ijkl" },
        .{ .{ .offset = 11, .len = 4 }, "ijkl", "ijkl" },
        .{ .{ .offset = 13, .len = 0 }, "", "ijkl" },
        .{ .{ .offset = 13, .len = 1 }, "k", "ijkl" },
        .{ .{ .offset = 13, .len = 2 }, "kl", "ijkl" },
        .{ .{ .offset = 15, .len = 0 }, "", "ijkl" },
        .{ .{ .offset = 0, .len = 9 }, "abcde\nfgh", "abcde\nfgh" },
        .{ .{ .offset = 6, .len = 9 }, "fgh\n\nijkl", "fgh\n\nijkl" },
        .{ .{ .offset = 2, .len = 3 }, "cde", "abcde" },
        .{ .{ .offset = 2, .len = 4 }, "cde\n", "abcde" },
        .{ .{ .offset = 2, .len = 5 }, "cde\nf", "abcde\nfgh" },
        .{ .{ .offset = 2, .len = 6 }, "cde\nfg", "abcde\nfgh" },
        .{ .{ .offset = 2, .len = 7 }, "cde\nfgh", "abcde\nfgh" },
        .{ .{ .offset = 2, .len = 8 }, "cde\nfgh\n", "abcde\nfgh" },
        .{ .{ .offset = 2, .len = 9 }, "cde\nfgh\n\n", "abcde\nfgh\n" },
        .{ .{ .offset = 2, .len = 10 }, "cde\nfgh\n\ni", source },
        .{ .{ .offset = 2, .len = 11 }, "cde\nfgh\n\nij", source },
        .{ .{ .offset = 0, .len = 15 }, source, source },
    };

    for (cases) |case| {
        const input, const input_string, const expected_string = case;
        log.info("-" ** 50, .{});
        log.info("INPUT:   \t\"{s}\"", .{input_string});
        log.info("INPUT:   \t{}", .{input});
        log.info("EXPECTED:\t\"{s}\"", .{expected_string});
        if (!std.mem.eql(u8, input_string, input.viewString(source))) {
            log.info("(INPUT): \t\"{s}\"", .{input.viewString(source)});
            unreachable;
        }
        const actual = input.getContainingLines(source);
        const actual_string = actual.viewString(source);
        log.info("ACTUAL:  \t\"{s}\"", .{actual_string});
        log.info("ACTUAL:  \t{}", .{actual});
        try expect(actual.end() <= source.len); // <= is intended
        try expect(std.mem.eql(u8, actual_string, expected_string));
    }
}
