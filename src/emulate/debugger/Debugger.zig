const Debugger = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Traps = @import("../../Traps.zig");
const Reporter = @import("../../report/Reporter.zig");
const Air = @import("../../compile/Air.zig");
const Span = @import("../../compile/Span.zig");
const Parser = @import("../../compile/parse/Parser.zig");
const Runtime = @import("../Runtime.zig");
const Instruction = @import("../decode.zig").Instruction;
const Input = @import("Input.zig");
const Command = @import("Command.zig");
const parse = @import("parse.zig");

status: Status,
instruction_count: usize,
should_echo_pc: bool,
halt_address: ?u16,
breakpoints: Breakpoints,

current_line: []const u8,
input: Input,

initial_state: ?Runtime.State,
assembly: ?Assembly,
traps: *const Traps,
reporter: *Reporter,

pub const Assembly = struct {
    air: *const Air,
    source: []const u8,
};

const Breakpoints = struct {
    entries: std.ArrayList(u16),
    gpa: Allocator,

    pub fn init(gpa: Allocator) Breakpoints {
        return .{ .entries = .empty, .gpa = gpa };
    }

    pub fn deinit(breakpoints: *Breakpoints) void {
        breakpoints.entries.deinit(breakpoints.gpa);
    }

    pub fn insert(breakpoints: *Breakpoints, address: u16) error{OutOfMemory}!bool {
        for (breakpoints.entries.items) |breakpoint| {
            if (breakpoint == address)
                return false;
        }
        // TODO: Sorted insert
        try breakpoints.entries.append(breakpoints.gpa, address);
        return true;
    }

    pub fn remove(breakpoints: *Breakpoints, address: u16) bool {
        // PERF: Make better
        const length = breakpoints.entries.items.len;
        var i: usize = 0;
        while (i < breakpoints.entries.items.len) {
            if (breakpoints.entries.items[i] != address)
                continue;
            _ = breakpoints.entries.orderedRemove(i);
            i += 1;
        }
        return length > breakpoints.entries.items.len;
    }
};

const Status = union(enum) {
    inactive,
    get_action,
    step_over: struct { return_address: u16 },
    step_into: struct { count: u32 },
    step_out,
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
    command_buffer: []u8,
    assembly: ?Assembly,
    traps: *const Traps,
    reporter: *Reporter,
) Debugger {
    return .{
        .status = .get_action,
        .instruction_count = 0,
        .should_echo_pc = true,
        .halt_address = null,
        .breakpoints = .init(gpa),
        .current_line = "",
        .input = .init(gpa, reader, writer, command_buffer),
        .initial_state = null,
        .assembly = assembly,
        .traps = traps,
        .reporter = reporter,
    };
}

pub fn deinit(debugger: *Debugger, gpa: Allocator) void {
    debugger.breakpoints.deinit();
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
        return null;

    try runtime.ensureWriterNewline();

    if (debugger.isHalted(runtime))
        debugger.should_echo_pc = false
    else
        debugger.halt_address = null;

    switch (try debugger.nextAction(runtime)) {
        .proceed => {},
        .disable_debugger => {
            debugger.status = .inactive;
            return if (debugger.isHalted(runtime)) .@"break" else .@"continue";
        },
        .stop_runtime => {
            return .@"break";
        },
    }

    if (debugger.isHalted(runtime)) {
        try debugger.printLine("Currently halted at 0x{x:04}.", .{runtime.state.pc});
        debugger.status = .get_action;
        return .@"continue";
    }

    debugger.instruction_count += 1;

    return null;
}

fn printLine(debugger: *Debugger, comptime fmt: []const u8, args: anytype) !void {
    try debugger.input.writer.print("\x1b[34m", .{});
    try debugger.input.writer.print("| " ++ fmt ++ "\n", args);
    try debugger.input.writer.print("\x1b[0m", .{});
}

pub fn catchHalt(debugger: *Debugger, runtime: *Runtime) error{WriteFailed}!Runtime.Control {
    if (debugger.status == .inactive)
        return .@"break";

    // PC was incremented after decoding instruction; reverse that
    runtime.state.pc -= 1;
    try debugger.printLine("Program halted at 0x{x:04}.", .{runtime.state.pc});
    debugger.status = .get_action;
    debugger.halt_address = runtime.state.pc;
    return .@"continue";
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
                if (debugger.instruction_count > 1)
                    try debugger.printLine("Reached end of subroutine.", .{});
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
            .step_out => {
                const instruction = getNextInstruction(runtime);
                if (instruction == .ret_rets) {
                    try debugger.printLine("Reached end of subroutine.", .{});
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

fn getNextInstruction(runtime: *const Runtime) ?enum { ret_rets } {
    const word = runtime.state.memory[runtime.state.pc];
    const instruction = Instruction.decode(word) catch
        return null;
    switch (instruction) {
        .jmp_ret => |operands| if (operands.base == 7)
            return .ret_rets,
        .pop_push_rets_call => |variant| if (variant == .rets)
            return .ret_rets,
        else => {},
    }
    return null;
}

fn tryNextAction(debugger: *Debugger, runtime: *Runtime) !?Action {
    assert(debugger.status == .get_action);

    if (debugger.instruction_count > 0)
        try debugger.printLine("Executed {} instruction{s}.", .{
            debugger.instruction_count,
            if (debugger.instruction_count == 1) "" else "s",
        });
    if (debugger.should_echo_pc)
        try debugger.printLine("Program counter is at 0x{x:04}.", .{
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
    try runtime.writer.flush();
    return action;
}

fn runCommand(
    debugger: *Debugger,
    runtime: *Runtime,
    command: Command,
    source: []const u8,
) !?Action {
    switch (command.value) {
        .help => {
            try debugger.input.writer.print("\x1b[34m", .{});
            try runtime.writer.writeAll(@embedFile("help.txt"));
            try debugger.input.writer.print("\x1b[0m", .{});
        },

        .quit => return .disable_debugger,
        .exit => return .stop_runtime,

        .reset => {
            const state = debugger.initial_state orelse {
                try debugger.reporter.report(.debugger_any_err, .{
                    .code = error.NoInitialState,
                    .span = command.tag,
                }).abort();
            };
            runtime.state.copyFrom(state);
            try debugger.printLine("Reset registers and memory to initial state.", .{});
            debugger.should_echo_pc = true;
        },

        .registers => {
            try debugger.input.writer.print("\x1b[34m", .{});
            try runtime.printRegisters();
            try debugger.input.writer.print("\x1b[0m", .{});
        },

        .@"continue" => {
            debugger.status = .@"continue";
            debugger.should_echo_pc = true;
            if (!debugger.isHalted(runtime))
                try debugger.printLine("Continuing program execution...", .{});
        },

        .print => |arguments| {
            switch (try debugger.resolveLocation(runtime, arguments.location, source)) {
                .register => |register| {
                    try debugger.printLine("Register R{}:", .{register});
                    try debugger.input.writer.print("\x1b[34m", .{});
                    try runtime.printInteger(runtime.state.registers[register]);
                    try debugger.input.writer.print("\x1b[0m", .{});
                },
                .address => |address| {
                    try debugger.printLine("Memory at address 0x{x:04}:", .{address});
                    try debugger.input.writer.print("\x1b[34m", .{});
                    try runtime.printInteger(runtime.state.memory[address]);
                    try debugger.input.writer.print("\x1b[0m", .{});
                },
            }
        },

        .move => |arguments| {
            switch (try debugger.resolveLocation(runtime, arguments.location, source)) {
                .register => |register| {
                    runtime.state.registers[register] = arguments.value.value;
                    try debugger.printLine(
                        "| Updated register R{} to 0x{x:04}.n",
                        .{ register, arguments.value.value },
                    );
                },
                .address => |address| {
                    try debugger.ensureUserAddress(address, arguments.location.span);
                    runtime.state.memory[address] = arguments.value.value;
                    try debugger.printLine(
                        "| Updated memory at address 0x{x:04} to 0x{x:04}.\n",
                        .{ address, arguments.value.value },
                    );
                },
            }
        },

        .goto => |arguments| {
            const address = try debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            );
            try debugger.ensureUserAddress(address, arguments.location.span);
            runtime.state.pc = address;
            try debugger.printLine("Set program counter to 0x{x:04}.", .{address});
            // debugger.should_echo_pc = true;
        },

        .assembly => |arguments| {
            const assembly = try debugger.getAssembly(command.tag);
            const address = try debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            );

            const line = try debugger.getAssemblyLine(&assembly, address, arguments.location.span);

            var reporter = debugger.copyReporter(assembly.source);
            reporter.report(.debugger_any_info, .{
                .code = error.ShowAssembly,
                .span = line.span,
            }).proceed();
        },

        .eval => |arguments| {
            const assembly = try debugger.getAssembly(command.tag);
            try debugger.evalCommand(runtime, assembly, arguments.instruction, source);
        },

        .echo => |arguments| {
            try debugger.printLine("[{s}]\n", .{arguments.string.view(source)});
        },

        .step_over => {
            debugger.status = .{ .step_over = .{
                .return_address = runtime.state.pc + 1,
            } };
            debugger.should_echo_pc = true;
            // Don't print message here, we can't know if next instruction will change PC.
        },

        .step_into => |arguments| {
            debugger.status = .{ .step_into = .{
                .count = arguments.count.value - 1,
            } };
            debugger.should_echo_pc = true;
        },

        .step_out => {
            debugger.status = .step_out;
            debugger.should_echo_pc = true;
            if (!debugger.isHalted(runtime))
                try debugger.printLine("Finishing subroutine execution...", .{});
        },

        .break_list => {
            if (debugger.breakpoints.entries.items.len == 0) {
                try debugger.printLine("No breakpoints exist", .{});
            } else {
                try debugger.printLine("Breakpoints:", .{});
                for (debugger.breakpoints.entries.items) |address| {
                    try debugger.printLine("- 0x{x:04}", .{address});
                }
            }
        },

        .break_add => |arguments| {
            const address = try debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            );
            try debugger.ensureUserAddress(address, arguments.location.span);
            const inserted = debugger.breakpoints.insert(address) catch {
                try debugger.reporter.report(.debugger_any_err, .{
                    .code = error.OutOfMemory,
                    .span = command.tag,
                }).abort();
            };
            if (inserted)
                try debugger.printLine("Added breakpoint at 0x{x:04}", .{address})
            else
                try debugger.printLine("Breakpoint already exists at 0x{x:04}", .{address});
        },

        .break_remove => |arguments| {
            const address = try debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            );
            const removed = debugger.breakpoints.remove(address);
            if (removed)
                try debugger.printLine("Removed Breakpoint at 0x{x:04}", .{address})
            else
                try debugger.printLine("No breakpoint exists at 0x{x:04}", .{address});
        },
    }

    return null;
}

fn evalCommand(
    debugger: *Debugger,
    runtime: *Runtime,
    assembly: Assembly,
    span: Span,
    source: []const u8,
) (Runtime.IoError || error{Reported})!void {
    const line = span.view(source);

    const asm_instr = try debugger.parseInstructionLine(
        assembly,
        line,
        runtime.state.pc - assembly.air.origin,
    );

    const runtime_instr = Instruction.decode(asm_instr.encode()) catch
        // Any encoded instruction must be valid to decode
        unreachable;

    runtime.runInstruction(runtime_instr) catch |err| switch (err) {
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        error.TermiosFailed,
        => |err2| return err2,

        // TODO: Add details depending on error code
        else => try debugger.reporter.report(.debugger_any_err, .{
            .code = err,
            .span = span,
        }).abort(),
    };
}

fn parseInstructionLine(
    debugger: *const Debugger,
    assembly: Assembly,
    line: []const u8,
    index: usize,
) error{Reported}!Parser.Instruction {
    var reporter = debugger.copyReporter(line);
    var parser = Parser.new(debugger.traps, line, &reporter) orelse
        return error.Reported;

    var instruction = try parser.parseInstructionLine();
    try parser.resolveInstructionLabel(assembly.air, assembly.source, &instruction, index);
    return instruction;
}

fn copyReporter(debugger: *const Debugger, source: []const u8) Reporter {
    var reporter = debugger.reporter.copyImplementation();
    reporter.source = source;

    var policies: Reporter.Policies = .{
        .extension = reporter.options.policies.extension,
        .smell = reporter.options.policies.smell,
        .style = .permit_all,
    };

    reporter.options.strictness = .normal;
    reporter.options.policies = &policies;

    return reporter;
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

fn resolveLocation(
    debugger: *Debugger,
    runtime: *Runtime,
    location: Command.Spanned(Command.Location),
    source: []const u8,
) error{Reported}!union(enum) { register: u3, address: u16 } {
    switch (location.value) {
        .register => |register| {
            return .{ .register = register };
        },
        .memory => |memory| {
            const address = try debugger.resolveMemoryLocation(runtime, memory, location.span, source);
            return .{ .address = address };
        },
    }
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

    try runtime.ensureWriterNewline();
    try runtime.tty.enableRawMode();
    const line = debugger.input.readLine();
    try runtime.tty.disableRawMode();
    return line;
}
