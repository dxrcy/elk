const Ctx = @This();

const std = @import("std");
const Io = std.Io;

const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");
const reporting = @import("reporting.zig");
const Reporter = reporting.Reporter;
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

fn printDepth(ctx: Ctx) error{WriteFailed}!void {
    for (0..ctx.depth) |_|
        try ctx.writer.print(" " ** indent_width, .{});
}

pub fn printTitle(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
) error{WriteFailed}!void {
    defer ctx.incrementItemCount();

    const level = ctx.level orelse
        unreachable;
    try ctx.printDepth();
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

pub fn printNote(ctx: Ctx, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
    defer ctx.incrementItemCount();

    switch (ctx.verbosity) {
        .normal => {},
        .quiet => return,
    }

    try ctx.printDepth();
    try ctx.writer.print("\x1b[36m", .{});
    try ctx.writer.print("Note: ", .{});
    try ctx.writer.print("\x1b[0m", .{});
    try ctx.writer.print(fmt, args);
    try ctx.writer.print("\n", .{});
}

pub fn printSourceNote(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
    span: Span,
) error{WriteFailed}!void {
    try ctx.printNote(fmt ++ ": ", args);
    try ctx.printSource(span);
}

fn printSource(ctx: Ctx, span: Span) error{WriteFailed}!void {
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

    try reporting.writeSpanContext(ctx.writer, span, .{
        .indent = ctx.depth * indent_width,
        .max_line_width = 90,
    }, source);
}
