const Sink = @This();

const std = @import("std");
const Io = std.Io;

const elk = @import("../root.zig");
const Source = elk.Source;
const reporting = elk.reporting;
const Ctx = @import("Ctx.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const Fancy = @import("FancySink.zig");
pub const Collect = @import("CollectSink.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    sendDiagnostic: *const fn (
        ptr: *anyopaque,
        diag: Diagnostic,
        level: reporting.Level,
        verbosity: reporting.Options.Verbosity,
        source: ?Source,
    ) error{WriteFailed}!void,

    sendSummary: *const fn (
        ptr: *anyopaque,
        count: *const std.EnumArray(reporting.Level, usize),
        verbosity: reporting.Options.Verbosity,
    ) error{WriteFailed}!void,
};

pub fn sendDiagnostic(
    sink: *Sink,
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: ?Source,
) error{WriteFailed}!void {
    return sink.vtable.sendDiagnostic(sink.ptr, diag, level, verbosity, source);
}

pub fn sendSummary(
    sink: *Sink,
    count: *const std.EnumArray(reporting.Level, usize),
    verbosity: reporting.Options.Verbosity,
) error{WriteFailed}!void {
    return printer.vtable.sendSummary(printer.ptr, count, verbosity);
}
