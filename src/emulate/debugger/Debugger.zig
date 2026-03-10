const Debugger = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../../compile/Air.zig");
const Span = @import("../../compile/Span.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const Command = @import("command.zig").Command;
const parseCommand = @import("parse.zig").parseCommand;

input: Input,
status: Status,

assembly: ?Assembly,
reporter: *Reporter,

const Assembly = struct {
    air: *const Air,
    source: []const u8,
};

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
    assembly: ?Assembly,
) Debugger {
    return .{
        .input = .init(gpa, reader, writer),
        .status = .get_action,
        .assembly = assembly,
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
                return try debugger.runCommandLoop(runtime) orelse
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

fn runCommandLoop(debugger: *Debugger, runtime: *Runtime) !?Action {
    assert(debugger.status == .get_action);

    var command_buffer: [20]u8 = undefined;
    debugger.input.editor.setBuffer(&command_buffer);

    while (true) {
        const command_string = debugger.readCommand(runtime) catch |err| switch (err) {
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

        const action_opt = try debugger.runCommand(runtime, command, command_string);
        try runtime.writer.interface.flush();
        if (action_opt) |action|
            return action;
    }
}

fn runCommand(
    debugger: *Debugger,
    runtime: *Runtime,
    command: Command,
    source: []const u8,
) !?Action {
    switch (command) {
        // TODO: Implement all commands
        else => {
            std.debug.print("Command: {}\n", .{command});
        },

        .quit => return .disable_debugger,
        .exit => return .stop_runtime,

        .help => {
            try runtime.writer.interface.writeAll(@embedFile("help.txt"));
        },

        .registers => {
            try runtime.printRegisters();
        },

        .print => |arguments| switch (arguments.location) {
            .register => |register| {
                try runtime.writer.interface.print("Register R{}:\n", .{register});
                try runtime.printInteger(runtime.registers[register]);
            },
            .memory => |memory| {
                const address = debugger.resolveMemoryLocation(runtime, memory, source) catch
                    return null;
                try runtime.writer.interface.print("Memory at address 0x{x:04}:\n", .{address});
                try runtime.printInteger(runtime.memory[address]);
            },
        },

        .move => |arguments| switch (arguments.location) {
            .register => |register| {
                runtime.registers[register] = arguments.value;
                try runtime.writer.interface.print("Updated register R{} to 0x{x:04}.n", .{ register, arguments.value });
            },
            .memory => |memory| {
                const address = debugger.resolveMemoryLocation(runtime, memory, source) catch
                    return null;
                runtime.memory[address] = arguments.value;
                try runtime.writer.interface.print("Updated memory at address 0x{x:04} to 0x{x:04}.\n:", .{ address, arguments.value });
            },
        },

        .goto => |arguments| {
            const address = debugger.resolveMemoryLocation(runtime, arguments.location, source) catch
                return null;
            runtime.pc = address;
            try runtime.writer.interface.print("Set program counter to 0x{x:04}.\n:", .{address});
        },

        .step_into => |arguments| {
            debugger.status = .{ .step_into = .{
                .count = arguments.count - 1,
            } };
        },
    }

    return null;
}

fn resolveMemoryLocation(
    debugger: *const Debugger,
    runtime: *const Runtime,
    memory: Command.Location.Memory,
    source: []const u8,
) error{Reported}!u16 {
    switch (memory) {
        .address => |address| return address,

        .pc_offset => |pc_offset| {
            const combined = @as(isize, runtime.pc) + pc_offset;

            return std.math.cast(u16, combined) orelse {
                try debugger.reporter.report(.debugger_any_err, .{
                    .code = error.AddressTooLarge,
                    // TODO: Include proper span
                    .span = .emptyAt(0),
                }).abort();
            };
        },

        .label => |label| {
            const assembly = try debugger.getAssembly(label.name);
            const address = try debugger.resolveLabelIndex(assembly, label.name, source);

            const combined = @as(isize, @intCast(address + assembly.air.origin)) + label.offset;

            return std.math.cast(u16, combined) orelse {
                try debugger.reporter.report(.debugger_any_err, .{
                    .code = error.AddressTooLarge,
                    // TODO: Include proper span
                    .span = label.name,
                }).abort();
            };
        },
    }
}

fn resolveLabelIndex(
    debugger: *const Debugger,
    assembly: Assembly,
    label: Span,
    source: []const u8,
) error{Reported}!usize {
    const string = label.view(source);

    if (assembly.air.findLabelDefinition(string, .sensitive, assembly.source)) |result|
        return result[0];

    if (assembly.air.findLabelDefinition(string, .insensitive, assembly.source)) |result| {
        debugger.reporter.report(.debugger_any_warn, .{
            .code = error.IncorrectLabelCase,
            .span = label,
        }).proceed();
        return result[0];
    }

    try debugger.reporter.report(.debugger_any_err, .{
        .code = error.UndeclaredLabel,
        .span = label,
    }).abort();
}

fn getAssembly(debugger: *const Debugger, span: Span) error{Reported}!Assembly {
    return debugger.assembly orelse {
        try debugger.reporter.report(.debugger_any_err, .{
            .code = error.RequiresAssembly,
            .span = span,
        }).abort();
    };
}

fn readCommand(debugger: *Debugger, runtime: *Runtime) ![]const u8 {
    try runtime.writer.ensureNewline();
    try runtime.tty.enableRawMode();
    const line = debugger.input.readLine();
    try runtime.tty.disableRawMode();
    return line;
}
