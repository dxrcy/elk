const Runtime = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Debugger = @import("debugger/Debugger.zig");
const Policies = @import("../policies.zig").Policies;
const Traps = @import("../Traps.zig");
const Tty = @import("Tty.zig");

pub const Callback = @import("../callback.zig").Callback;
pub const Instruction = @import("decode.zig").Instruction;

pub const memory_size = 0x1_0000;
pub const user_memory_start = 0x3000;
pub const user_memory_end = 0xFDFF;

state: State,

traps: *const Traps,
hooks: Hooks,
policies: Policies,
debugger: ?*Debugger,

reader: *Io.Reader,
writer: *Io.Writer,
writer_is_newline: bool,
tty: Tty,

pub const State = struct {
    memory: []u16,
    registers: [8]u16,
    pc: u16,
    condition: Condition,

    pub fn init(gpa: Allocator) error{OutOfMemory}!State {
        const memory = try gpa.alloc(u16, memory_size);
        @memset(memory, 0x0000);
        return .{
            .memory = memory,
            .registers = .{ 0, 0, 0, 0, 0, 0, 0, user_memory_end },
            .pc = 0x0000,
            .condition = .zero,
        };
    }

    pub fn copyFrom(dest: *State, src: State) void {
        @memcpy(dest.memory, src.memory);
        dest.* = .{
            .memory = dest.memory,
            .registers = src.registers,
            .pc = src.pc,
            .condition = src.condition,
        };
    }

    pub fn deinit(state: State, gpa: Allocator) void {
        defer gpa.free(state.memory);
    }
};

const Error = Exception || HostError;

/// The user's program or configuration (traps, policies) is erroneous.
pub const Exception = error{
    PcOutOfBounds,
    IncorrectPadding,
    InvalidOperand,
    UnhandledTrap,
    UnsupportedRti,
    UnpermittedOpcode,
    TrapFailed,
};

/// Stdio or terminal failure.
pub const HostError = error{
    WriteFailed,
    ReadFailed,
    EndOfStream,
    TermiosFailed,
};

const Condition = enum(u3) {
    negative = 0b100,
    zero = 0b010,
    positive = 0b001,
};

pub const Hooks = struct {
    pre_decode: ?Callback(&.{ *Runtime, u16 }, HostError!void) = null,
    pre_execute: ?Callback(&.{ *Runtime, Instruction }, HostError!void) = null,
};

pub fn init(params: struct {
    gpa: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    traps: *const Traps,
    hooks: Hooks,
    policies: Policies,
    debugger: ?*Debugger = null,
}) !Runtime {
    return .{
        .state = try .init(params.gpa),
        .traps = params.traps,
        .hooks = params.hooks,
        .policies = params.policies,
        .debugger = params.debugger,
        .reader = params.reader,
        .writer = params.writer,
        .writer_is_newline = true,
        .tty = .uninit,
    };
}

pub fn deinit(runtime: Runtime, gpa: Allocator) void {
    runtime.state.deinit(gpa);
}

pub fn readFromFile(runtime: *Runtime, io: Io, file: Io.File, buffer: []u8) !void {
    var reader = file.reader(io, buffer);
    const metadata = try file.stat(io);

    if (metadata.size < 2)
        return error.FileTooSmall;
    if (metadata.size % 2 != 0)
        return error.FileNotAligned;

    const origin = try reader.interface.takeInt(u16, .big);
    runtime.state.pc = origin;

    var i: usize = 0;
    const words = metadata.size / 2 - 1;
    while (i < words) : (i += 1) {
        const raw = try reader.interface.takeInt(u16, .big);
        runtime.state.memory[origin + i] = raw;
    }
}

pub fn run(runtime: *Runtime) Error!void {
    if (runtime.debugger) |debugger|
        try debugger.startMessage();

    while (true) {
        if (runtime.debugger) |debugger| {
            if (try debugger.invoke(runtime)) |control| switch (control) {
                .@"continue" => continue,
                .@"break" => break,
            };
        }

        runtime.runNextInstruction() catch |err| switch (err) {
            error.WriteFailed,
            error.ReadFailed,
            error.EndOfStream,
            error.TermiosFailed,
            => |err2| return err2,

            else => |exception| {
                if (runtime.debugger) |debugger| {
                    if (debugger.state.status != .inactive) {
                        try debugger.catchEvent(exception, runtime);
                        continue;
                    }
                }
                break;
            },
        };
    }
}

fn runNextInstruction(runtime: *Runtime) (Error || error{Halt})!void {
    switch (runtime.state.pc) {
        user_memory_start...user_memory_end => {},
        else => return error.PcOutOfBounds,
    }

    const word = runtime.state.memory[runtime.state.pc];
    runtime.state.pc += 1;

    if (runtime.hooks.pre_decode) |pre_decode|
        try pre_decode.call(.{ runtime, word });

    const instruction: Instruction = try .decode(word);

    if (runtime.hooks.pre_execute) |pre_execute|
        try pre_execute.call(.{ runtime, instruction });

    try runtime.runInstruction(instruction);
}

pub fn runInstruction(runtime: *Runtime, instruction: Instruction) (Error || error{Halt})!void {
    switch (instruction) {
        inline .add, .@"and" => |operands, subset| {
            const lhs = runtime.state.registers[operands.src_a];
            const rhs: u16 = switch (operands.src_b) {
                .register => |register| runtime.state.registers[register],
                .immediate => |immediate| signExtend(immediate),
            };
            runtime.setRegister(operands.dest, switch (subset) {
                .add => lhs +% rhs,
                .@"and" => lhs & rhs,
                else => comptime unreachable,
            });
        },
        .not => |operands| {
            runtime.setRegister(operands.dest, ~runtime.state.registers[operands.src]);
        },

        .br => |operands| {
            // No-op case
            if (operands.mask == 0b000)
                return;
            if (@intFromEnum(runtime.state.condition) & operands.mask != 0)
                runtime.state.pc +%= signExtend(operands.pc_offset);
        },

        .jmp_ret => |operands| {
            runtime.state.pc = runtime.state.registers[operands.base];
        },
        .jsr_jsrr => |variant| {
            runtime.state.registers[7] = runtime.state.pc;
            switch (variant) {
                .jsr => |operands| {
                    runtime.state.pc +%= signExtend(operands.pc_offset);
                },
                .jsrr => |operands| {
                    runtime.state.pc = runtime.state.registers[operands.base];
                },
            }
        },

        .lea => |operands| {
            const address = runtime.state.pc +% signExtend(operands.pc_offset);
            runtime.setRegister(operands.dest, address);
        },
        .ld => |operands| {
            const address = runtime.state.pc +% signExtend(operands.pc_offset);
            runtime.setRegister(operands.dest, runtime.state.memory[address]);
        },
        .ldi => |operands| {
            const address = runtime.state.memory[runtime.state.pc +% signExtend(operands.pc_offset)];
            runtime.setRegister(operands.dest, runtime.state.memory[address]);
        },
        .ldr => |operands| {
            const address = runtime.state.registers[operands.base] + signExtend(operands.offset);
            runtime.setRegister(operands.dest, runtime.state.memory[address]);
        },
        .st => |operands| {
            const address = runtime.state.pc +% signExtend(operands.pc_offset);
            runtime.state.memory[address] = runtime.state.registers[operands.src];
        },
        .sti => |operands| {
            const address = runtime.state.memory[runtime.state.pc +% signExtend(operands.pc_offset)];
            runtime.state.memory[address] = runtime.state.registers[operands.src];
        },
        .str => |operands| {
            const address = runtime.state.registers[operands.base] + signExtend(operands.offset);
            runtime.state.memory[address] = runtime.state.registers[operands.src];
        },

        .trap => |operands| {
            const callback = runtime.traps.entries[operands.vect].callback orelse
                // No trap callback declared
                // Either trap was never registered, or only registered for alias
                return error.UnhandledTrap;
            try callback.call(.{runtime});
        },

        .rti => {
            return error.UnsupportedRti;
        },

        .pop_push_rets_call => |variant| {
            if (runtime.policies.extension.stack_instructions != .permit)
                return error.UnpermittedOpcode;

            // Do not set condition for any operation
            switch (variant) {
                .pop => |operands| {
                    const value = runtime.stackPop();
                    runtime.state.registers[operands.dest] = value;
                },
                .push => |operands| {
                    const value = runtime.state.registers[operands.src];
                    runtime.stackPush(value);
                },
                .rets => {
                    runtime.state.pc = runtime.stackPop();
                },
                .call => |operands| {
                    runtime.stackPush(runtime.state.pc);
                    runtime.state.pc +%= signExtend(operands.pc_offset);
                },
            }
        },
    }
}

fn setRegister(runtime: *Runtime, register: u3, value: u16) void {
    runtime.state.registers[register] = value;

    runtime.state.condition =
        if (@as(i16, @bitCast(value)) < 0)
            .negative
        else if (value == 0)
            .zero
        else
            .positive;
}

fn stackPush(runtime: *Runtime, value: u16) void {
    runtime.state.registers[7] -%= 1;
    const stack_ptr = runtime.state.registers[7];
    runtime.state.memory[stack_ptr] = value;
}

fn stackPop(runtime: *Runtime) u16 {
    const stack_ptr = runtime.state.registers[7];
    const value = runtime.state.memory[stack_ptr];
    runtime.state.registers[7] +%= 1;
    return value;
}

pub fn readByte(runtime: *const Runtime) error{ EndOfStream, ReadFailed }!u8 {
    var char: u8 = undefined;
    runtime.reader.readSliceAll(@ptrCast(&char)) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.ReadFailed,
    };
    return char;
}

pub fn ensureWriterNewline(runtime: *Runtime) error{WriteFailed}!void {
    if (runtime.writer_is_newline)
        return;
    try runtime.writer.writeByte('\n');
    runtime.writer_is_newline = true;
}

pub fn writeChar(runtime: *Runtime, char: u8) error{WriteFailed}!void {
    try runtime.writer.writeByte(char);
    runtime.writer_is_newline = char == '\n';
}

pub fn printRegisters(runtime: *Runtime) error{WriteFailed}!void {
    try runtime.ensureWriterNewline();
    try runtime.writer.print("+-----------------------------------+\n", .{});
    try runtime.writer.print("|        hex      int    uint   chr |\n", .{});

    for (runtime.state.registers, 0..8) |word, i| {
        try runtime.writer.print("| R{}  ", .{i});
        try runtime.printIntegerForms(word);
        try runtime.writer.print(" |\n", .{});
    }

    try runtime.writer.print("+-----------------+-----------------+\n", .{});
    try runtime.writer.print(
        "|    PC 0x{x:04}    |   CC {s}   |\n",
        .{ runtime.state.pc, switch (runtime.state.condition) {
            .negative => "NEGATIVE",
            .zero => "  ZERO  ",
            .positive => "POSITIVE",
        } },
    );
    try runtime.writer.print("+-----------------+-----------------+\n", .{});
}

pub fn printInteger(runtime: *Runtime, integer: u16) error{WriteFailed}!void {
    try runtime.ensureWriterNewline();
    try runtime.writer.print("+-------------------------------+\n", .{});
    try runtime.writer.print("|    hex      int    uint   chr |\n", .{});

    try runtime.writer.print("| ", .{});
    try runtime.printIntegerForms(integer);
    try runtime.writer.print(" |\n", .{});

    try runtime.writer.print("+-------------------------------+\n", .{});
}

fn printIntegerForms(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    try runtime.writer.print(
        "0x{x:04}  {:7}  {:6}   ",
        .{ word, @as(i16, @bitCast(word)), word },
    );
    try runtime.printDisplayChar(word);
}

fn printDisplayChar(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    const ascii = [0x80]*const [3]u8{
        "NUL", "SOH", "STX",  "ETX", "EOT", "ENQ", "ACK", "BEL", " BS", " HT", " LF", " VT", " FF",  " CR", " SO", " SI",
        "DLE", "DC1", "DC2",  "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", " EM", "SUB", "ESC", " FS",  " GS", " RS", " US",
        " SP", " ! ", " \" ", " # ", " $ ", " % ", " & ", " ' ", " ( ", " ) ", " * ", " + ", " , ",  " - ", " . ", " / ",
        " 0 ", " 1 ", " 2 ",  " 3 ", " 4 ", " 5 ", " 6 ", " 7 ", " 8 ", " 9 ", " : ", " ; ", " < ",  " = ", " > ", " ? ",
        " @ ", " A ", " B ",  " C ", " D ", " E ", " F ", " G ", " H ", " I ", " J ", " K ", " L ",  " M ", " N ", " O ",
        " P ", " Q ", " R ",  " S ", " T ", " U ", " V ", " W ", " X ", " Y ", " Z ", " [ ", " \\ ", " ] ", " ^ ", " _ ",
        " ` ", " a ", " b ",  " c ", " d ", " e ", " f ", " g ", " h ", " i ", " j ", " k ", " l ",  " m ", " n ", " o ",
        " p ", " q ", " r ",  " s ", " t ", " u ", " v ", " w ", " x ", " y ", " z ", " { ", " | ",  " } ", " ~ ", "DEL",
    };
    const display = if (word > 0x80) "---" else ascii[word];
    try runtime.writer.print("{s}", .{display});
}

fn signExtend(value: anytype) u16 {
    const bits = @typeInfo(@TypeOf(value)).int.bits;
    const Signed = @Int(.signed, bits);
    return @bitCast(@as(i16, @as(Signed, @bitCast(value))));
}

test signExtend {
    const expect = std.testing.expect;

    try expect(signExtend(@as(u1, 0b1)) == 0b1111_1111_1111_1111);
    try expect(signExtend(@as(u2, 0b01)) == 0b0000_0000_0000_0001);
    try expect(signExtend(@as(u3, 0b101)) == 0b1111_1111_1111_1101);
    try expect(signExtend(@as(u4, 0b0101)) == 0b0000_0000_0000_0101);
}
