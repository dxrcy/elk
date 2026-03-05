const Air = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Runtime = @import("../emulate/Runtime.zig");
const Statement = @import("statement.zig").Statement;
const Span = @import("Span.zig");

pub const Operand = @import("Operand.zig");

origin: u16,
lines: ArrayList(Line),

pub const Line = struct {
    label: ?Span,
    statement: Statement,
    span: Span,
};

pub fn init() Air {
    return .{
        .origin = 0x3000,
        .lines = .empty,
    };
}

pub fn deinit(air: *Air, allocator: Allocator) void {
    air.lines.deinit(allocator);
}

pub fn getFirstSpan(air: *const Air) ?Span {
    if (air.lines.items.len == 0)
        return null;
    return air.lines.items[0].label orelse
        air.lines.items[0].span;
}

pub fn emitWriter(air: *const Air, writer: *Io.Writer) !void {
    assert(air.lines.items.len <= 0xffff);

    try writer.writeInt(u16, air.origin, .big);
    for (air.lines.items) |line| {
        const raw = line.statement.encode();
        try writer.writeInt(u16, raw, .big);
    }
}

pub fn emitRuntime(air: *const Air, runtime: *Runtime) !void {
    assert(air.lines.items.len <= 0xffff);

    runtime.pc = air.origin;
    for (air.lines.items, 0..) |line, i| {
        const raw = line.statement.encode();
        runtime.memory[air.origin + i] = raw;
    }
}
