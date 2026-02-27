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

pub fn fromSlice(slice: []const u8, source: []const u8) Span {
    return .{ .offset = slice.ptr - source.ptr, .len = slice.len };
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

pub fn view(span: Span, source: []const u8) []const u8 {
    return source[span.offset..][0..span.len];
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

pub fn getSurroundingLines(span: Span, source: []const u8) Span {
    const containing = span.getContainingLines(source);
    const widened: Span = .fromBounds(
        containing.offset -| 1,
        @min(containing.end() + "\n".len + 1, source.len),
    );
    return widened.getContainingLines(source);
}

pub fn getContainingLines(span: Span, source: []const u8) Span {
    assert(span.end() <= source.len);

    var start = span.offset;
    var end_ = span.offset;

    if (span.len > 0) {
        if (start >= source.len or
            (source[start] == '\n' and source[start - 1] != '\n'))
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
        if (!std.mem.eql(u8, input_string, input.view(source))) {
            log.info("(INPUT): \t\"{s}\"", .{input.view(source)});
            unreachable;
        }
        const actual = input.getContainingLines(source);
        const actual_string = actual.view(source);
        log.info("ACTUAL:  \t\"{s}\"", .{actual_string});
        log.info("ACTUAL:  \t{}", .{actual});
        try expect(actual.end() <= source.len); // <= is intended
        try expect(std.mem.eql(u8, actual_string, expected_string));
    }
}
