const Runtime = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Policies = @import("../Policies.zig");
const Traps = @import("../Traps.zig");
const Instruction = @import("decode.zig").Instruction;
const NewlineTracker = @import("NewlineTracker.zig");
const Tty = @import("Tty.zig");

const MEMORY_SIZE = 0x1_0000;
const USER_MEMORY_START = 0x3000;
const USER_MEMORY_END = 0xFDFF;

memory: *[MEMORY_SIZE]u16,
registers: [8]u16,
pc: u16,
condition: Condition,

traps: *const Traps,
policies: *const Policies,

writer: NewlineTracker,
reader: *Io.Reader,
tty: Tty,
io: Io,

pub const Error = ProgramError || IoError;

/// The user's program or configuration (traps, policies) is erroneous.
pub const ProgramError = error{
    PcOutOfBounds,
    IncorrectPadding,
    InvalidOperand,
    UnhandledTrap,
    UnsupportedRti,
    UnpermittedOpcode,
    TrapFailed,
};

/// Stdio or terminal failure.
pub const IoError = error{
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

pub fn init(
    traps: *const Traps,
    policies: *const Policies,
    writer: *Io.Writer,
    reader: *Io.Reader,
    io: Io,
    gpa: Allocator,
) !Runtime {
    const buffer = try gpa.alloc(u16, MEMORY_SIZE);
    @memset(buffer, 0x0000);

    return .{
        .memory = buffer[0..MEMORY_SIZE],
        .registers = .{ 0, 0, 0, 0, 0, 0, 0, USER_MEMORY_END },
        .pc = 0x0000,
        .condition = .zero,
        .traps = traps,
        .policies = policies,
        .writer = .new(writer),
        .reader = reader,
        .tty = .uninit,
        .io = io,
    };
}

pub fn deinit(runtime: Runtime, gpa: Allocator) void {
    defer gpa.free(runtime.memory);
}

const Control = enum { @"continue", @"break" };

pub fn run(runtime: *Runtime) Error!void {
    while (true) {
        switch (runtime.pc) {
            USER_MEMORY_START...USER_MEMORY_END => {},
            else => return error.PcOutOfBounds,
        }

        const word = runtime.memory[runtime.pc];
        runtime.pc += 1;

        const instr: Instruction = try .decode(word);
        const control = try runtime.runInstruction(instr);
        switch (control) {
            .@"continue" => continue,
            .@"break" => break,
        }
    }
}

fn runInstruction(runtime: *Runtime, instr: Instruction) Error!Control {
    switch (instr) {
        inline .add, .@"and" => |operands| {
            const lhs = runtime.registers[operands.src_a];
            const rhs: u16 = switch (operands.src_b) {
                .register => |register| runtime.registers[register],
                .immediate => |immediate| signExtend(immediate),
            };
            runtime.setRegister(operands.dest, switch (instr) {
                .add => lhs +% rhs,
                .@"and" => lhs & rhs,
                else => unreachable,
            });
        },
        .not => |operands| {
            runtime.setRegister(operands.dest, ~runtime.registers[operands.src]);
        },

        .br => |operands| {
            // No-op case
            if (operands.mask == 0b000)
                return .@"continue";
            if (@intFromEnum(runtime.condition) & operands.mask != 0)
                runtime.pc +%= signExtend(operands.pc_offset);
        },

        .jmp_ret => |operands| {
            runtime.pc = runtime.registers[operands.base];
        },
        .jsr_jsrr => |variant| {
            runtime.registers[7] = runtime.pc;
            switch (variant) {
                .jsr => |operands| {
                    runtime.pc +%= signExtend(operands.pc_offset);
                },
                .jsrr => |operands| {
                    runtime.pc = runtime.registers[operands.base];
                },
            }
        },

        .lea => |operands| {
            const address = runtime.pc +% signExtend(operands.pc_offset);
            runtime.setRegister(operands.dest, address);
        },
        .ld => |operands| {
            const address = runtime.pc +% signExtend(operands.pc_offset);
            runtime.setRegister(operands.dest, runtime.memory[address]);
        },
        .ldi => |operands| {
            const address = runtime.memory[runtime.pc +% signExtend(operands.pc_offset)];
            runtime.setRegister(operands.dest, runtime.memory[address]);
        },
        .ldr => |operands| {
            const address = runtime.registers[operands.base] + signExtend(operands.offset);
            runtime.setRegister(operands.dest, runtime.memory[address]);
        },
        .st => |operands| {
            const address = runtime.pc +% signExtend(operands.pc_offset);
            runtime.memory[address] = runtime.registers[operands.src];
        },
        .sti => |operands| {
            const address = runtime.memory[runtime.pc +% signExtend(operands.pc_offset)];
            runtime.memory[address] = runtime.registers[operands.src];
        },
        .str => |operands| {
            const address = runtime.registers[operands.base] + signExtend(operands.offset);
            runtime.memory[address] = runtime.registers[operands.src];
        },

        .trap => |operands| {
            const entry = runtime.traps.entries[operands.vect];
            const procedure = entry.procedure orelse
                // No procedure declared
                // Either trap was never registered, or only registered for alias
                return error.UnhandledTrap;
            procedure(runtime, entry.data) catch |err| switch (err) {
                error.Halt => return .@"break",
                else => |err2| return err2,
            };
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
                    runtime.registers[operands.dest] = value;
                },
                .push => |operands| {
                    const value = runtime.registers[operands.src];
                    runtime.stackPush(value);
                },
                .rets => {
                    runtime.pc = runtime.stackPop();
                },
                .call => |operands| {
                    runtime.stackPush(runtime.pc);
                    runtime.pc +%= signExtend(operands.pc_offset);
                },
            }
        },
    }

    return .@"continue";
}

fn setRegister(runtime: *Runtime, register: u3, value: u16) void {
    runtime.registers[register] = value;

    runtime.condition =
        if (@as(i16, @bitCast(value)) < 0)
            .negative
        else if (value == 0)
            .zero
        else
            .positive;
}

fn stackPush(runtime: *Runtime, value: u16) void {
    runtime.registers[7] -%= 1;
    const stack_ptr = runtime.registers[7];
    runtime.memory[stack_ptr] = value;
}

fn stackPop(runtime: *Runtime) u16 {
    const stack_ptr = runtime.registers[7];
    const value = runtime.memory[stack_ptr];
    runtime.registers[7] +%= 1;
    return value;
}

pub fn printRegisters(runtime: *Runtime) error{WriteFailed}!void {
    try runtime.writer.ensureNewline();
    try runtime.writer.interface.print("+-----------------------------------+\n", .{});
    try runtime.writer.interface.print("|        hex      int    uint   chr |\n", .{});

    for (runtime.registers, 0..8) |word, i| {
        try runtime.writer.interface.print("| R{}  ", .{i});
        try runtime.printIntegerForms(word);
        try runtime.writer.interface.print(" |\n", .{});
    }

    try runtime.writer.interface.print("+-----------------+-----------------+\n", .{});
    try runtime.writer.interface.print(
        "|    PC 0x{x:04}    |   CC {s}   |\n",
        .{ runtime.pc, switch (runtime.condition) {
            .negative => "NEGATIVE",
            .zero => "  ZERO  ",
            .positive => "POSITIVE",
        } },
    );
    try runtime.writer.interface.print("+-----------------+-----------------+\n", .{});
}

fn printIntegerForms(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    try runtime.writer.interface.print(
        "0x{x:04}  {:7}  {:6}   ",
        .{ word, @as(i16, @bitCast(word)), word },
    );
    try runtime.printDisplayChar(word);
}

fn printDisplayChar(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    const display = switch (word) {
        // Non-ascii and unimportant ascii
        else => "---",
        // ASCII control characters which are arbitrarily considered significant
        // ᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘꞯʀꜱᴛᴜᴠᴡxʏᴢ
        0x00 => "ɴᴜʟ",
        0x08 => " ʙꜱ",
        0x09 => " ʜᴛ",
        0x0a => " ʟꜰ",
        0x0b => " ᴠᴛ",
        0x0c => " ꜰꜰ",
        0x0d => " ᴄʀ",
        0x1b => "ᴇꜱᴄ",
        0x7f => "ᴅᴇʟ",
        // Space
        0x20 => "[_]",
        // Printable ASCII characters
        0x21...0x7e => {
            try runtime.writer.interface.print("{c:^3}", .{@as(u8, @truncate(word))});
            return;
        },
    };
    try runtime.writer.interface.print("{s}", .{display});
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
