const std = @import("std");
const assert = std.debug.assert;

const Span = @import("Span.zig");
const Form = @import("parse/integers.zig").Form;

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

pub fn Formed(comptime I: type) type {
    return struct {
        integer: I,
        form: ?Form,
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
        immediate: Formed(i5),
        pub fn bits(self: @This()) u16 {
            return switch (self) {
                .register => |register| register.bits(),
                .immediate => |immediate| 0b100000 +
                    @as(u16, @as(u5, @bitCast(immediate.integer))),
            };
        }
    };

    pub const TrapVect = struct {
        immediate: Formed(u8),
        pub fn bits(self: @This()) u16 {
            return self.immediate.integer;
        }
    };

    pub const Offset6 = struct {
        immediate: Formed(i6),
        pub fn bits(self: @This()) u16 {
            return @as(u6, @bitCast(self.immediate.integer));
        }
    };

    pub fn PcOffset(comptime size: u4) type {
        switch (size) {
            9, 10, 11 => {},
            else => comptime unreachable,
        }
        return union(enum) {
            unresolved,
            resolved: Formed(@Int(.signed, size)),
            pub fn bits(self: @This()) u16 {
                assert(self == .resolved);
                return @as(@Int(.unsigned, size), @bitCast(self.resolved.integer));
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
