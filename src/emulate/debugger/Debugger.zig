const Debugger = @This();

const std = @import("std");
const Io = std.Io;

const Reporter = @import("../../report/Reporter.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const parseCommand = @import("parse.zig").parseCommand;

input: Input,
reporter: *Reporter,

pub fn new(reader: *Io.Reader, writer: *Io.Writer, reporter: *Reporter) Debugger {
    return .{
        .input = .new(reader, writer),
        .reporter = reporter,
    };
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    var command_buffer: [20]u8 = undefined;

    while (true) {
        const command_string = try debugger.readCommand(runtime, &command_buffer);

        const command = parseCommand(command_string) catch |err| {
            std.debug.print("Error: {t}\n", .{err});
            continue;
        };

        std.debug.print("Command: {}\n", .{command});
        return null;
    }
}

fn readCommand(debugger: *Debugger, runtime: *Runtime, buffer: []u8) ![]const u8 {
    try runtime.tty.enableRawMode();
    const line = try debugger.input.readLine(buffer);
    try runtime.tty.disableRawMode();
    debugger.input.clear();
    return line;
}
