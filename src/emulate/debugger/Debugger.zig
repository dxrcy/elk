const Debugger = @This();

const std = @import("std");
const control_code = std.ascii.control_code;

const Runtime = @import("../Runtime.zig");
const parseCommand = @import("parse.zig").parseCommand;

pub fn new() Debugger {
    return .{};
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    std.debug.print("[INVOKE DEBUGGER]\n", .{});

    var command_buffer: [20]u8 = undefined;

    while (true) {
        std.debug.print("\n", .{});

        const command_string = try debugger.readCommand(runtime, &command_buffer);

        const command = parseCommand(command_string) catch |err| {
            std.debug.print("Error: {t}\n", .{err});
            continue;
        };

        std.debug.print("Command: {}\n", .{command});
        return null;
    }
}

const Input = struct {
    const Io = std.Io;
    const assert = std.debug.assert;

    buffer: []u8,
    length: usize,
    cursor: usize,

    reader: *Io.Reader,

    fn new(buffer: []u8, reader: *Io.Reader) Input {
        return .{
            .buffer = buffer,
            .length = 0,
            .cursor = 0,
            .reader = reader,
        };
    }

    fn readByte(input: *Input) !?u8 {
        var char: u8 = undefined;
        input.reader.readSliceAll(@ptrCast(&char)) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return error.ReadFailed,
        };
        return char;
    }

    fn readCommand(input: *Input) ![]const u8 {
        const prompt = "> ";

        while (true) {
            assert(input.cursor <= input.length);

            std.debug.print("\r\x1b[K", .{});
            std.debug.print(prompt, .{});
            std.debug.print("{s}", .{input.buffer[0..input.length]});
            std.debug.print("\x1b[{}G", .{input.cursor + prompt.len + 1});

            const char = try input.readByte() orelse
                break;

            switch (char) {
                '\n' => break,

                control_code.bs,
                control_code.del,
                => if (input.cursor > 0) {
                    // Shift characters down
                    if (input.cursor < input.length) {
                        for (input.cursor..input.length) |i| {
                            input.buffer[i - 1] = input.buffer[i];
                        }
                    }
                    input.cursor -= 1;
                    input.length -= 1;
                },

                control_code.esc => {
                    if (try input.readByte() == '[') {
                        const command = try input.readByte() orelse
                            break;
                        switch (command) {
                            'C' => if (input.cursor < input.length) {
                                input.cursor += 1;
                            },
                            'D' => if (input.cursor > 0) {
                                input.cursor -= 1;
                            },
                            else => {},
                        }
                    }
                },

                0x20...0x7e => if (input.length < input.buffer.len) {
                    input.buffer[input.length] = char;
                    input.length += 1;
                    input.cursor += 1;
                },

                else => {},
            }
        }

        std.debug.print("\n", .{});

        return input.buffer[0..input.length];
    }
};

fn readCommand(debugger: *Debugger, runtime: *Runtime, buffer: []u8) ![]const u8 {
    _ = debugger;

    try runtime.tty.enableRawMode();

    var input: Input = .new(buffer, runtime.reader);

    const line = try input.readCommand();

    try runtime.tty.disableRawMode();

    return line;
}
