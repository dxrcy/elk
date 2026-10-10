const Sink = @This();

const std = @import("std");
const Io = std.Io;

const elk = @import("../../root.zig");
const Source = elk.Source;
const Reporter = elk.Reporter;

pub const Fancy = @import("Fancy.zig");
pub const Collect = @import("Collect.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    sendDiagnostic: *const fn (
        ptr: *anyopaque,
        diag: Reporter.Diagnostic,
        level: Reporter.Level,
        verbosity: Reporter.Options.Verbosity,
        source: ?Source,
    ) error{WriteFailed}!void,

    flush: *const fn (ptr: *anyopaque) error{WriteFailed}!void,

    sendSummary: *const fn (
        ptr: *anyopaque,
        count: *const std.EnumArray(Reporter.Level, usize),
        verbosity: Reporter.Options.Verbosity,
    ) error{WriteFailed}!void,
};

pub fn sendDiagnostic(
    sink: *Sink,
    diag: Reporter.Diagnostic,
    level: Reporter.Level,
    verbosity: Reporter.Options.Verbosity,
    source: ?Source,
) error{WriteFailed}!void {
    return sink.vtable.sendDiagnostic(sink.ptr, diag, level, verbosity, source);
}

pub fn flush(sink: *Sink) error{WriteFailed}!void {
    return sink.vtable.flush(sink.ptr);
}

pub fn sendSummary(
    sink: *Sink,
    count: *const std.EnumArray(Reporter.Level, usize),
    verbosity: Reporter.Options.Verbosity,
) error{WriteFailed}!void {
    return sink.vtable.sendSummary(sink.ptr, count, verbosity);
}
