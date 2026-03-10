const Reporter = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Policies = @import("../Policies.zig");
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

pub const Level = enum { err, warn };

pub const Options = struct {
    strictness: Strictness = .default,
    policies: *const Policies = &.default,

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

pub fn fromImplementation(ptr: *anyopaque, vtable: *const VTable) Reporter {
    return .{
        .options = .{},
        .count = .initFill(0),
        .source = null,
        .ptr = ptr,
        .vtable = vtable,
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
