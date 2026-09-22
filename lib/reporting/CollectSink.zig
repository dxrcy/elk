const CollectSink = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const elk = @import("../root.zig");
const Source = elk.Source;
const reporting = elk.reporting;
const Sink = @import("Sink.zig");
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;

inner: Sink,
entries: std.ArrayList(Entry),
gpa: Allocator,

// TODO: Rename
const Entry = struct {
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: ?Source,
};

pub fn init(gpa: Allocator, inner: Sink) CollectSink {
    return .{
        .inner = inner,
        .entries = .empty,
        .gpa = gpa,
    };
}

pub fn deinit(sink: *CollectSink) void {
    sink.entries.deinit(sink.gpa);
}

pub fn interface(sink: *CollectSink) Sink {
    return .{
        .ptr = sink,
        .vtable = &.{
            .sendDiagnostic = CollectSink.sendDiagnostic,
            .sendSummary = CollectSink.sendSummary,
        },
    };
}

pub fn sendDiagnostic(
    ptr: *anyopaque,
    diag: Diagnostic,
    level: reporting.Level,
    verbosity: reporting.Options.Verbosity,
    source: ?Source,
) error{WriteFailed}!void {
    const sink: *CollectSink = @ptrCast(@alignCast(ptr));

    sink.entries.append(sink.gpa, .{
        .diag = diag,
        .level = level,
        .verbosity = verbosity,
        .source = source,
    }) catch
        return error.WriteFailed;
}

pub fn sendSummary(
    ptr: *anyopaque,
    count: *const std.EnumArray(reporting.Level, usize),
    verbosity: reporting.Options.Verbosity,
) error{WriteFailed}!void {
    const sink: *CollectSink = @ptrCast(@alignCast(ptr));

    for (sink.entries.items) |entry|
        try sink.inner.sendDiagnostic(entry.diag, entry.level, entry.verbosity, entry.source);
    try sink.inner.sendSummary(count, verbosity);
}
