const Discarding = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Reporter = @import("Reporter.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const init: Reporter = .fromImplementation(undefined, &.{
    .showReport = showReport,
    .showSummary = showSummary,
});

pub fn showReport(
    _: *anyopaque,
    _: Diagnostic,
    _: Reporter.Level,
    _: ?[]const u8,
) void {
    return;
}

pub fn showSummary(
    _: *anyopaque,
    _: *const std.EnumArray(Reporter.Level, usize),
) void {
    return;
}
