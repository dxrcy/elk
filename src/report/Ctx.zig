const Ctx = @This();

const std = @import("std");

const Span = @import("../compile/Span.zig");
const Token = @import("../compile/parse/Token.zig");
const Reporter = @import("Reporter.zig");
const Stderr = @import("Stderr.zig");

reporter: *Stderr,
level: ?Reporter.Level,
depth: usize,
item_count: ?*usize,
source: ?[]const u8,

pub const Verbosity = enum {
    normal,
    quiet,
    pub const default: Verbosity = .normal;
};

const indent_width = 4;

pub fn new(
    reporter: *Stderr,
    level: ?Reporter.Level,
    item_count: ?*usize,
    source: ?[]const u8,
) Ctx {
    return .{
        .reporter = reporter,
        .level = level,
        .depth = 0,
        .item_count = item_count,
        .source = source,
    };
}

pub fn print(ctx: Ctx, comptime fmt: []const u8, args: anytype) void {
    ctx.reporter.writer.print(fmt, args) catch
        std.debug.panic("failed to write to reporter file", .{});
}

pub fn flush(ctx: Ctx) void {
    ctx.reporter.writer.flush() catch
        std.debug.panic("failed to flush reporter file", .{});
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

fn printDepth(ctx: Ctx) void {
    for (0..ctx.depth) |_|
        ctx.print(" " ** indent_width, .{});
}

pub fn printTitle(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
) void {
    defer ctx.incrementItemCount();

    const level = ctx.level orelse
        unreachable;
    ctx.printDepth();
    switch (level) {
        .err => {
            ctx.print("\x1b[31m", .{});
            ctx.print("\x1b[1m", .{});
            ctx.print("Error: ", .{});
            ctx.print("\x1b[0m", .{});
        },
        .warn => {
            ctx.print("\x1b[33m", .{});
            ctx.print("\x1b[1m", .{});
            ctx.print("Warning: ", .{});
            ctx.print("\x1b[0m", .{});
        },
        .info => {
            ctx.print("\x1b[34m", .{});
            ctx.print("\x1b[1m", .{});
            ctx.print("Info: ", .{});
            ctx.print("\x1b[0m", .{});
        },
    }

    ctx.print(fmt, args);

    switch (ctx.reporter.verbosity) {
        .normal => {
            ctx.print("\n", .{});
        },
        .quiet => {},
    }
}

pub fn printNote(ctx: Ctx, comptime fmt: []const u8, args: anytype) void {
    defer ctx.incrementItemCount();

    switch (ctx.reporter.verbosity) {
        .normal => {},
        .quiet => return,
    }

    ctx.printDepth();
    ctx.print("\x1b[36m", .{});
    ctx.print("Note: ", .{});
    ctx.print("\x1b[0m", .{});
    ctx.print(fmt, args);
    ctx.print("\n", .{});
}

pub fn printSourceNote(
    ctx: Ctx,
    comptime fmt: []const u8,
    args: anytype,
    span: Span,
) void {
    ctx.printNote(fmt ++ ": ", args);
    ctx.printSource(span);
}

fn printSource(ctx: Ctx, span: Span) void {
    const source = ctx.source orelse
        unreachable;

    switch (ctx.reporter.verbosity) {
        .normal => {},
        .quiet => {
            // Scuffed!
            if (if (ctx.item_count) |count| count.* > 2 else true)
                return;
            const line_number = span.getLineNumber(source);
            ctx.print(" (Line {})", .{line_number});
            ctx.print("\n", .{});
            return;
        },
    }

    Reporter.writeSpanContext(ctx.reporter.writer, span, 1, ctx.depth * indent_width, source) catch
        std.debug.panic("failed to write to reporter file", .{});
}
