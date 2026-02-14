const Air = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Span = @import("Span.zig");

origin: ?u16,

lines: ArrayList(Line),
allocator: Allocator,

pub const Line = struct {
    label: ?Span,
    statement: Statement,
    span: Span,

    pub const Statement = union(enum) {
        raw_word: u16,

        add: struct {
            dest: Register,
            src_a: Register,
            src_b: RegImm5,
        },

        lea: struct {
            dest: Register,
            src: Offset(9),
        },

        trap: struct {
            vect: TrapVect,
        },

        pub const Register = u3;

        // TODO: Rename
        pub const RegImm5 = union(enum) {
            register: Register,
            immediate: u5,
        };

        pub fn Offset(comptime bits: u16) type {
            return union(enum) {
                // TODO: Replace 'redundant' span with void ?
                unresolved: Span,
                resolved: @Int(.signed, bits),
            };
        }

        pub const TrapVect = u8;

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
                                    Register => try writer.print("Register = r{}", .{value}),
                                    RegImm5 => {
                                        try writer.print("Reg/Imm = ", .{});
                                        switch (value) {
                                            .register => |register| try writer.print("r{}", .{register}),
                                            .immediate => |immediate| try writer.print("0x{x:02}", .{immediate}),
                                        }
                                    },
                                    Offset(9) => {
                                        try writer.print("Label = ", .{});
                                        switch (value) {
                                            .unresolved => |span| try writer.print("\"{s}\" (unresolved)", .{span.resolve(self.source)}),
                                            .resolved => |offset| {
                                                const index: usize = @intCast(
                                                    @as(isize, @intCast(self.index)) +
                                                        @as(isize, @intCast(offset)),
                                                );
                                                if (self.air.lines.items[index].label) |label|
                                                    try writer.print("\"{s}\"", .{label.resolve(self.source)})
                                                else
                                                    try writer.print("<INVALID>", .{});
                                                try writer.print(" ({c}0x{x:04})", .{
                                                    @as(u8, if (offset < 0) '-' else '+'),
                                                    @abs(offset),
                                                });
                                            },
                                        }
                                    },
                                    TrapVect => try writer.print("Vect = 0x{x:02}", .{value}),
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
