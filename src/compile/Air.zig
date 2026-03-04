const Air = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Runtime = @import("../emulate/Runtime.zig");
const Statement = @import("statement.zig").Statement;
const Span = @import("Span.zig");

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

pub const Operand = struct {
    // Shorthand
    pub const Register = Spanned(value.Register);
    pub const RegImm5 = Spanned(value.RegImm5);
    pub const TrapVect = Spanned(value.TrapVect);
    pub const Offset6 = Spanned(value.Offset6);
    pub const ConditionMask = Spanned(value.ConditionMask);
    pub fn PcOffset(comptime size: u4) type {
        return Spanned(value.PcOffset(size));
    }

    pub fn Spanned(comptime K: type) type {
        return struct {
            span: Span,
            value: K,
        };
    }

    pub const value = struct {
        pub const Register = struct {
            code: u3,
            pub fn bits(self: @This()) u16 {
                return self.code;
            }
        };

        pub const RegImm5 = union(enum) {
            register: value.Register,
            immediate: i5,
            pub fn bits(self: @This()) u16 {
                return switch (self) {
                    .register => |register| register.bits(),
                    .immediate => |immediate| 0b100000 +
                        @as(u16, @as(u5, @bitCast(immediate))),
                };
            }
        };

        pub const TrapVect = struct {
            immediate: u8,
            pub fn bits(self: @This()) u16 {
                return self.immediate;
            }
        };

        pub const Offset6 = struct {
            immediate: i6,
            pub fn bits(self: @This()) u16 {
                return @as(u6, @bitCast(self.immediate));
            }
        };

        pub fn PcOffset(comptime size: u4) type {
            switch (size) {
                9, 10, 11 => {},
                else => comptime unreachable,
            }
            return union(enum) {
                unresolved,
                resolved: @Int(.signed, size),
                pub fn bits(self: @This()) u16 {
                    assert(self == .resolved);
                    return @as(@Int(.unsigned, size), @bitCast(self.resolved));
                }
            };
        }

        pub const ConditionMask = enum(u3) {
            n = 0b100,
            z = 0b010,
            p = 0b001,
            nz = 0b110,
            zp = 0b011,
            np = 0b101,
            nzp = 0b111,
            pub fn bits(self: @This()) u16 {
                return @intFromEnum(self);
            }
        };
    };
};
