const Printer = @This();

const std = @import("std");
const Io = std.Io;

const Ctx = @import("Ctx.zig");
const reporting = @import("reporting.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Printerface = @import("Printerface.zig");

writer: *Io.Writer,

pub fn new(writer: *Io.Writer) Printer {
    return .{
        .writer = writer,
    };
}

pub fn interface(printer: *Printer) Printerface {
    return .{
        .ptr = printer,
        .vtable = &.{
            .printDiagnostic = Printer.printDiagnostic,
            .printSummary = Printer.printSummary,
        },
    };
}

pub fn printDiagnostic(
    ptr: *anyopaque,
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: []const u8,
) error{WriteFailed}!void {
    const printer: *Printer = @ptrCast(@alignCast(ptr));

    var ctx_items: usize = 0;
    const ctx: Ctx = .new(
        printer.writer,
        verbosity,
        level,
        &ctx_items,
        source,
    );
    try ctx.printDiagnostic(diag);

    try printer.writer.flush();
}

pub fn printSummary(
    ptr: *anyopaque,
    count: *const std.EnumArray(reporting.Level, usize),
    verbosity: reporting.Options.Verbosity,
) error{WriteFailed}!void {
    const printer: *Printer = @ptrCast(@alignCast(ptr));

    const count_err = count.get(.err);
    const count_warn = count.get(.warn);
    // Ignore `info`

    const ctx: Ctx = .new(
        printer.writer,
        verbosity,
        .warn,
        null,
        null,
    );

    if (count_err > 0) {
        try ctx.writer.print("\x1b[31m", .{});
        try ctx.writer.print("{} error{s}", .{
            count_err, if (count_err == 1) "" else "s",
        });
        try ctx.writer.print("\x1b[0m", .{});
        try ctx.writer.print("\n", .{});
    }

    if (count_warn > 0) {
        try ctx.writer.print("\x1b[33m", .{});
        try ctx.writer.print("{} warnings{s}", .{
            count_warn, if (count_warn == 1) "" else "s",
        });
        try ctx.writer.print("\x1b[0m", .{});
        try ctx.writer.print("\n", .{});
    }

    try printer.writer.flush();
}
