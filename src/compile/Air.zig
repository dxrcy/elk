const Air = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Runtime = @import("../emulate/Runtime.zig");
const Span = @import("Span.zig");
pub const Instruction = @import("instruction.zig").Instruction;

origin: u16,
lines: ArrayList(Line),
labels: ArrayList(Label),

pub const Label = struct {
    /// Index in `lines`. `address - offset`.
    index: u16,
    span: Span,
    references: usize,
    kind: Kind,

    pub fn new(index: u16, span: Span, string: []const u8) Label {
        return .{
            .index = index,
            .span = span,
            .references = 0,
            .kind = .from(string),
        };
    }

    pub const Kind = enum {
        normal,
        breakpoint,
        pub fn from(string: []const u8) Kind {
            return if (std.mem.startsWith(u8, string, "__")) .breakpoint else .normal;
        }
    };
};

pub const Line = struct {
    statement: Statement,
    span: Span,
};

pub const Statement = union(enum) {
    raw_word: u16,
    instruction: Instruction,

    pub fn encode(statement: Statement) u16 {
        return switch (statement) {
            .raw_word => |raw| raw,
            .instruction => |instruction| instruction.encode(),
        };
    }
};

pub fn init() Air {
    return .{
        .origin = 0x3000,
        .lines = .empty,
        .labels = .empty,
    };
}

pub fn deinit(air: *Air, gpa: Allocator) void {
    air.lines.deinit(gpa);
    air.labels.deinit(gpa);
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

    runtime.state.pc = air.origin;
    for (air.lines.items, 0..) |line, i| {
        const raw = line.statement.encode();
        runtime.state.memory[air.origin + i] = raw;
    }
}

pub fn findLabelDefinition(
    air: *const Air,
    reference: []const u8,
    case_mode: enum { sensitive, insensitive },
    source: []const u8,
) ?*Label {
    assertLabelOrder(air);
    for (air.labels.items) |*label| {
        const string = label.span.view(source);
        const matches = switch (case_mode) {
            .sensitive => std.mem.eql(u8, string, reference),
            .insensitive => std.ascii.eqlIgnoreCase(string, reference),
        };
        if (matches)
            return label;
    }
    return null;
}

pub fn assertLabelOrder(air: *const Air) void {
    var i: usize = 0;
    while (i + 1 < air.labels.items.len) : (i += 1) {
        const first = air.labels.items[i];
        const second = air.labels.items[i + 1];
        assert(first.index <= second.index);
    }
}
