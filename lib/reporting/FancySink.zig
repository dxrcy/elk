const FancySink = @This();

const std = @import("std");
const Io = std.Io;

const Ctx = @import("Ctx.zig");
const reporting = @import("reporting.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Sink = @import("Sink.zig");

pub const writeSpanContext = Ctx.writeSpanContext;

writer: *Io.Writer,

pub fn new(writer: *Io.Writer) FancySink {
    return .{
        .writer = writer,
    };
}

pub fn interface(sink: *FancySink) Sink {
    return .{
        .ptr = sink,
        .vtable = &.{
            .sendDiagnostic = FancySink.sendDiagnostic,
            .sendSummary = FancySink.sendSummary,
        },
    };
}

pub fn sendDiagnostic(
    ptr: *anyopaque,
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: []const u8,
) error{WriteFailed}!void {
    const sink: *FancySink = @ptrCast(@alignCast(ptr));

    var ctx_items: usize = 0;
    const ctx: Ctx = .new(
        sink.writer,
        verbosity,
        level,
        &ctx_items,
        source,
    );
    try ctx.writeDiagnostic(diag);

    try sink.writer.flush();
}

pub fn sendSummary(
    ptr: *anyopaque,
    count: *const std.EnumArray(reporting.Level, usize),
    verbosity: reporting.Options.Verbosity,
) error{WriteFailed}!void {
    const sink: *FancySink = @ptrCast(@alignCast(ptr));

    const count_err = count.get(.err);
    const count_warn = count.get(.warn);
    // Ignore `info`

    const ctx: Ctx = .new(
        sink.writer,
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

    try sink.writer.flush();
}
