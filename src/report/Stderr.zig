const Stderr = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Reporter = @import("Reporter.zig");
const Ctx = @import("Ctx.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

source: ?[]const u8,
writer: *Io.Writer,
verbosity: Verbosity,

pub const Verbosity = enum {
    normal,
    quiet,
    pub const default: Verbosity = .normal;
};

pub fn new(writer: *Io.Writer) Stderr {
    return .{
        .source = null,
        .writer = writer,
        .verbosity = .default,
    };
}

pub fn interface(reporter: *Stderr) Reporter {
    return .fromImplementation(reporter, &.{
        .showReport = showReport,
        .showSummary = showSummary,
    });
}

pub fn setSource(reporter: *Stderr, source: []const u8) void {
    assert(reporter.source == null);
    reporter.source = source;
}

pub fn showReport(
    ptr: *anyopaque,
    diag: Diagnostic,
    level: Reporter.Level,
) void {
    const reporter: *Stderr = @ptrCast(@alignCast(ptr));

    var ctx_items: usize = 0;
    const ctx: Ctx = .new(reporter, level, &ctx_items);
    const source = reporter.source orelse
        unreachable;

    diag.print(ctx, source);
    ctx.flush();
}

pub fn showSummary(
    ptr: *anyopaque,
    count: *const std.EnumArray(Reporter.Level, usize),
) void {
    const reporter: *Stderr = @ptrCast(@alignCast(ptr));

    const count_err = count.get(.err);
    const count_warn = count.get(.warn);

    const ctx: Ctx = .new(reporter, .warn, null);

    if (count_err > 0) {
        ctx.print("\x1b[31m", .{});
        ctx.print("{} errors", .{count_err});
        ctx.print("\x1b[0m", .{});
        ctx.print("\n", .{});
    }

    if (count_warn > 0) {
        ctx.print("\x1b[33m", .{});
        ctx.print("{} warnings", .{count_warn});
        ctx.print("\x1b[0m", .{});
        ctx.print("\n", .{});
    }

    ctx.flush();
}
