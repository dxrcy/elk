const Ctx = @This();

const std = @import("std");
const Io = std.Io;

const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");
const reporting = @import("reporting.zig");
const Verbosity = reporting.Options.Verbosity;
const Level = reporting.Level;

writer: *Io.Writer,
verbosity: Verbosity,
level: ?Level,
depth: usize,
item_count: ?*usize,
source: ?[]const u8,

const indent_width = 4;

pub fn new(
    writer: *Io.Writer,
    verbosity: Verbosity,
    level: ?Level,
    item_count: ?*usize,
    source: ?[]const u8,
) Ctx {
    return .{
        .writer = writer,
        .verbosity = verbosity,
        .level = level,
        .depth = 0,
        .item_count = item_count,
        .source = source,
    };
}

pub fn deepen(ctx: Ctx) Ctx {
    var new_ctx = ctx;
    new_ctx.depth += 1;
    return new_ctx;
}

pub fn withSource(ctx: Ctx, source: []const u8) Ctx {
    var new_ctx = ctx;
    new_ctx.source = source;
    return new_ctx;
}

fn incrementItemCount(ctx: *const Ctx) void {
    if (ctx.item_count) |count|
        count.* += 1;
}

fn writeDepth(ctx: Ctx) error{WriteFailed}!void {
    for (0..ctx.depth) |_|
        try ctx.writer.print(" " ** indent_width, .{});
}

pub fn writeTitle(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
) error{WriteFailed}!void {
    defer ctx.incrementItemCount();

    const level = ctx.level orelse
        unreachable;
    try ctx.writeDepth();
    switch (level) {
        .err => {
            try ctx.writer.print("\x1b[31m", .{});
            try ctx.writer.print("\x1b[1m", .{});
            try ctx.writer.print("Error: ", .{});
            try ctx.writer.print("\x1b[0m", .{});
        },
        .warn => {
            try ctx.writer.print("\x1b[33m", .{});
            try ctx.writer.print("\x1b[1m", .{});
            try ctx.writer.print("Warning: ", .{});
            try ctx.writer.print("\x1b[0m", .{});
        },
        .info => {
            try ctx.writer.print("\x1b[34m", .{});
            try ctx.writer.print("\x1b[1m", .{});
            try ctx.writer.print("Info: ", .{});
            try ctx.writer.print("\x1b[0m", .{});
        },
    }

    try ctx.writer.print(fmt, args);

    switch (ctx.verbosity) {
        .normal => {
            try ctx.writer.print("\n", .{});
        },
        .quiet => {},
    }
}

pub fn writeNote(ctx: Ctx, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
    defer ctx.incrementItemCount();

    switch (ctx.verbosity) {
        .normal => {},
        .quiet => return,
    }

    try ctx.writeDepth();
    try ctx.writer.print("\x1b[36m", .{});
    try ctx.writer.print("Note: ", .{});
    try ctx.writer.print("\x1b[0m", .{});
    try ctx.writer.print(fmt, args);
    try ctx.writer.print("\n", .{});
}

pub fn writeSourceNote(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
    span: Span,
) error{WriteFailed}!void {
    try ctx.writeNote(fmt ++ ": ", args);
    try ctx.writeSource(span);
}

fn writeSource(ctx: Ctx, span: Span) error{WriteFailed}!void {
    const source = ctx.source orelse
        unreachable;

    switch (ctx.verbosity) {
        .normal => {},
        .quiet => {
            // Scuffed!
            if (if (ctx.item_count) |count| count.* > 2 else true)
                return;

            const start_line = span.getLineNumber(source);
            const end_line = span.getEndLineNumber(source);
            const start_column = span.getColumnNumber(source);
            const end_column = span.getEndColumnNumber(source);

            try ctx.writer.print(" (Line {}:{}-{}:{})", .{
                start_line, start_column, end_line, end_column,
            });
            try ctx.writer.print("\n", .{});
            return;
        },
    }

    try writeSpanContext(ctx.writer, span, .{
        .indent = ctx.depth * indent_width,
        .max_line_width = 90,
    }, source);
}

pub fn writeSpanContext(
    writer: *std.Io.Writer,
    span: Span,
    config: struct {
        indent: usize = 0,
        max_context: usize = 1,
        max_line_width: usize = 80,
    },
    source: []const u8,
) error{WriteFailed}!void {
    const lines = span.getSurroundingLines(config.max_context, source);
    var iter = std.mem.splitScalar(u8, lines.view(source), '\n');
    while (iter.next()) |line_string_full| {
        const line_string = line_string_full[0..@min(line_string_full.len, config.max_line_width)];
        const is_truncated = line_string_full.len > config.max_line_width;

        const line = Span.fromSlice(line_string, source);
        const line_number = line.getLineNumber(source);

        for (0..config.indent) |_|
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

        if (is_truncated) {
            try writer.print("\x1b[0m", .{});
            try writer.print("\x1b[36;2m", .{});
            try writer.print("...", .{});
        }

        try writer.print("\x1b[0m", .{});
        try writer.print("\n", .{});

        if (!line.overlaps(span) or
            std.mem.trim(u8, line_string, &std.ascii.whitespace).len == 0)
        {
            continue;
        }

        for (0..config.indent) |_|
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
