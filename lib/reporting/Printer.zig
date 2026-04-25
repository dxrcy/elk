const Printer = @This();

const std = @import("std");
const Io = std.Io;

const Ctx = @import("Ctx.zig");
const reporting = @import("reporting.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

writer: *Io.Writer,

pub fn new(writer: *Io.Writer) Printer {
    return .{
        .writer = writer,
    };
}

pub fn printDiagnostic(
    printer: *Printer,
    diag: Diagnostic,
    verbosity: reporting.Options.Verbosity,
    level: reporting.Level,
    source: []const u8,
) error{WriteFailed}!void {
    var ctx_items: usize = 0;
    const ctx: Ctx = .new(
        printer.writer,
        verbosity,
        level,
        &ctx_items,
        source,
    );
    try ctx.printDiagnostic(diag);
    try ctx.writer.flush();
}
