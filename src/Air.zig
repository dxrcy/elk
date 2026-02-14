const Air = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Span = @import("Span.zig");
const Integer = @import("integers.zig").Integer;

origin: ?u16,

lines: ArrayList(Line),
allocator: Allocator,

// TODO: Somehow add spans to all operators ? (currently only `Offset9.unresolved`)
pub const Operand = enum {
    register,
    reg_imm5,
    offset9,
    word,
    string,

    // TODO: Rename
    pub fn asType(comptime operand: Operand) type {
        return switch (operand) {
            .register => Register,
            .reg_imm5 => RegImm5,
            .offset9 => Offset9,
            .word => Integer(16),
            .string => []const u8,
        };
    }

    pub const Register = struct {
        value: u3,
        pub const operand: Operand = .register;
    };

    // TODO: Rename
    pub const RegImm5 = union(enum) {
        register: u3,
        immediate: u5,
        pub const operand: Operand = .reg_imm5;
    };

    pub const Offset9 = union(enum) {
        unresolved: Span,
        resolved: i9,
        pub const operand: Operand = .offset9;
    };

    pub const TrapVect = u8;
};

pub const Line = struct {
    label: ?Span,
    statement: Statement,
    span: Span,
};

pub const Statement = union(enum) {
    raw_word: u16,

    add: struct {
        dest: Operand.Register,
        src_a: Operand.Register,
        src_b: Operand.RegImm5,
    },

    lea: struct {
        dest: Operand.Register,
        src: Operand.Offset9,
    },

    trap: struct {
        vect: Operand.TrapVect,
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
                            const value = @field(variant, field.name);
                            switch (field.type) {
                                Operand.Register => try writer.print("Register = r{}", .{value.value}),
                                Operand.RegImm5 => {
                                    try writer.print("Reg/Imm = ", .{});
                                    switch (value) {
                                        .register => |register| try writer.print("r{}", .{register}),
                                        .immediate => |immediate| try writer.print("0x{x:02}", .{immediate}),
                                    }
                                },
                                Operand.Offset9 => {
                                    try writer.print("Label = ", .{});
                                    switch (value) {
                                        .unresolved => |span| try writer.print("\"{s}\" (unresolved)", .{span.view(self.source)}),
                                        .resolved => |offset| {
                                            const index: usize = @intCast(
                                                @as(isize, @intCast(self.index)) +
                                                    @as(isize, @intCast(offset)),
                                            );
                                            if (self.air.lines.items[index].label) |label|
                                                try writer.print("\"{s}\"", .{label.view(self.source)})
                                            else
                                                try writer.print("<INVALID>", .{});
                                            try writer.print(" ({c}0x{x:04})", .{
                                                @as(u8, if (offset < 0) '-' else '+'),
                                                @abs(offset),
                                            });
                                        },
                                    }
                                },
                                Operand.TrapVect => try writer.print("Vect = 0x{x:02}", .{value}),
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
