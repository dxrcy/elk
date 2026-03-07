const Debugger = @This();

const std = @import("std");

const Runtime = @import("Runtime.zig");
const Lexer = @import("../compile/parse/Lexer.zig");

pub fn new() Debugger {
    return .{};
}

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
