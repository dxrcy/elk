const Printer = @This();

const std = @import("std");
const Io = std.Io;

const Source = @import("../compile/Source.zig");
const Ctx = @import("Ctx.zig");
const reporting = @import("reporting.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const Fancy = @import("FancySink.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    sendDiagnostic: *const fn (
        ptr: *anyopaque,
        diag: Diagnostic,
        level: reporting.Level,
        verbosity: reporting.Options.Verbosity,
        source: Source,
    ) error{WriteFailed}!void,

    sendSummary: *const fn (
        ptr: *anyopaque,
        count: *const std.EnumArray(reporting.Level, usize),
        verbosity: reporting.Options.Verbosity,
    ) error{WriteFailed}!void,
};

pub fn sendDiagnostic(
    printer: *Printer,
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: Source,
) error{WriteFailed}!void {
    return printer.vtable.sendDiagnostic(printer.ptr, diag, level, verbosity, source);
}

pub fn sendSummary(
    printer: *Printer,
    count: *const std.EnumArray(reporting.Level, usize),
    verbosity: reporting.Options.Verbosity,
) error{WriteFailed}!void {
    return printer.vtable.sendSummary(printer.ptr, count, verbosity);
}
