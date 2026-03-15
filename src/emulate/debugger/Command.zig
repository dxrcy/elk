const Command = @This();

const std = @import("std");

const Span = @import("../../compile/Span.zig");

pub fn Spanned(comptime K: type) type {
    return struct { span: Span, value: K };
}

line: Span,
tag: Span,
value: Value,

pub const Value = union(enum) {
    help,
    quit,
    exit,
    reset,
    registers,
    @"continue",
    print: struct {
        location: Spanned(Location),
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
    };
};

pub const Label = struct {
    name: Span,
    offset: i16,
};

pub fn tagString(command: Tag) [:0]const u8 {
    return switch (command) {
        .help => "help",
        .@"continue" => "continue",
        .registers => "registers",
        .print => "print",
        .move => "move",
        .goto => "goto",
        .assembly => "assembly",
        .eval => "eval",
        .echo => "echo",
        .reset => "reset",
        .quit => "quit",
        .exit => "exit",
        .step_over => "step over",
        .step_into => "step into",
        .step_out => "step out",
        .break_list => "break list",
        .break_add => "break add",
        .break_remove => "break remove",
    };
}
