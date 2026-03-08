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
    std.debug.print("[INVOKE DEBUGGER]\n", .{});

    var command_buffer: [20]u8 = undefined;

    while (true) {
        const command_string = try debugger.readCommand(runtime, &command_buffer);

        debugger.reporter.source = command_string;

        const command = parseCommand(command_string) catch |err| {
            debugger.reporter.report(.debugger_any, .{
                .code = err,
                .span = .{ .offset = 0, .len = command_string.len },
            }).abort() catch
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
