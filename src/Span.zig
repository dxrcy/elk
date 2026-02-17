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

pub fn getWholeLine(span: Span, source: []const u8) Span {
    assert(span.end() <= source.len);
    { // Newlines may only be present for newline token "\n"
        const newlines = std.mem.countScalar(u8, span.view(source), '\n');
        switch (newlines) {
            0 => {},
            1 => assert(span.len == 1),
            else => unreachable,
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

    const cases = [_]struct { Span, usize, bool }{
        .{ .{ .offset = 0, .len = 0 }, 0, false },
        .{ .{ .offset = 1, .len = 0 }, 0, false },
        .{ .{ .offset = 4, .len = 0 }, 0, false },
        .{ .{ .offset = 5, .len = 0 }, 0, false },
        .{ .{ .offset = 0, .len = 1 }, 0, false },
        .{ .{ .offset = 1, .len = 1 }, 0, false },
        .{ .{ .offset = 4, .len = 1 }, 0, false },
        .{ .{ .offset = 0, .len = 5 }, 0, false },
        .{ .{ .offset = 5, .len = 1 }, 0, true },
        .{ .{ .offset = 6, .len = 0 }, 1, false },
        .{ .{ .offset = 8, .len = 0 }, 1, false },
        .{ .{ .offset = 9, .len = 0 }, 1, false },
        .{ .{ .offset = 6, .len = 1 }, 1, false },
        .{ .{ .offset = 8, .len = 1 }, 1, false },
        .{ .{ .offset = 6, .len = 3 }, 1, false },
        .{ .{ .offset = 9, .len = 1 }, 1, true },
        .{ .{ .offset = 10, .len = 0 }, 2, false },
        .{ .{ .offset = 10, .len = 1 }, 2, true },
        .{ .{ .offset = 11, .len = 0 }, 3, false },
        .{ .{ .offset = 12, .len = 0 }, 3, false },
        .{ .{ .offset = 14, .len = 0 }, 3, false },
        .{ .{ .offset = 11, .len = 1 }, 3, false },
        .{ .{ .offset = 12, .len = 1 }, 3, false },
        .{ .{ .offset = 11, .len = 4 }, 3, false },
        .{ .{ .offset = 15, .len = 0 }, 3, false }, // emptyAt(source.len)
    };

    for (cases) |case| {
        const input, const expected_index, const is_newline = case;
        const input_string = input.view(source);
        const expected_string = lines[expected_index];
        log.info("INPUT:   \t\"{s}\"", .{input_string});
        log.info("INPUT:   \t{}", .{input});
        try expect(std.mem.eql(u8, input_string, "\n") == is_newline);
        log.info("EXPECTED:\t\"{s}\"", .{expected_string});
        const actual = input.getWholeLine(source);
        const actual_string = actual.view(source);
        log.info("ACTUAL:  \t\"{s}\"", .{actual_string});
        log.info("ACTUAL:  \t{}", .{actual});
        try expect(actual.end() <= source.len); // <= is intended
        try expect(std.mem.eql(u8, actual_string, expected_string));
    }
}
