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

// TODO: Support multiline tokens (extension multiline strings),
// Return span of all lines containing token, and caller can use an iterator to
// split lines,
// Or return iterator of all line spans containing token.
pub fn getWholeLine(span: Span, source: []const u8) ?Span {
    assert(span.end() <= source.len);
    { // Newlines may only be present for newline token "\n"
        const newlines = std.mem.countScalar(u8, span.view(source), '\n');
        switch (newlines) {
            0 => {},
            // TODO: Handle these cases better (see function comment)
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
