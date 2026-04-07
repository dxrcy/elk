const Reporter = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Policies = @import("../policies.zig").Policies;
const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Ctx = @import("Ctx.zig");

pub const Stderr = @import("Stderr.zig");
pub const Discarding = @import("Discarding.zig");

const BUFFER_SIZE = 1024;

options: Options,
count: std.EnumArray(Level, usize),
source: ?[]const u8,

ptr: *anyopaque,
vtable: *const VTable,

const VTable = struct {
    showReport: *const fn (
        ptr: *anyopaque,
        diag: Diagnostic,
        level: Reporter.Level,
        source: ?[]const u8,
    ) void,

    showSummary: *const fn (
        ptr: *anyopaque,
        count: *const std.EnumArray(Reporter.Level, usize),
    ) void,
};

pub const Level = enum { err, warn, info };

pub const Options = struct {
    strictness: Strictness = .default,
    policies: Policies = .none,

    pub const Strictness = enum {
        strict,
        normal,
        relaxed,
        pub const default: Strictness = .normal;
    };
};

pub const Response = enum {
    /// Must be handled immediately.
    fatal,
    /// Must be handled in this pass.
    major,

    minor,
    info,
    pass,

    pub fn abort(response: Response) error{Reported}!noreturn {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .info, .pass => unreachable,
        };
    }
    pub fn collect(response: Response, result: *error{Reported}!void) void {
        return switch (response) {
            .fatal, .major => {
                result.* = error.Reported;
            },
            .minor, .info, .pass => {},
        };
    }
    pub fn handle(response: Response) error{Reported}!void {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .info, .pass => {},
        };
    }
    /// Callsites should document why `proceed` is used rather than `handle`.
    pub fn proceed(response: Response) void {
        switch (response) {
            .fatal => unreachable,
            .major, .minor, .info, .pass => {},
        }
    }
};

pub fn fromImplementation(ptr: *anyopaque, vtable: *const VTable) Reporter {
    return .{
        .options = .{},
        .count = .initFill(0),
        .source = null,
        .ptr = ptr,
        .vtable = vtable,
    };
}

pub fn copyImplementation(reporter: *const Reporter) Reporter {
    return .{
        .options = .{},
        .count = .initFill(0),
        .source = null,
        .ptr = reporter.ptr,
        .vtable = reporter.vtable,
    };
}

pub fn report(
    reporter: *Reporter,
    comptime tag: std.meta.Tag(Diagnostic),
    info: @FieldType(Diagnostic, @tagName(tag)),
) Response {
    return reporter.reportInner(@unionInit(Diagnostic, @tagName(tag), info));
}

fn reportInner(reporter: *Reporter, diag: Diagnostic) Response {
    const response: Response = diag.getResponse(reporter.options);

    const level: Level = switch (response) {
        .fatal, .major => .err,
        .minor => .warn,
        .info => .info,
        .pass => return .pass,
    };

    reporter.count.getPtr(level).* += 1;

    reporter.vtable.showReport(reporter.ptr, diag, level, reporter.source);

    assert(response != .pass);
    return response;
}

pub fn showSummary(reporter: *Reporter) void {
    reporter.vtable.showSummary(reporter.ptr, &reporter.count);
}

pub fn getLevel(reporter: *const Reporter) ?Level {
    if (reporter.count.get(.err) > 0)
        return .err;
    if (reporter.count.get(.warn) > 0)
        return .warn;
    return null;
}

pub fn writeSpanContext(
    writer: *std.Io.Writer,
    span: Span,
    max_context: usize,
    indent: usize,
    source: []const u8,
) error{WriteFailed}!void {
    const lines = span.getSurroundingLines(max_context, source);
    var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
    while (iter.next()) |line_string| {
        const line = Span.fromSlice(line_string, source);
        const line_number = line.getLineNumber(source);

        for (0..indent) |_|
            try writer.print(" ", .{});

        try writer.print("\x1b[2m", .{});
        try writer.print("{:3} ", .{line_number});
        try writer.print("| ", .{});
        try writer.print("\x1b[0m", .{});
        try writer.print("\x1b[3m", .{});
        try writer.print("\x1b[2m", .{});

        {
            var was_in_span = false;
            var was_non_valid = false;

            for (line_string, 0..) |char, i| {
                const index = line.offset + i;

                const in_span = span.containsIndex(index);
                if (in_span and !was_in_span)
                    try writer.print("\x1b[22m", .{})
                else if (!in_span and was_in_span)
                    try writer.print("\x1b[2m", .{});

                const non_valid = Token.isValidChar(char);
                if (!non_valid and was_non_valid)
                    try writer.print("\x1b[31m", .{})
                else if (non_valid and !was_non_valid)
                    try writer.print("\x1b[39m", .{});

                if (non_valid)
                    try writer.print("{c}", .{char})
                else
                    try writer.print("?", .{});

                was_in_span = in_span;
                was_non_valid = non_valid;
            }
        }

        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});

        if (!line.overlaps(span) or
            std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0)
        {
            continue;
        }

        for (0..indent) |_|
            try writer.print(" ", .{});

        try writer.print("\x1b[2m", .{});
        try writer.print("    | ", .{});
        try writer.print("\x1b[22m", .{});
        try writer.print("\x1b[36m", .{});
        for (0..line_string.len + 1) |i| {
            const index = line.offset + i;
            if (span.containsIndex(index) or
                // Still highlight first character if len==0
                span.offset == index)
                try writer.print("^", .{})
            else
                try writer.print(" ", .{});
        }
        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});
    }
}
