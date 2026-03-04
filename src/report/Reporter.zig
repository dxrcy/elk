const Reporter = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Policies = @import("../Policies.zig");
const Token = @import("../compile/parse/Token.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Ctx = @import("Ctx.zig");

const BUFFER_SIZE = 1024;

options: Options,
count: std.EnumArray(Level, usize),
impl: Inner,

pub const Inner = struct {
    source: ?[]const u8,
    file: Io.File,
    buffer: [BUFFER_SIZE]u8,
    writer: Io.File.Writer,
    io: Io,
};

pub const Level = enum { err, warn };

pub const Options = struct {
    strictness: Strictness = .default,
    verbosity: Verbosity = .default,
    policies: *const Policies = &.default,

    pub const Strictness = enum {
        strict,
        normal,
        relaxed,
        const default: Strictness = .normal;
    };

    pub const Verbosity = enum {
        normal,
        quiet,
        const default: Verbosity = .normal;
    };
};

pub const Response = enum {
    /// Must be handled immediately.
    fatal,
    /// Must be handled in this pass.
    major,

    minor,
    pass,

    pub fn abort(response: Response) error{Reported}!noreturn {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .pass => unreachable,
        };
    }
    pub fn collect(response: Response, result: *error{Reported}!void) void {
        return switch (response) {
            .fatal, .major => {
                result.* = error.Reported;
            },
            .minor, .pass => {},
        };
    }
    pub fn handle(response: Response) error{Reported}!void {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .pass => {},
        };
    }
    /// Callsites should document why `proceed` is used rather than `handle`.
    pub fn proceed(response: Response) void {
        switch (response) {
            .fatal => unreachable,
            .major, .minor, .pass => {},
        }
    }
};

pub fn new(io: Io) Reporter {
    return .{
        .options = .{},
        .count = .initFill(0),
        .impl = .{
            .source = null,
            .file = undefined,
            .buffer = undefined,
            .writer = undefined,
            .io = io,
        },
    };
}

pub fn init(reporter: *Reporter) !void {
    reporter.impl.file = std.Io.File.stderr();
    reporter.impl.writer = reporter.impl.file.writer(reporter.impl.io, &reporter.impl.buffer);
}

pub fn setSource(reporter: *Reporter, source: []const u8) void {
    assert(reporter.impl.source == null);
    reporter.impl.source = source;
}

pub fn getLevel(reporter: *const Reporter) ?Level {
    if (reporter.count.get(.err) > 0)
        return .err;
    if (reporter.count.get(.warn) > 0)
        return .warn;
    return null;
}

pub fn showSummary(reporter: *Reporter) void {
    const count_err = reporter.count.get(.err);
    const count_warn = reporter.count.get(.warn);

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
        .pass => return .pass,
    };

    reporter.count.getPtr(level).* += 1;

    var ctx_items: usize = 0;
    const ctx: Ctx = .new(reporter, level, &ctx_items);
    const source = reporter.impl.source orelse
        unreachable;

    diag.print(ctx, source);
    ctx.flush();

    assert(response != .pass);
    return response;
}
