const Debugger = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../../compile/Air.zig");
const Span = @import("../../compile/Span.zig");
const Runtime = @import("../Runtime.zig");
const Input = @import("Input.zig");
const Command = @import("Command.zig");
const parse = @import("parse.zig");

status: Status,
instruction_count: usize,
should_echo_pc: bool,
halt_address: ?u16,

current_line: []const u8,
initial_state: ?Runtime.State,
assembly: ?Assembly,
input: Input,
reporter: *Reporter,

pub const Assembly = struct {
    air: *const Air,
    source: []const u8,
};

const Status = union(enum) {
    inactive,
    get_action,
    step_over: struct { return_address: u16 },
    step_into: struct { count: u32 },
    @"continue",
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
    command_buffer: []u8,
    assembly: ?Assembly,
) Debugger {
    return .{
        .status = .get_action,
        .instruction_count = 0,
        .should_echo_pc = true,
        .halt_address = null,
        .current_line = "",
        .initial_state = null,
        .assembly = assembly,
        .input = .init(gpa, reader, writer, command_buffer),
        .reporter = reporter,
    };
}

pub fn deinit(debugger: *Debugger, gpa: Allocator) void {
    debugger.input.deinit();
    if (debugger.initial_state) |state|
        state.deinit(gpa);
}

pub fn initState(
    debugger: *Debugger,
    gpa: Allocator,
    runtime: *const Runtime,
) error{OutOfMemory}!void {
    debugger.initial_state = try .init(gpa);
    debugger.initial_state.?.copyFrom(runtime.state);
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    if (debugger.status == .inactive)
        return .@"continue";

    try runtime.writer.ensureNewline();

    if (debugger.isHalted(runtime))
        debugger.should_echo_pc = false
    else
        debugger.halt_address = null;

    switch (try debugger.nextAction(runtime)) {
        .proceed => {},
        .disable_debugger => {
            debugger.status = .inactive;
            return .@"continue";
        },
        .stop_runtime => {
            return .@"break";
        },
    }

    if (debugger.isHalted(runtime)) {
        try runtime.writer.interface.print("| Currently halted at 0x{x:04}.\n", .{runtime.state.pc});
        debugger.status = .get_action;
        return .@"continue";
    }

    debugger.instruction_count += 1;

    return null;
}

pub fn catchHalt(debugger: *Debugger, runtime: *Runtime) error{WriteFailed}!void {
    // PC was incremented after decoding instruction; reverse that
    runtime.state.pc -= 1;
    try runtime.writer.interface.print("| Program halted at 0x{x:04}.\n", .{runtime.state.pc});
    debugger.status = .get_action;
    debugger.halt_address = runtime.state.pc;
}

fn isHalted(debugger: *const Debugger, runtime: *const Runtime) bool {
    return debugger.halt_address == runtime.state.pc;
}

fn nextAction(debugger: *Debugger, runtime: *Runtime) !Action {
    while (true) {
        switch (debugger.status) {
            .inactive => unreachable,
            .get_action => {
                return try debugger.tryNextAction(runtime) orelse
                    continue;
            },
            .step_over => |*info| {
                if (runtime.state.pc != info.return_address)
                    return .proceed;
                std.log.debug("DONE", .{});
                debugger.status = .get_action;
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
            .@"continue" => {
                return .proceed;
            },
        }
        comptime unreachable;
    }
}

fn tryNextAction(debugger: *Debugger, runtime: *Runtime) !?Action {
    assert(debugger.status == .get_action);

    if (debugger.instruction_count > 0)
        try runtime.writer.interface.print("| Executed {} instruction{s}.\n", .{
            debugger.instruction_count,
            if (debugger.instruction_count == 1) "" else "s",
        });
    if (debugger.should_echo_pc)
        try runtime.writer.interface.print("| Program counter is at 0x{x:04}.\n", .{
            runtime.state.pc,
        });

    debugger.instruction_count = 0;
    debugger.should_echo_pc = false;

    const command_string = debugger.readCommand(runtime) catch |err| switch (err) {
        else => |err2| return err2,
        error.EndOfStream => {
            return .disable_debugger;
        },
    };

    debugger.reporter.source = command_string;

    const command = parse.parseCommand(command_string, debugger.reporter) catch |err| switch (err) {
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
        else => {
            debugger.reporter.report(.debugger_any_err, .{
                .code = error.UnimplementedCommand,
                .span = command.tag,
            }).abort() catch
                return null;
        },

        .help => {
            try runtime.writer.interface.writeAll(@embedFile("help.txt"));
        },

        .quit => return .disable_debugger,
        .exit => return .stop_runtime,

        .reset => {
            const state = debugger.initial_state orelse {
                debugger.reporter.report(.debugger_any_err, .{
                    .code = error.NoInitialState,
                    .span = command.tag,
                }).abort() catch
                    return null;
            };
            runtime.state.copyFrom(state);
            try runtime.writer.interface.print("| Reset registers and memory to initial state.\n", .{});
            debugger.should_echo_pc = true;
        },

        .registers => {
            try runtime.printRegisters();
        },

        .@"continue" => {
            debugger.status = .@"continue";
            debugger.should_echo_pc = true;
            if (!debugger.isHalted(runtime))
                try runtime.writer.interface.print("| Continuing program execution...\n", .{});
        },

        .print => |arguments| switch (arguments.location.value) {
            .register => |register| {
                try runtime.writer.interface.print("| Register R{}:\n", .{register});
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
                try runtime.writer.interface.print("| Memory at address 0x{x:04}:\n", .{address});
                try runtime.printInteger(runtime.state.memory[address]);
            },
        },

        .move => |arguments| switch (arguments.location.value) {
            .register => |register| {
                runtime.state.registers[register] = arguments.value.value;
                try runtime.writer.interface.print(
                    "| Updated register R{} to 0x{x:04}.n",
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
                debugger.ensureUserAddress(address, arguments.location.span) catch
                    return null;
                runtime.state.memory[address] = arguments.value.value;
                try runtime.writer.interface.print(
                    "| Updated memory at address 0x{x:04} to 0x{x:04}.\n",
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
            debugger.ensureUserAddress(address, arguments.location.span) catch
                return null;
            runtime.state.pc = address;
            try runtime.writer.interface.print("| Set program counter to 0x{x:04}.\n", .{address});
            // debugger.should_echo_pc = true;
        },

        .assembly => |arguments| {
            const assembly = try debugger.getAssembly(command.tag);
            const address = debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            ) catch return null;

            const line = debugger.getAssemblyLine(&assembly, address, arguments.location.span) catch
                return null;

            // This is NOT a hack, I promise.
            var reporter = debugger.reporter.copyImplementation();
            reporter.source = assembly.source;

            reporter.report(.debugger_any_info, .{
                .code = error.ShowAssembly,
                .span = line.span,
            }).proceed();
        },

        // TODO:
        // .eval => {},

        .echo => |arguments| {
            try runtime.writer.interface.print("[{s}]\n", .{arguments.string.view(source)});
        },

        .step_over => {
            debugger.status = .{ .step_over = .{
                .return_address = runtime.state.pc + 1,
            } };
            debugger.should_echo_pc = true;
        },

        .step_into => |arguments| {
            debugger.status = .{ .step_into = .{
                .count = arguments.count.value - 1,
            } };
            debugger.should_echo_pc = true;
        },

        // TODO:
        // .step_out => {},

        // TODO:
        // .break_list => {},

        // TODO:
        // .break_add => {},

        // TODO:
        // .break_remove => {},
    }

    return null;
}

fn getAssemblyLine(
    debugger: *Debugger,
    assembly: *const Assembly,
    address: u16,
    span: Span,
) error{Reported}!*const Air.Line {
    try debugger.ensureUserAddress(address, span);
    // Overflow is not possible since address is in user memory
    const index = address - assembly.air.origin;
    if (index >= assembly.air.lines.items.len) {
        try debugger.reporter.report(.debugger_any_err, .{
            .code = error.AddressNotInAssembly,
            .span = span,
        }).abort();
    }
    return &assembly.air.lines.items[index];
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

fn ensureUserAddress(debugger: *Debugger, address: u16, span: Span) error{Reported}!void {
    switch (address) {
        Runtime.USER_MEMORY_START...Runtime.USER_MEMORY_END => {},
        else => {
            try debugger.reporter.report(.debugger_any_err, .{
                .code = error.AddressNotInUserMemory,
                .span = span,
            }).abort();
        },
    }
}

fn readCommand(debugger: *Debugger, runtime: *Runtime) ![]const u8 {
    const line = try debugger.readInputLine(runtime);
    const first, const rest = parse.splitCommandLine(line);
    debugger.current_line = rest;
    return first;
}

fn readInputLine(debugger: *Debugger, runtime: *Runtime) ![]const u8 {
    if (debugger.current_line.len > 0)
        return debugger.current_line;

    try runtime.writer.ensureNewline();
    try runtime.tty.enableRawMode();
    const line = debugger.input.readLine();
    try runtime.tty.disableRawMode();
    return line;
}
