const Fir = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Runtime = @import("../emulate/Runtime.zig");
const Span = @import("Span.zig");
pub const Instruction = @import("instruction.zig").Instruction;

lines: ArrayList(Line),

pub const Line = struct {
    statement: ?Statement,
    comment: ?Span,
};

pub const Statement = union(enum) {
    label: Span,
    directive: Directive,
    instruction: Instruction,

    pub const Directive = union(enum) {
        // TODO:
    };

    pub fn encode(statement: Statement) u16 {
        return switch (statement) {
            .raw_word => |raw| raw,
            .instruction => |instruction| instruction.encode(),
        };
    }
};

pub fn init() Fir {
    return .{ .lines = .empty };
}

pub fn deinit(air: *Fir, allocator: Allocator) void {
    air.lines.deinit(allocator);
}
