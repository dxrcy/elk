const Debugger = @This();

const std = @import("std");
const Io = std.Io;

const Reporter = @import("../../report/Reporter.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const parseCommand = @import("parse.zig").parseCommand;

input: Input,
io: Io,

pub fn new(io: Io, reader: *Io.Reader, writer: *Io.Writer) Debugger {
    return .{
        .input = .new(reader, writer),
        .io = io,
    };
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    std.debug.print("[INVOKE DEBUGGER]\n", .{});

    var command_buffer: [20]u8 = undefined;

    var reporter_buffer: [1024]u8 = undefined;
    var reporter_writer = Io.File.stderr().writer(debugger.io, &reporter_buffer);
    var reporter_impl = Reporter.Stderr.new(&reporter_writer.interface);
    var reporter = reporter_impl.interface();

    while (true) {
        const command_string = try debugger.readCommand(runtime, &command_buffer);

        reporter_impl.source = command_string;

        const command = parseCommand(command_string) catch |err| {
            reporter.report(.debugger_any, .{
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
