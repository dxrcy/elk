const Debugger = @This();

const std = @import("std");
const Io = std.Io;

const Reporter = @import("../../report/Reporter.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const parseCommand = @import("parse.zig").parseCommand;

input: Input,
reporter: *Reporter,

pub fn init(
    gpa: std.mem.Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    reporter: *Reporter,
) Debugger {
    return .{
        .input = .init(gpa, reader, writer),
        .reporter = reporter,
    };
}

pub fn deinit(debugger: *Debugger) void {
    debugger.input.deinit();
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    var command_buffer: [20]u8 = undefined;

    while (true) {
        const command_string = try debugger.readCommand(runtime, &command_buffer);

        debugger.reporter.source = command_string;

        const command = parseCommand(command_string, debugger.reporter) catch |err| switch (err) {
            error.Reported => continue,
            // TODO: Remove once all command parsing is implemented
            error.Unimplemented => continue,
        } orelse
            continue; // No tokens lexed

        std.debug.print("Command: {}\n", .{command});
    }
}

fn readCommand(debugger: *Debugger, runtime: *Runtime, buffer: []u8) ![]const u8 {
    try runtime.tty.enableRawMode();
    const line = try debugger.input.readLine(buffer);
    try runtime.tty.disableRawMode();
    debugger.input.clear();
    return line;
}
