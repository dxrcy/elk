const Collect = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const elk = @import("../../root.zig");
const Source = elk.Source;
const Reporter = elk.Reporter;

const Sink = @import("Sink.zig");

inner: Sink,
entries: std.ArrayList(Entry),
gpa: Allocator,

// TODO: Rename
const Entry = struct {
    diag: Reporter.Diagnostic,
    level: Reporter.Level,
    verbosity: Reporter.Options.Verbosity,
    source: ?Source,
};

pub fn init(gpa: Allocator, inner: Sink) Collect {
    return .{
        .inner = inner,
        .entries = .empty,
        .gpa = gpa,
    };
}

pub fn deinit(sink: *Collect) void {
    sink.entries.deinit(sink.gpa);
}

pub fn interface(sink: *Collect) Sink {
    return .{
        .ptr = sink,
        .vtable = &.{
            .sendDiagnostic = Collect.sendDiagnostic,
            .flush = Collect.flush,
            .sendSummary = Collect.sendSummary,
        },
    };
}

pub fn sendDiagnostic(
    ptr: *anyopaque,
    diag: Reporter.Diagnostic,
    level: Reporter.Level,
    verbosity: Reporter.Options.Verbosity,
    source: ?Source,
) error{WriteFailed}!void {
    const sink: *Collect = @ptrCast(@alignCast(ptr));

    sink.entries.append(sink.gpa, .{
        .diag = diag,
        .level = level,
        .verbosity = verbosity,
        .source = source,
    }) catch
        return error.WriteFailed;
}

pub fn flush(ptr: *anyopaque) error{WriteFailed}!void {
    const sink: *Collect = @ptrCast(@alignCast(ptr));

    // Stable
    std.mem.sort(Entry, sink.entries.items, {}, lessThanEntry);

    for (sink.entries.items) |entry|
        try sink.inner.sendDiagnostic(entry.diag, entry.level, entry.verbosity, entry.source);

    sink.entries.clearRetainingCapacity();
}

pub fn sendSummary(
    ptr: *anyopaque,
    count: *const std.EnumArray(Reporter.Level, usize),
    verbosity: Reporter.Options.Verbosity,
) error{WriteFailed}!void {
    const sink: *Collect = @ptrCast(@alignCast(ptr));

    try flush(sink);
    try sink.inner.sendSummary(count, verbosity);
}

fn lessThanEntry(_: void, a: Entry, b: Entry) bool {
    const a_span = a.diag.getPrimarySpan() orelse
        return false;
    const b_span = b.diag.getPrimarySpan() orelse
        return false;
    return a_span.offset < b_span.offset;
}
