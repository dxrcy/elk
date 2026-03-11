const Debugger = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../../compile/Air.zig");
const Span = @import("../../compile/Span.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const Command = @import("Command.zig");
const parseCommand = @import("parse.zig").parseCommand;

input: Input,
status: Status,

assembly: ?Assembly,
reporter: *Reporter,

pub const Assembly = struct {
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
                return try debugger.tryNextAction(runtime) orelse
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

fn tryNextAction(debugger: *Debugger, runtime: *Runtime) !?Action {
    assert(debugger.status == .get_action);

    var command_buffer: [20]u8 = undefined;
    debugger.input.editor.setBuffer(&command_buffer);

    const command_string = debugger.readCommand(runtime) catch |err| switch (err) {
        else => |err2| return err2,
        error.EndOfStream => {
            return .disable_debugger;
        },
    };

    debugger.reporter.source = command_string;

    const command = parseCommand(command_string, debugger.reporter) catch |err| switch (err) {
        error.Reported => return null,
    } orelse
        return null; // No tokens lexed

    const action = debugger.runCommand(runtime, command, command_string) catch |err| switch (err) {
        error.Reported => return null,
        else => |err2| return err2,
    };
    try runtime.writer.interface.flush();
    return action;
}

fn runCommand(
    debugger: *Debugger,
    runtime: *Runtime,
    command: Command,
    source: []const u8,
) !?Action {
    switch (command.value) {
        // TODO: Implement all commands
        else => {
            debugger.reporter.report(.debugger_any_err, .{
                .code = error.UnimplementedCommand,
                .span = command.tag,
            }).abort() catch
                return null;
        },

        .quit => return .disable_debugger,
        .exit => return .stop_runtime,

        .help => {
            try runtime.writer.interface.writeAll(@embedFile("help.txt"));
        },

        .registers => {
            try runtime.printRegisters();
        },

        .print => |arguments| switch (arguments.location.value) {
            .register => |register| {
                try runtime.writer.interface.print("Register R{}:\n", .{register});
                try runtime.printInteger(runtime.state.registers[register]);
            },
            .memory => |memory| {
                const address = debugger.resolveMemoryLocation(
                    runtime,
                    memory,
                    arguments.location.span,
                    source,
                ) catch
                    return null;
                try runtime.writer.interface.print("Memory at address 0x{x:04}:\n", .{address});
                try runtime.printInteger(runtime.state.memory[address]);
            },
        },

        .move => |arguments| switch (arguments.location.value) {
            .register => |register| {
                runtime.state.registers[register] = arguments.value.value;
                try runtime.writer.interface.print(
                    "Updated register R{} to 0x{x:04}.n",
                    .{ register, arguments.value.value },
                );
            },
            .memory => |memory| {
                const address = debugger.resolveMemoryLocation(
                    runtime,
                    memory,
                    arguments.location.span,
                    source,
                ) catch
                    return null;
                runtime.state.memory[address] = arguments.value.value;
                try runtime.writer.interface.print(
                    "Updated memory at address 0x{x:04} to 0x{x:04}.\n",
                    .{ address, arguments.value.value },
                );
            },
        },

        .goto => |arguments| {
            const address = debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            ) catch
                return null;
            runtime.state.pc = address;
            try runtime.writer.interface.print("Set program counter to 0x{x:04}.\n", .{address});
        },

        .assembly => |arguments| {
            const assembly = try debugger.getAssembly(command.tag);
            const address = debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            ) catch return null;

            // FIXME: Handle overflow
            const index = address - assembly.air.origin;
            // FIXME: Handle OOB
            const line = assembly.air.lines.items[index];

            // HACK: What the hell is this
            const reporter = debugger.reporter;
            reporter.source = assembly.source;

            reporter.report(.debugger_any_info, .{
                .code = error.ShowAssembly,
                .span = line.span,
            }).proceed();
        },

        .echo => |arguments| {
            try runtime.writer.interface.print("[{s}]\n", .{arguments.string.view(source)});
        },

        .step_into => |arguments| {
            debugger.status = .{ .step_into = .{
                .count = arguments.count.value - 1,
            } };
        },
    }

    return null;
}

fn resolveMemoryLocation(
    debugger: *const Debugger,
    runtime: *const Runtime,
    memory: Command.Location.Memory,
    span: Span,
    source: []const u8,
) error{Reported}!u16 {
    switch (memory) {
        .address => |address| return address,

        .pc_offset => |pc_offset| {
            const combined = @as(isize, runtime.state.pc) + pc_offset;

            return std.math.cast(u16, combined) orelse {
                try debugger.reporter.report(.debugger_any_err, .{
                    .code = error.AddressTooLarge,
                    .span = span,
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
                    .span = span,
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
