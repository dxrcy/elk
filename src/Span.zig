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

pub fn view(span: Span, source: []const u8) []const u8 {
    return source[span.offset..][0..span.len];
}

// TODO: Remove and replace with `getContainingLines`
pub fn getWholeLine(span: Span, source: []const u8) ?Span {
    assert(span.end() <= source.len);
    { // Newlines may only be present for newline token "\n"
        const newlines = std.mem.countScalar(u8, span.view(source), '\n');
        switch (newlines) {
            0 => {},
            1 => if (span.len > 1) return null,
            else => return null,
        }
    }

    var start = span.offset;
    while (start > 0) : (start -= 1) {
        if (source[start - 1] == '\n')
            break;
    }

    var end_ = span.offset;
    while (end_ < source.len) : (end_ += 1) {
        if (source[end_] == '\n')
            break;
    }

    return .fromBounds(start, end_);
}

test getWholeLine {
    const expect = std.testing.expect;
    const log = std.log.scoped(.getWholeLine);

    const lines = [_][]const u8{
        "abcde",
        "fgh",
        "",
        "ijkl",
    };

    const source = lines[0] ++ "\n" ++ lines[1] ++ "\n" ++ lines[2] ++ "\n" ++ lines[3];
    comptime assert(source.len == 15);

    const cases = [_]struct { Span, ?[]const u8 }{
        // Single-line spans
        .{ .{ .offset = 0, .len = 0 }, lines[0] },
        .{ .{ .offset = 1, .len = 0 }, lines[0] },
        .{ .{ .offset = 4, .len = 0 }, lines[0] },
        .{ .{ .offset = 5, .len = 0 }, lines[0] },
        .{ .{ .offset = 5, .len = 1 }, lines[0] },
        .{ .{ .offset = 0, .len = 1 }, lines[0] },
        .{ .{ .offset = 1, .len = 1 }, lines[0] },
        .{ .{ .offset = 4, .len = 1 }, lines[0] },
        .{ .{ .offset = 0, .len = 5 }, lines[0] },
        .{ .{ .offset = 6, .len = 0 }, lines[1] },
        .{ .{ .offset = 8, .len = 0 }, lines[1] },
        .{ .{ .offset = 9, .len = 0 }, lines[1] },
        .{ .{ .offset = 9, .len = 1 }, lines[1] },
        .{ .{ .offset = 6, .len = 1 }, lines[1] },
        .{ .{ .offset = 8, .len = 1 }, lines[1] },
        .{ .{ .offset = 6, .len = 3 }, lines[1] },
        .{ .{ .offset = 10, .len = 0 }, lines[2] },
        .{ .{ .offset = 10, .len = 1 }, lines[2] },
        .{ .{ .offset = 11, .len = 0 }, lines[3] },
        .{ .{ .offset = 12, .len = 0 }, lines[3] },
        .{ .{ .offset = 14, .len = 0 }, lines[3] },
        .{ .{ .offset = 11, .len = 1 }, lines[3] },
        .{ .{ .offset = 12, .len = 1 }, lines[3] },
        .{ .{ .offset = 11, .len = 4 }, lines[3] },
        .{ .{ .offset = 15, .len = 0 }, lines[3] }, // emptyAt(source.len)
        // Newline spans ("\n")
        .{ .{ .offset = 5, .len = 1 }, lines[0] },
        .{ .{ .offset = 9, .len = 1 }, lines[1] },
        .{ .{ .offset = 10, .len = 1 }, lines[2] },
        // Multiline spans
        .{ .{ .offset = 0, .len = 6 }, null },
        .{ .{ .offset = 4, .len = 2 }, null },
        .{ .{ .offset = 5, .len = 2 }, null },
        .{ .{ .offset = 6, .len = 4 }, null },
        .{ .{ .offset = 7, .len = 3 }, null },
        .{ .{ .offset = 7, .len = 4 }, null },
        .{ .{ .offset = 8, .len = 2 }, null },
        .{ .{ .offset = 9, .len = 2 }, null },
        .{ .{ .offset = 10, .len = 2 }, null },
        .{ .{ .offset = 0, .len = 15 }, null },
    };

    for (cases) |case| {
        const input, const expected_opt = case;
        const input_string = input.view(source);
        log.info("INPUT:   \t\"{s}\"", .{input_string});
        log.info("INPUT:   \t{}", .{input});
        log.info("EXPECTED:\t\"{?s}\"", .{expected_opt});
        const actual_opt = input.getWholeLine(source);
        log.info("ACTUAL:  \t\"{?s}\"", .{if (actual_opt) |actual| actual.view(source) else null});
        log.info("ACTUAL:  \t{?}", .{actual_opt});
        if (expected_opt) |expected_string| {
            const actual = actual_opt orelse return error.TestUnexpectedResult;
            const actual_string = actual.view(source);
            try expect(actual.end() <= source.len); // <= is intended
            try expect(std.mem.eql(u8, actual_string, expected_string));
        } else {
            try expect(actual_opt == null);
        }
    }
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
