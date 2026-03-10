const std = @import("std");

const Span = @import("../../compile/Span.zig");

pub const Command = union(enum) {
    help,
    @"continue",
    registers,
    print: struct { location: Location },
    move: struct { location: Location, value: u16 },
    goto: struct { location: Location.Memory },
    assembly: struct { location: Location.Memory },
    eval: struct { instruction: Span },
    echo: struct { string: Span },
    reset,
    quit,
    exit,
    step_over,
    step_into: struct { count: u16 },
    step_out,
    break_list,
    break_add: struct { location: Location.Memory },
    break_remove: struct { location: Location.Memory },

    pub const Tag = std.meta.Tag(@This());

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
};
