const Debugger = @This();

const std = @import("std");

const Span = @import("../compile/Span.zig");
const Lexer = @import("../compile/parse/Lexer.zig");
const Runtime = @import("Runtime.zig");

pub fn new() Debugger {
    return .{};
}

pub const Command = union(enum) {
    help,
    step_over,
    step_into: struct { count: u16 },
    step_out,
    @"continue",
    registers,
    print: struct { location: Location },
    move: struct { location: Location, value: u16 },
    goto: struct { location: Location.Memory },
    assembly: struct { location: Location.Memory },
    eval: struct { instruction: Span },
    Echo: struct { string: Span },
    Reset,
    Quit,
    Exit,
    BreakList,
    breakadd: struct { location: Location.Memory },
    breakremove: struct { location: Location.Memory },

    pub const Location = union(enum) {
        register: u3,
        memory: Memory,

        pub const Memory = union(enum) {
            pc_offset: i16,
            address: u16,
            label: Label,
        };
    };

    pub const Label = struct {
        name: Span,
        offset: i16,
    };
};

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    std.debug.print("[INVOKE DEBUGGER]\n", .{});

    var command_buffer: [20]u8 = undefined;

    const command_string = try debugger.readCommand(runtime, &command_buffer);

    std.debug.print("[{s}]\n", .{command_string});

    var lexer = Lexer.new(command_string, false);

    while (lexer.next()) |span| {
        std.debug.print("[{s}]\n", .{span.view(command_string)});
    }

    return null;
}

fn readCommand(debugger: *Debugger, runtime: *Runtime, buffer: []u8) ![]const u8 {
    _ = debugger;

    var length: usize = 0;

    try runtime.tty.enableRawMode();

    while (true) {
        std.debug.print("\r\x1b[K", .{});
        std.debug.print("{s}", .{buffer[0..length]});

        const char = try runtime.readByte();

        switch (char) {
            '\n' => break,

            std.ascii.control_code.bs,
            std.ascii.control_code.del,
            => if (length > 0) {
                length -= 1;
            },

            else => if (length < buffer.len) {
                buffer[length] = char;
                length += 1;
            },
        }
    }

    std.debug.print("\n", .{});
    try runtime.tty.disableRawMode();

    return buffer[0..length];
}
