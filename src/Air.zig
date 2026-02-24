const Air = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Span = @import("Span.zig");
const Runtime = @import("Runtime.zig");

origin: u16,
lines: ArrayList(Line),

pub const Line = struct {
    label: ?Span,
    statement: Statement,
    span: Span,
};

/// Note that some instructions (`Statement` variants) share the same 4-bit
/// opcode, eg. `jsr` and `jsrr`, which are distinguished by the 5th-highest
/// bit.
pub const Statement = union(enum) {
    raw_word: u16,

    add: struct {
        dest: Operand.Register,
        src_a: Operand.Register,
        src_b: Operand.RegImm5,
    },
    @"and": struct {
        dest: Operand.Register,
        src_a: Operand.Register,
        src_b: Operand.RegImm5,
    },
    not: struct {
        dest: Operand.Register,
        src: Operand.Register,
    },
    br: struct {
        condition: Operand.ConditionMask,
        dest: Operand.PCOffset9,
    },
    jmp: struct {
        base: Operand.Register,
    },
    ret: struct {},
    jsr: struct {
        dest: Operand.PCOffset11,
    },
    jsrr: struct {
        base: Operand.Register,
    },
    lea: struct {
        dest: Operand.Register,
        src: Operand.PCOffset9,
    },
    ld: struct {
        dest: Operand.Register,
        src: Operand.PCOffset9,
    },
    ldi: struct {
        dest: Operand.Register,
        src: Operand.PCOffset9,
    },
    ldr: struct {
        dest: Operand.Register,
        src: Operand.Register,
        offset: Operand.Offset6,
    },
    st: struct {
        src: Operand.Register,
        dest: Operand.PCOffset9,
    },
    sti: struct {
        src: Operand.Register,
        dest: Operand.PCOffset9,
    },
    str: struct {
        src: Operand.Register,
        dest: Operand.Register,
        offset: Operand.Offset6,
    },
    trap: struct {
        vect: Operand.TrapVect,
    },
    rti: struct {},
};

pub const Operand = struct {
    // Shorthand
    pub const Register = Spanned(Value.Register);
    pub const RegImm5 = Spanned(Value.RegImm5);
    pub const TrapVect = Spanned(Value.TrapVect);
    pub const Offset6 = Spanned(Value.Offset6);
    pub const PCOffset9 = Spanned(Value.PCOffset9);
    pub const PCOffset11 = Spanned(Value.PCOffset11);
    pub const ConditionMask = Spanned(Value.ConditionMask);

    pub fn Spanned(comptime K: type) type {
        return struct {
            span: Span,
            value: K,
        };
    }

    pub const Value = struct {
        pub const Register = struct {
            code: u3,
            pub fn bits(self: @This()) u16 {
                return self.code;
            }
        };

        pub const RegImm5 = union(enum) {
            register: Value.Register,
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

        pub const PCOffset9 = union(enum) {
            unresolved,
            resolved: i9,
            pub fn bits(self: @This()) u16 {
                assert(self == .resolved);
                return @as(u9, @bitCast(self.resolved));
            }
        };

        pub const PCOffset11 = union(enum) {
            unresolved,
            resolved: i11,
            pub fn bits(self: @This()) u16 {
                assert(self == .resolved);
                return @as(u11, @bitCast(self.resolved));
            }
        };

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
    try writer.writeInt(u16, air.origin, .big);
    for (air.lines.items) |line| {
        const raw = encode(line.statement);
        try writer.writeInt(u16, raw, .big);
    }
}

pub fn emitMemory(air: *const Air, memory: *[Runtime.MEMORY_SIZE]u16) !void {
    for (air.lines.items, 0..) |line, i| {
        const raw = encode(line.statement);
        memory[air.origin + i] = raw;
    }
}

// TODO: Move to `Statement` ?
fn encode(statement: Statement) u16 {
    switch (statement) {
        .raw_word => |raw| {
            return raw;
        },
        .add => |operands| {
            var raw: u16 = 0x1000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src_a.value.bits() << 6;
            raw |= operands.src_b.value.bits();
            return raw;
        },
        .@"and" => |operands| {
            var raw: u16 = 0x5000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src_a.value.bits() << 6;
            raw |= operands.src_b.value.bits();
            return raw;
        },
        .not => |operands| {
            var raw: u16 = 0x9000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits() << 6;
            raw |= 0b111111;
            return raw;
        },
        .br => |operands| {
            var raw: u16 = 0x0000;
            raw |= operands.condition.value.bits() << 9;
            raw |= operands.dest.value.bits();
            return raw;
        },
        .jmp => |operands| {
            var raw: u16 = 0xc000;
            raw |= operands.base.value.bits() << 6;
            return raw;
        },
        .ret => {
            return 0xc1c0;
        },
        .jsr => |operands| {
            var raw: u16 = 0x4800;
            raw |= operands.dest.value.bits();
            return raw;
        },
        .jsrr => |operands| {
            var raw: u16 = 0x4000;
            raw |= operands.base.value.bits() << 6;
            return raw;
        },
        .lea => |operands| {
            var raw: u16 = 0xe000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits();
            return raw;
        },
        .ld => |operands| {
            var raw: u16 = 0x2000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits();
            return raw;
        },
        .ldi => |operands| {
            var raw: u16 = 0xa000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits();
            return raw;
        },
        .ldr => |operands| {
            var raw: u16 = 0x6000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits() << 6;
            raw |= operands.offset.value.bits();
            return raw;
        },
        .st => |operands| {
            var raw: u16 = 0x3000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits();
            return raw;
        },
        .sti => |operands| {
            var raw: u16 = 0xB000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits();
            return raw;
        },
        .str => |operands| {
            var raw: u16 = 0x7000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits() << 6;
            raw |= operands.offset.value.bits();
            return raw;
        },
        .trap => |operands| {
            var raw: u16 = 0xf000;
            raw |= operands.vect.value.bits();
            return raw;
        },
        .rti => {
            return 0x8000;
        },
    }
}
