const Air = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Span = @import("Span.zig");
const Integer = @import("integers.zig").Integer;

origin: ?u16,

lines: ArrayList(Line),
allocator: Allocator,

pub fn OperandSpan(comptime K: type) type {
    return struct {
        span: Span,
        value: K,

        pub const Kind: type = K;
    };
}

pub const Operand = struct {
    pub const Register = struct {
        // TODO: Rename to `inner` or something (and elsewhere)
        value: u3,
        pub fn bits(self: Register) u16 {
            return self.value;
        }
    };

    // TODO: Rename
    pub const RegImm5 = union(enum) {
        register: u3,
        immediate: u5,
        pub fn bits(self: RegImm5) u16 {
            return switch (self) {
                .register => |register| register,
                .immediate => |immediate| 0b100000 + @as(u16, immediate),
            };
        }
    };

    pub const TrapVect = struct {
        value: u8,
        pub fn bits(self: TrapVect) u16 {
            return self.value;
        }
    };

    pub const Offset6 = struct {
        value: i6,
        pub fn bits(self: Offset6) u16 {
            return @as(u6, @bitCast(self.value));
        }
    };

    pub const PCOffset9 = union(enum) {
        unresolved,
        resolved: i9,
        pub fn bits(self: PCOffset9) u16 {
            return @as(u9, @bitCast(self.resolved));
        }
    };

    pub const PCOffset11 = union(enum) {
        unresolved,
        resolved: i11,
        pub fn bits(self: PCOffset11) u16 {
            return @as(u11, @bitCast(self.resolved));
        }
    };
};

pub const Line = struct {
    label: ?Span,
    statement: Statement,
    span: Span,
};

pub const Statement = union(enum) {
    raw_word: u16,

    add: struct {
        dest: OperandSpan(Operand.Register),
        src_a: OperandSpan(Operand.Register),
        src_b: OperandSpan(Operand.RegImm5),
    },

    jsr: struct {
        dest: OperandSpan(Operand.PCOffset11),
    },

    ldr: struct {
        dest: OperandSpan(Operand.Register),
        src: OperandSpan(Operand.Register),
        offset: OperandSpan(Operand.Offset6),
    },

    lea: struct {
        dest: OperandSpan(Operand.Register),
        src: OperandSpan(Operand.PCOffset9),
    },

    trap: struct {
        vect: OperandSpan(Operand.TrapVect),
    },

    pub fn format(
        statement: Statement,
        air: *const Air,
        source: []const u8,
        index: usize,
    ) Format {
        return .{
            .statement = statement,
            .air = air,
            .source = source,
            .index = index,
        };
    }

    pub const Format = struct {
        statement: Statement,
        air: *const Air,
        source: []const u8,
        index: usize,

        pub fn format(self: Format, writer: *std.Io.Writer) !void {
            inline for (@typeInfo(Statement).@"union".fields) |tag| {
                if (std.mem.eql(u8, @tagName(self.statement), tag.name)) {
                    const variant = @field(self.statement, tag.name);

                    if (@typeInfo(tag.type) == .@"struct") {
                        assert(self.statement != .raw_word);

                        for (tag.name) |char| {
                            try writer.print("{c}", .{std.ascii.toUpper(char)});
                        }
                        try writer.print(":\n", .{});

                        inline for (@typeInfo(tag.type).@"struct".fields) |field| {
                            try writer.print("{s:8}: ", .{field.name});
                            const operand = @field(variant, field.name);
                            switch (@field(field.type, "Kind")) {
                                Operand.Register => try writer.print("Register = r{}", .{operand.value.value}),
                                Operand.RegImm5 => {
                                    try writer.print("Reg/Imm = ", .{});
                                    switch (operand.value) {
                                        .register => |register| try writer.print("r{}", .{register}),
                                        .immediate => |immediate| try writer.print("0x{x:02}", .{immediate}),
                                    }
                                },
                                Operand.TrapVect => try writer.print("Vect = 0x{x:02}", .{operand.value.value}),
                                Operand.Offset6 => try writer.print("Offset6 = 0x{x:04}", .{operand.value.value}),
                                Operand.PCOffset9,
                                Operand.PCOffset11,
                                => {
                                    try writer.print("PCOffset(9/11) = ", .{});
                                    switch (operand.value) {
                                        .unresolved => try writer.print("\"{s}\" (unresolved)", .{operand.span.view(self.source)}),
                                        .resolved => |offset| {
                                            const index: usize = @intCast(
                                                @as(isize, @intCast(self.index)) +
                                                    @as(isize, @intCast(offset)) + 1,
                                            );
                                            if (self.air.lines.items[index].label) |label|
                                                try writer.print("\"{s}\"", .{label.view(self.source)})
                                            else
                                                try writer.print("<?>", .{});
                                            try writer.print(" ({c}0x{x:04})", .{
                                                @as(u8, if (offset < 0) '-' else '+'),
                                                @abs(offset),
                                            });
                                        },
                                    }
                                },
                                else => comptime unreachable,
                            }
                            try writer.print("\n", .{});
                        }
                    } else {
                        assert(self.statement == .raw_word);

                        try writer.print("    0x{x:04}", .{variant});
                        if (variant > 0x7f) {
                            try writer.print(" (?)", .{});
                        } else switch (@as(u8, @intCast(variant))) {
                            '\n' => try writer.print(" '\\n'", .{}),
                            else => |char| try writer.print(" '{c}'", .{char}),
                        }
                        try writer.print("\n", .{});
                    }
                }
            }
        }
    };
};

pub fn init(allocator: Allocator) Air {
    return .{
        .origin = null,
        .lines = .empty,
        .allocator = allocator,
    };
}

pub fn deinit(air: *Air) void {
    air.lines.deinit(air.allocator);
}

pub fn emit(air: *const Air, writer: *Io.Writer) !void {
    try writer.writeInt(u16, air.origin.?, .big);

    for (air.lines.items) |line| {
        const raw = encode(line.statement);
        try writer.writeInt(u16, raw, .big);
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
        .jsr => |operands| {
            var raw: u16 = 0x4800;
            raw |= operands.dest.value.bits();
            return raw;
        },
        .ldr => |operands| {
            var raw: u16 = 0xa000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits() << 6;
            raw |= operands.offset.value.bits();
            return raw;
        },
        .lea => |operands| {
            var raw: u16 = 0xe000;
            raw |= operands.dest.value.bits() << 9;
            raw |= operands.src.value.bits();
            return raw;
        },
        .trap => |operands| {
            var raw: u16 = 0xf000;
            raw |= operands.vect.value.bits();
            return raw;
        },
    }
}
