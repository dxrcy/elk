const Debugger = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const parseCommand = @import("parse.zig").parseCommand;

input: Input,
status: Status,

reporter: *Reporter,

const Status = union(enum) {
    inactive,
    get_action,
    step_into: struct { count: u32 },
};

const Action = enum {
    proceed,
    disable_debugger,
    stop_runtime,
};

pub fn init(
    gpa: std.mem.Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    reporter: *Reporter,
) Debugger {
    return .{
        .input = .init(gpa, reader, writer),
        .status = .get_action,
        .reporter = reporter,
    };
}

pub fn deinit(debugger: *Debugger) void {
    debugger.input.deinit();
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    if (debugger.status == .inactive)
        return .@"continue";

    switch (try debugger.nextAction(runtime)) {
        .proceed => {
            return .@"continue";
        },
        .disable_debugger => {
            debugger.status = .inactive;
            return .@"continue";
        },
        .stop_runtime => {
            return .@"break";
        },
    }
}

fn nextAction(debugger: *Debugger, runtime: *Runtime) !Action {
    while (true) {
        switch (debugger.status) {
            .inactive => unreachable,
            .get_action => {
                return try debugger.runCommand(runtime) orelse
                    continue;
            },
            .step_into => |*info| {
                if (info.count > 0) {
                    info.count -= 1;
                } else {
                    debugger.status = .get_action;
                }
                return .proceed;
            },
        }
        comptime unreachable;
    }
}

fn runCommand(debugger: *Debugger, runtime: *Runtime) !?Action {
    assert(debugger.status == .get_action);

    var command_buffer: [20]u8 = undefined;

    while (true) {
        const command_string = debugger.readCommand(runtime, &command_buffer) catch |err| switch (err) {
            else => |err2| return err2,
            error.EndOfStream => {
                return .disable_debugger;
            },
        };

        debugger.reporter.source = command_string;

        const command = parseCommand(command_string, debugger.reporter) catch |err| switch (err) {
            error.Reported => continue,
            // TODO: Remove once all command parsing is implemented
            error.Unimplemented => continue,
        } orelse
            continue; // No tokens lexed

        switch (command) {
            // TODO: Implement all commands
            else => {
                std.debug.print("Command: {}\n", .{command});
            },

            .quit => return .disable_debugger,
            .exit => return .stop_runtime,

            .step_into => |arguments| {
                debugger.status = .{ .step_into = .{
                    .count = arguments.count - 1,
                } };
                return null;
            },
        }
    }
}

fn readCommand(debugger: *Debugger, runtime: *Runtime, buffer: []u8) ![]const u8 {
    try runtime.tty.enableRawMode();
    const line = debugger.input.readLine(buffer);
    try runtime.tty.disableRawMode();
    debugger.input.clear();
    return line;
}
