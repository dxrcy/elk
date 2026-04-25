const Debugger = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const reporting = @import("../../reporting/reporting.zig");
const Reporter = reporting.Primary;
const writeSpanContext = reporting.Sink.Fancy.writeSpanContext;
const Traps = @import("../../Traps.zig");
const Air = @import("../../compile/Air.zig");
const Span = @import("../../compile/Span.zig");
const Parser = @import("../../compile/parse/Parser.zig");
const Runtime = @import("../Runtime.zig");
const Instruction = @import("../decode.zig").Instruction;
const Command = @import("Command.zig");
const Breakpoints = @import("Breakpoints.zig");
const Input = @import("Input.zig");
const parse = @import("parse.zig");

state: struct {
    status: Status = .get_action,
    instruction_count: usize = 0,
    should_print_pc: bool = true,
    halt_address: ?u16 = null,
    current_breakpoint: ?u16 = null,
},

breakpoints: Breakpoints,
initial_state: ?Runtime.State,
assembly: ?Assembly,

current_line: []const u8,
input: Input,
writer: Writer,
traps: *const Traps,
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
    step_out,
    @"continue",
};

const Action = enum {
    proceed,
    disable_debugger,
    stop_runtime,
};

pub const Writer = struct {
    pub const color = 34;
    const prompt = "> ";

    inner: *Io.Writer,

    pub fn print(writer: *Writer, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        try writer.inner.print(fmt, args);
    }

    pub fn flush(writer: *Writer) error{WriteFailed}!void {
        try writer.inner.flush();
    }

    pub fn printLine(writer: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try writer.enableColor();
        try writer.print("| " ++ fmt ++ "\n", args);
        try writer.disableColor();
    }

    pub fn enableColor(writer: *Writer) !void {
        try writer.print("\x1b[{}m", .{color});
    }

    pub fn disableColor(writer: *Writer) !void {
        try writer.print("\x1b[0m", .{});
    }

    pub fn writePrompt(writer: *Writer, string: []const u8, cursor_opt: ?usize) !void {
        try writer.print("\r\x1b[K", .{});

        try writer.enableColor();
        try writer.print(prompt, .{});
        try writer.disableColor();

        const trimmed = std.mem.trim(u8, string, &std.ascii.whitespace);
        const semicolon = std.mem.findScalar(u8, trimmed, ';') orelse trimmed.len;
        const first = trimmed[0..semicolon];
        const rest = trimmed[semicolon..];

        try writer.print("{s}", .{first});
        if (rest.len > 0) {
            try writer.print("\x1b[2m", .{});
            try writer.print("{s}", .{rest});
            try writer.print("\x1b[0m", .{});
        }

        if (cursor_opt) |cursor|
            try writer.print("\x1b[{}G", .{cursor + prompt.len + 1});
    }
};

pub fn init(params: struct {
    io: Io,
    gpa: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    traps: *const Traps,
    reporter: *Reporter,
    command_buffer: []u8,
    assembly: ?Assembly = null,
    history_file: ?Io.File = null,
    initial_command_line: []const u8 = "",
}) error{OutOfMemory}!Debugger {
    const breakpoints: Breakpoints =
        if (params.assembly) |assembly|
            try .initFrom(params.gpa, assembly)
        else
            .init(params.gpa);

    const input: Input = .new(
        params.io,
        params.reader,
        params.history_file,
        .init(params.gpa, params.command_buffer),
    );

    return .{
        .state = .{},
        .breakpoints = breakpoints,
        .initial_state = null,
        .assembly = params.assembly,
        .current_line = params.initial_command_line,
        .input = input,
        .writer = .{ .inner = params.writer },
        .traps = params.traps,
        .reporter = params.reporter,
    };
}

pub fn deinit(debugger: *Debugger, gpa: Allocator) void {
    debugger.breakpoints.deinit();
    debugger.input.editor.deinit();
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

pub fn startMessage(debugger: *Debugger) !void {
    try debugger.writer.printLine("* Welcome to ELK Debugger *", .{});
    try debugger.writer.printLine("Type `help` for available commands", .{});
}

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?enum { @"continue", @"break" } {
    if (debugger.state.status == .inactive)
        return null;

    if (!debugger.canProceed(runtime))
        debugger.state.should_print_pc = false;
    if (!debugger.isHalted(runtime))
        debugger.state.halt_address = null;

    switch (try debugger.nextAction(runtime)) {
        .proceed => {},
        .disable_debugger => {
            debugger.state.status = .inactive;
            return if (debugger.isHalted(runtime)) .@"break" else .@"continue";
        },
        .stop_runtime => {
            return .@"break";
        },
    }

    if (debugger.isHalted(runtime)) {
        try runtime.ensureWriterNewline();
        try debugger.writer.printLine("Currently halted at 0x{x:04}.", .{runtime.state.pc});
        debugger.state.status = .get_action;
        return .@"continue";
    }

    if (debugger.isAtBreakpoint(runtime)) {
        try runtime.ensureWriterNewline();
        try debugger.writer.printLine("Currently on breakpoint at 0x{x:04}.", .{runtime.state.pc});
        debugger.state.current_breakpoint = runtime.state.pc;
        debugger.state.status = .get_action;
        return .@"continue";
    } else {
        debugger.state.current_breakpoint = null;
    }

    debugger.state.instruction_count += 1;

    return null;
}

pub fn catchEvent(
    debugger: *Debugger,
    event: (Runtime.Exception || error{Halt}),
    runtime: *Runtime,
) error{WriteFailed}!void {
    assert(debugger.state.status != .inactive);

    // PC was incremented after decoding instruction; reverse that
    runtime.state.pc -= 1;

    switch (event) {
        error.Halt => {},
        else => |exception| {
            debugger.reporter.report(.emulate_exception, .{
                .code = exception,
            }).abort() catch
                {};
        },
    }

    try debugger.triggerHalt(runtime);
}

fn triggerHalt(debugger: *Debugger, runtime: *Runtime) error{WriteFailed}!void {
    try runtime.ensureWriterNewline();
    try debugger.writer.printLine("Program halted at 0x{x:04}.", .{runtime.state.pc});
    debugger.state.status = .get_action;
    debugger.state.halt_address = runtime.state.pc;
}

fn canProceed(debugger: *const Debugger, runtime: *const Runtime) bool {
    return !debugger.isHalted(runtime) and !debugger.isAtBreakpoint(runtime);
}

fn isHalted(debugger: *const Debugger, runtime: *const Runtime) bool {
    return debugger.state.halt_address == runtime.state.pc;
}

fn isAtBreakpoint(debugger: *const Debugger, runtime: *const Runtime) bool {
    for (debugger.breakpoints.entries.items) |entry| {
        if (entry.address == runtime.state.pc and
            entry.address != debugger.state.current_breakpoint)
            return true;
    }
    return false;
}

fn nextAction(debugger: *Debugger, runtime: *Runtime) !Action {
    while (true) {
        switch (debugger.state.status) {
            .inactive => unreachable,
            .get_action => {
                try runtime.ensureWriterNewline();
                return try debugger.tryNextAction(runtime) orelse
                    continue;
            },
            .step_over => |*info| {
                if (runtime.state.pc != info.return_address)
                    return .proceed;
                try runtime.ensureWriterNewline();
                if (debugger.state.instruction_count > 1)
                    try debugger.writer.printLine("Reached end of subroutine.", .{});
                debugger.state.status = .get_action;
                continue;
            },
            .step_into => |*info| {
                if (info.count > 0) {
                    info.count -= 1;
                } else {
                    try runtime.ensureWriterNewline();
                    debugger.state.status = .get_action;
                }
                return .proceed;
            },
            .step_out => {
                const instruction = getNextInstruction(runtime);
                if (instruction == .ret_rets) {
                    try runtime.ensureWriterNewline();
                    try debugger.writer.printLine("Reached end of subroutine.", .{});
                    debugger.state.status = .get_action;
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
    assert(debugger.state.status == .get_action);
    assert(runtime.writer_is_newline);

    if (debugger.state.instruction_count > 0)
        try debugger.writer.printLine("Executed {} instruction{s}.", .{
            debugger.state.instruction_count,
            if (debugger.state.instruction_count == 1) "" else "s",
        });
    if (debugger.state.should_print_pc)
        try debugger.writer.printLine("Program counter is at 0x{x:04}.", .{
            runtime.state.pc,
        });

    debugger.state.instruction_count = 0;
    debugger.state.should_print_pc = false;

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
    assert(debugger.state.status == .get_action);
    assert(runtime.writer_is_newline);

    switch (command.value) {
        .help => {
            try debugger.writer.enableColor();
            try runtime.writer.writeAll(@embedFile("help.txt"));
            try debugger.writer.disableColor();
        },

        .quit => return .disable_debugger,
        .exit => return .stop_runtime,

        .clear => {
            debugger.input.clearHistory() catch |err| {
                std.log.err("failed to clear history file: {t}", .{err});
            };
        },

        .reset => {
            const state = debugger.initial_state orelse {
                try debugger.reporter.report(.debugger_requires_state, .{
                    .command = command.tag,
                }).abort();
            };
            runtime.state.copyFrom(state);
            try debugger.writer.printLine("Reset registers and memory to initial state.", .{});
            debugger.state.should_print_pc = true;
        },

        .registers => {
            try debugger.writer.enableColor();
            try runtime.printRegisters();
            try debugger.writer.disableColor();
        },

        .@"continue" => {
            debugger.state.status = .@"continue";
            debugger.state.should_print_pc = true;
            if (debugger.canProceed(runtime))
                try debugger.writer.printLine("Continuing program execution...", .{});
        },

        .print => |arguments| {
            switch (try debugger.resolveLocation(runtime, arguments.location, source)) {
                .register => |register| {
                    try debugger.writer.printLine("Register R{}:", .{register});
                    try debugger.writer.enableColor();
                    try runtime.printInteger(runtime.state.registers[register]);
                    try debugger.writer.disableColor();
                },
                .address => |address| {
                    try debugger.writer.printLine("Memory at address 0x{x:04}:", .{address});
                    try debugger.writer.enableColor();
                    try runtime.printInteger(runtime.state.memory[address]);
                    try debugger.writer.disableColor();
                },
            }
        },

        .list => |arguments| {
            const start = try debugger.resolveMemoryLocation(
                runtime,
                arguments.start.value,
                arguments.start.span,
                source,
            );
            const end = try debugger.resolveMemoryLocation(
                runtime,
                arguments.start.value.add(arguments.length.value - 1),
                arguments.length.span,
                source,
            );
            try debugger.printListing(runtime, start, end);
        },

        .move => |arguments| {
            switch (try debugger.resolveLocation(runtime, arguments.location, source)) {
                .register => |register| {
                    runtime.state.registers[register] = arguments.value.value;
                    try debugger.writer.printLine(
                        "Updated register R{} to 0x{x:04}.",
                        .{ register, arguments.value.value },
                    );
                },
                .address => |address| {
                    try debugger.ensureUserAddress(address, arguments.location.span);
                    runtime.state.memory[address] = arguments.value.value;
                    try debugger.writer.printLine(
                        "Updated memory at address 0x{x:04} to 0x{x:04}.",
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
            try debugger.writer.printLine("Set program counter to 0x{x:04}.", .{address});
            // Don't print PC again.
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

            try debugger.writer.printLine("Next instruction, at 0x{x:04}:", .{address});
            try writeSpanContext(debugger.writer.inner, line.span, .{
                .max_context = arguments.context.value,
            }, assembly.source);
        },

        .eval => |arguments| {
            const assembly = try debugger.getAssembly(command.tag);
            try debugger.evalCommand(runtime, assembly, arguments.instruction, source);
        },

        .echo => |arguments| {
            try debugger.writer.enableColor();
            try debugger.writer.print("[{s}]\n", .{arguments.string.view(source)});
            try debugger.writer.disableColor();
        },

        .step_over => {
            debugger.state.status = .{ .step_over = .{
                .return_address = runtime.state.pc + 1,
            } };
            debugger.state.should_print_pc = true;
            // Don't print message here, we can't know if next instruction will change PC.
        },

        .step_into => |arguments| {
            debugger.state.status = .{ .step_into = .{
                .count = arguments.count.value - 1,
            } };
            debugger.state.should_print_pc = true;
        },

        .step_out => {
            debugger.state.status = .step_out;
            debugger.state.should_print_pc = true;
            if (debugger.canProceed(runtime))
                try debugger.writer.printLine("Finishing subroutine execution...", .{});
        },

        .break_list => {
            if (debugger.breakpoints.entries.items.len == 0) {
                try debugger.writer.printLine("No breakpoints exist", .{});
                return null;
            }
            try debugger.writer.printLine("Breakpoints:", .{});
            try debugger.printBreakpoints();
        },

        .break_add => |arguments| {
            const address = try debugger.resolveMemoryLocation(
                runtime,
                arguments.location.value,
                arguments.location.span,
                source,
            );
            try debugger.ensureUserAddress(address, arguments.location.span);
            const inserted = debugger.breakpoints.insert(address, false) catch {
                try debugger.reporter.report(.debugger_no_space, .{}).abort();
            };
            if (inserted)
                try debugger.writer.printLine("Added breakpoint at 0x{x:04}", .{address})
            else
                try debugger.writer.printLine("Breakpoint already exists at 0x{x:04}", .{address});
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
                try debugger.writer.printLine("Removed breakpoint at 0x{x:04}", .{address})
            else
                try debugger.writer.printLine("No breakpoint exists at 0x{x:04}", .{address});
        },
    }

    return null;
}

fn printListing(debugger: *Debugger, runtime: *Runtime, start: u16, end: u16) !void {
    try debugger.writer.enableColor();

    const line = "+-----------------------------------------------+\n";
    try debugger.writer.print(line, .{});
    try debugger.writer.print("|          hex     decoded         label        |\n", .{});
    try debugger.writer.print(line, .{});

    for (start..end + 1) |i| {
        const address: u16 = @intCast(i);
        const word = runtime.state.memory[address];

        try debugger.writer.print("| ", .{});

        try debugger.writer.print("0x{x:04}", .{address});

        try debugger.writer.print(" {s}", .{
            if (debugger.breakpoints.contains(address)) "B" else " ",
        });

        try debugger.writer.print(" {x:04}", .{word});

        {
            const width = 16;
            var buffer: [width]u8 = undefined;
            const string = if (Instruction.decode(word)) |instruction|
                std.fmt.bufPrint(&buffer, "{f}", .{instruction}) catch unreachable
            else |_|
                "";
            try debugger.writer.print("  {s:<[1]}", .{ string, width });
        }

        {
            const width = 12;
            var buffer: [width]u8 = undefined;
            var string: []const u8 = buffer[0..0];
            if (debugger.assembly) |assembly| {
                if (getAssemblyLineIndexOptional(assembly, address)) |index| {
                    if (getLineLabel(assembly, index)) |label| {
                        const name = label.span.view(assembly.source);
                        const length = @min(name.len, width);
                        @memcpy(buffer[0..length], name[0..length]);
                        if (name.len > width)
                            buffer[width - 1] = '-';
                        string = buffer[0..length];
                    }
                }
            }
            try debugger.writer.print("  {s:<[1]}", .{ string, width });
        }

        try debugger.writer.print(" |\n", .{});
    }

    try debugger.writer.print(line, .{});
    try debugger.writer.disableColor();
}

fn printBreakpoints(debugger: *Debugger) !void {
    for (debugger.breakpoints.entries.items) |entry| {
        try debugger.writer.enableColor();
        try debugger.writer.print("    | Breakpoint at 0x{x:04}", .{entry.address});

        blk: {
            const assembly = debugger.assembly orelse {
                break :blk;
            };

            const index = getAssemblyLineIndexOptional(assembly, entry.address) orelse
                break :blk;
            const line = &assembly.air.lines.items[index];

            if (getLineLabel(assembly, index)) |label| {
                try debugger.writer.print(" (labelled '{s}')", .{
                    label.span.view(assembly.source),
                });
            }

            try debugger.writer.print(":", .{});
            try debugger.writer.disableColor();
            try debugger.writer.print("\n", .{});

            try writeSpanContext(debugger.writer.inner, line.span, .{}, assembly.source);
            continue;
        }

        try debugger.writer.print(" (not in assembly)", .{});
        try debugger.writer.disableColor();
        try debugger.writer.print("\n", .{});
    }
}

fn getLineLabel(assembly: Assembly, index: usize) ?*const Air.Label {
    for (assembly.air.labels.items) |*label| {
        if (label.index == index and
            label.kind != .breakpoint)
            return label;
    }
    for (assembly.air.labels.items) |*label| {
        if (label.index == index)
            return label;
    }
    return null;
}

fn evalCommand(
    debugger: *Debugger,
    runtime: *Runtime,
    assembly: Assembly,
    span: Span,
    source: []const u8,
) (Runtime.HostError || error{Reported})!void {
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

        error.Halt => {
            try debugger.triggerHalt(runtime);
        },

        else => |err2| try debugger.reporter.report(.emulate_exception, .{
            .code = err2,
        }).abort(),
    };
}

fn parseInstructionLine(
    debugger: *const Debugger,
    assembly: Assembly,
    line: []const u8,
    index: usize,
) error{Reported}!Air.Instruction {
    var reporter = debugger.copyReporter(line);
    var parser = try Parser.new(debugger.traps, line, &reporter);

    var instruction = try parser.parseInstruction();
    try parser.resolveLabelOperand(assembly.air, assembly.source, &instruction, index);
    return instruction;
}

fn copyReporter(debugger: *const Debugger, source: []const u8) Reporter {
    var reporter = debugger.reporter.*;
    reporter.source = source;
    reporter.options.strictness = .normal;
    reporter.options.policies = .{
        .extension = reporter.options.policies.extension,
        .smell = reporter.options.policies.smell,
        .style = .permit_all,
        .case = .permit_all,
    };
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
        try debugger.reporter.report(.debugger_address_not_in_assembly, .{
            .value = address,
            .max = @intCast(assembly.air.origin + assembly.air.lines.items.len - 1),
        }).abort();
    }
    return &assembly.air.lines.items[index];
}

fn getAssemblyLineIndexOptional(assembly: Assembly, address: u16) ?usize {
    if (address < assembly.air.origin)
        return null;
    const index = address - assembly.air.origin;
    if (index >= assembly.air.lines.items.len)
        return null;
    return index;
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
                try debugger.reporter.report(.integer_too_large, .{
                    .integer = span,
                    .type_info = @typeInfo(u16).int,
                }).abort();
            };
        },

        .label => |label| {
            const assembly = try debugger.getAssembly(label.name);
            const address = try debugger.resolveLabelIndex(assembly, label.name, source);

            const combined = @as(isize, @intCast(address + assembly.air.origin)) + label.offset;

            return std.math.cast(u16, combined) orelse {
                try debugger.reporter.report(.integer_too_large, .{
                    .integer = span,
                    .type_info = @typeInfo(u16).int,
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

    if (assembly.air.findLabel(string, .sensitive, assembly.source)) |result|
        return result.index;

    if (assembly.air.findLabel(string, .insensitive, assembly.source)) |result| {
        debugger.reporter.report(.debugger_label_partial_match, .{
            .reference = label,
            .nearest = result.span,
            .definition_source = assembly.source,
        }).proceed();
        return result.index;
    }

    try debugger.reporter.report(.undefined_label, .{
        .reference = label,
        .nearest = null,
        .definition_source = assembly.source,
    }).abort();
}

fn getAssembly(debugger: *const Debugger, span: Span) error{Reported}!Assembly {
    return debugger.assembly orelse {
        try debugger.reporter.report(.debugger_requires_assembly, .{
            .command = span,
        }).abort();
    };
}

fn ensureUserAddress(debugger: *Debugger, address: u16, span: Span) error{Reported}!void {
    switch (address) {
        Runtime.user_memory_start...Runtime.user_memory_end => {},
        else => {
            try debugger.reporter.report(.debugger_address_not_user_memory, .{
                .address = span,
                .value = address,
                .max = Runtime.user_memory_end,
            }).abort();
        },
    }
}

fn readCommand(debugger: *Debugger, runtime: *Runtime) ![]const u8 {
    const line = try debugger.readInputLine(runtime);

    try debugger.writer.writePrompt(line, null);
    try debugger.writer.print("\n", .{});
    try debugger.writer.flush();

    const first, const rest = parse.splitCommandLine(line);
    debugger.current_line = rest;
    return first;
}

fn readInputLine(debugger: *Debugger, runtime: *Runtime) ![]const u8 {
    if (debugger.current_line.len > 0)
        return debugger.current_line;

    try runtime.ensureWriterNewline();
    try runtime.tty.enableRawMode();
    const line = debugger.input.readLine(&debugger.writer);
    try runtime.tty.disableRawMode();
    return line;
}
