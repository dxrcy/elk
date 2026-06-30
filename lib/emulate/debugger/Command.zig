const Command = @This();

const std = @import("std");

const Span = @import("../../compile/Span.zig");
const Spanned = Span.Spanned;

line: Span,
tag: Span,
value: Value,

pub const Value = union(enum) {
    help,
    quit,
    exit,
    clear,
    reset,
    registers,
    @"continue",
    print: struct {
        location: Spanned(Location),
    },
    list: struct {
        start: Spanned(Location.Memory),
        end: Spanned(Location.Memory),
    },
    move: struct {
        location: Spanned(Location),
        value: Spanned(u16),
    },
    goto: struct {
        location: Spanned(Location.Memory),
    },
    assembly: struct {
        location: Spanned(Location.Memory),
        context: Spanned(u16),
    },
    eval: struct {
        instruction: Span,
    },
    echo: struct {
        string: Span,
    },
    step_over,
    step_into: struct {
        count: Spanned(u16),
    },
    step_out,
    break_list,
    break_add: struct {
        location: Spanned(Location.Memory),
    },
    break_remove: struct {
        location: Spanned(Location.Memory),
    },
};

pub const Tag = std.meta.Tag(Value);

pub const Location = union(enum) {
    register: u3,
    memory: Memory,

    pub const Memory = union(enum) {
        address: u16,
        pc_offset: i16,
        label: Label,

        pub fn add(location: Memory, length: u16) error{Overflow}!Memory {
            return switch (location) {
                .address => |address| .{
                    .address = try std.math.add(u16, address, length),
                },
                .pc_offset => |pc_offset| .{
                    .pc_offset = try addToOffset(pc_offset, length),
                },
                .label => |label| .{ .label = .{
                    .name = label.name,
                    .offset = try addToOffset(label.offset, length),
                } },
            };
        }

        fn addToOffset(offset: i16, length: u16) error{Overflow}!i16 {
            return try std.math.add(
                i16,
                offset,
                std.math.cast(i16, length) orelse
                    return error.Overflow,
            );
        }
    };
};

pub const Label = struct {
    name: Span,
    offset: i16,
};

pub fn tagString(command: Tag) [:0]const u8 {
    return switch (command) {
        .help => "help",
        .quit => "quit",
        .exit => "exit",
        .clear => "clear",
        .reset => "reset",
        .registers => "registers",
        .@"continue" => "continue",
        .print => "print",
        .list => "list",
        .move => "move",
        .goto => "goto",
        .assembly => "assembly",
        .eval => "eval",
        .echo => "echo",
        .step_over => "step over",
        .step_into => "step into",
        .step_out => "step out",
        .break_list => "break list",
        .break_add => "break add",
        .break_remove => "break remove",
    };
}
