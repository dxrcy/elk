const Printer = @This();

const std = @import("std");
const Io = std.Io;

const Ctx = @import("Ctx.zig");
const reporting = @import("reporting.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    printDiagnostic: *const fn (
        ptr: *anyopaque,
        diag: Diagnostic,
        level: reporting.Level,
        verbosity: reporting.Options.Verbosity,
        source: []const u8,
    ) error{WriteFailed}!void,

    printSummary: *const fn (
        ptr: *anyopaque,
        count: *const std.EnumArray(reporting.Level, usize),
        verbosity: reporting.Options.Verbosity,
    ) error{WriteFailed}!void,
};

pub fn printDiagnostic(
    printer: *Printer,
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: []const u8,
) error{WriteFailed}!void {
    return printer.vtable.printDiagnostic(printer.ptr, diag, level, verbosity, source);
}

pub fn printSummary(
    printer: *Printer,
    count: *const std.EnumArray(reporting.Level, usize),
    verbosity: reporting.Options.Verbosity,
) error{WriteFailed}!void {
    return printer.vtable.printSummary(printer.ptr, count, verbosity);
}
