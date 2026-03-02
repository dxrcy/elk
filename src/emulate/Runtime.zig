const Runtime = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Policies = @import("../Policies.zig");
const Traps = @import("../Traps.zig");
const NewlineTracker = @import("NewlineTracker.zig");
const Tty = @import("Tty.zig");
const Mask = @import("Mask.zig");

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

const Opcode = enum(u4) {
    add = 0x1,
    @"and" = 0x5,
    not = 0x9,
    br = 0x0,
    jmp_ret = 0xc,
    jsr_jsrr = 0x4,
    lea = 0xe,
    ld = 0x2,
    ldi = 0xa,
    ldr = 0x6,
    st = 0x3,
    sti = 0xb,
    str = 0x7,
    trap = 0xf,
    rti = 0x8,
    reserved_stack = 0xd,
};

const bitmask = struct {
    pub const opcode: Mask = .new(12, 15);

    pub const flag = struct {
        pub const add_and: Mask = .new(5, 5);
        pub const jsr_jsrr: Mask = .new(11, 11);
        pub const pop_push_rets_call: Mask = .new(10, 11);
    };

    pub const padding = struct {
        pub const add_and: Mask = .new(3, 4);
        pub const not: Mask = .new(0, 5);
        pub const jmp_ret_high: Mask = .new(9, 11);
        pub const jmp_ret_low: Mask = .new(0, 5);
        pub const jsrr_high: Mask = .new(9, 11);
        pub const jsrr_low: Mask = .new(0, 5);
    };

    pub const operand = struct {
        pub const reg_high: Mask = .new(9, 11);
        pub const reg_mid: Mask = .new(6, 8);
        pub const reg_low: Mask = .new(0, 2);
        pub const imm_5: Mask = .new(0, 4);
        pub const trap_vect: Mask = .new(0, 8);
        pub const offset_6: Mask = .new(0, 5);
        pub const pc_offset_9: Mask = .new(0, 8);
        pub const pc_offset_10: Mask = .new(0, 9);
        pub const pc_offset_11: Mask = .new(0, 10);
        pub const condition_mask: Mask = .new(9, 11);
    };
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

        const instr = runtime.memory[runtime.pc];
        runtime.pc += 1;

        switch (try runtime.runInstruction(instr)) {
            .@"continue" => continue,
            .@"break" => break,
        }
    }
}

fn runInstruction(runtime: *Runtime, instr: u16) Error!Control {
    // Conversion cannot fail
    const opcode: Opcode = @enumFromInt(bitmask.opcode.apply(instr));

    // TODO: Extract magic numbers

    switch (opcode) {
        .rti => return error.UnsupportedRti,

        inline .add, .@"and" => |arith_opcode| {
            const dest_reg = bitmask.operand.reg_high.apply(instr);
            const src_reg = bitmask.operand.reg_mid.apply(instr);

            const lhs = runtime.registers[src_reg];
            const rhs = rhs: switch (bitmask.flag.add_and.apply(instr)) {
                0 => { // Register
                    if (bitmask.padding.add_and.apply(instr) != 0)
                        return error.IncorrectPadding;
                    const rhs_reg = bitmask.operand.reg_low.apply(instr);
                    break :rhs runtime.registers[rhs_reg];
                },
                1 => { // Immediate
                    break :rhs bitmask.operand.imm_5.applySext(instr);
                },
            };

            runtime.setRegister(dest_reg, switch (arith_opcode) {
                .add => lhs +% rhs,
                .@"and" => lhs & rhs,
                else => comptime unreachable,
            });
        },

        .not => {
            const dest_reg = bitmask.operand.reg_high.apply(instr);
            const src_reg = bitmask.operand.reg_mid.apply(instr);
            if (bitmask.padding.not.apply(instr) != 0b111111)
                return error.IncorrectPadding;
            runtime.setRegister(dest_reg, ~runtime.registers[src_reg]);
        },

        .br => {
            const mask: u3 = bitmask.operand.condition_mask.apply(instr);
            // No-op case
            if (mask == 0b000)
                return .@"continue";
            const pc_offset = bitmask.operand.pc_offset_9.applySext(instr);
            if (@intFromEnum(runtime.condition) & mask != 0)
                runtime.pc +%= pc_offset;
        },

        .jmp_ret => {
            const base_reg = bitmask.operand.reg_mid.apply(instr);
            if (bitmask.padding.jmp_ret_high.apply(instr) != 0 or
                bitmask.padding.jmp_ret_low.apply(instr) != 0)
                return error.IncorrectPadding;
            runtime.pc = runtime.registers[base_reg];
        },

        .jsr_jsrr => {
            runtime.registers[7] = runtime.pc;
            switch (bitmask.flag.jsr_jsrr.apply(instr)) {
                0 => { // JSRR
                    if (bitmask.padding.jsrr_high.apply(instr) != 0 or
                        bitmask.padding.jsrr_low.apply(instr) != 0)
                        return error.IncorrectPadding;
                    const base_reg = bitmask.operand.reg_mid.apply(instr);
                    runtime.pc = runtime.registers[base_reg];
                },
                1 => { // JSR
                    const pc_offset = bitmask.operand.pc_offset_11.applySext(instr);
                    runtime.pc +%= pc_offset;
                },
            }
        },

        .lea => {
            const dest_reg = bitmask.operand.reg_high.apply(instr);
            const pc_offset = bitmask.operand.pc_offset_9.applySext(instr);
            runtime.setRegister(dest_reg, runtime.pc +% pc_offset);
        },

        .ld => {
            const dest_reg = bitmask.operand.reg_high.apply(instr);
            const pc_offset = bitmask.operand.pc_offset_9.applySext(instr);
            const address = runtime.pc +% pc_offset;
            runtime.setRegister(dest_reg, runtime.memory[address]);
        },

        .ldi => {
            const dest_reg = bitmask.operand.reg_high.apply(instr);
            const pc_offset = bitmask.operand.pc_offset_9.applySext(instr);
            const address = runtime.memory[runtime.pc +% pc_offset];
            runtime.setRegister(dest_reg, runtime.memory[address]);
        },

        .ldr => {
            const dest_reg = bitmask.operand.reg_high.apply(instr);
            const base_reg = bitmask.operand.reg_mid.apply(instr);
            const offset = bitmask.operand.offset_6.applySext(instr);
            const address = runtime.registers[base_reg] + offset;
            runtime.setRegister(dest_reg, runtime.memory[address]);
        },

        .st => {
            const src_reg = bitmask.operand.reg_high.apply(instr);
            const pc_offset = bitmask.operand.pc_offset_9.applySext(instr);
            const address = runtime.pc +% pc_offset;
            runtime.memory[address] = runtime.registers[src_reg];
        },

        .sti => {
            const src_reg = bitmask.operand.reg_high.apply(instr);
            const pc_offset = bitmask.operand.pc_offset_9.applySext(instr);
            const address = runtime.memory[runtime.pc +% pc_offset];
            runtime.memory[address] = runtime.registers[src_reg];
        },

        .str => {
            const src_reg = bitmask.operand.reg_high.apply(instr);
            const base_reg = bitmask.operand.reg_mid.apply(instr);
            const offset = bitmask.operand.offset_6.applySext(instr);
            const address = runtime.registers[base_reg] + offset;
            runtime.memory[address] = runtime.registers[src_reg];
        },

        .trap => {
            const vect = bitmask.operand.trap_vect.apply(instr);
            const entry = runtime.traps.entries[vect] orelse
                return error.UnhandledTrap;
            entry.procedure(runtime, entry.data) catch |err| switch (err) {
                error.Halt => return .@"break",
                else => |err2| return err2,
            };
        },

        .reserved_stack => {
            if (runtime.policies.extension.stack_instructions != .permit)
                return error.UnpermittedOpcode;

            // Do not set condition for any operation
            switch (bitmask.flag.pop_push_rets_call.apply(instr)) {
                0b00 => { // POP
                    const dest_reg = bitmask.operand.reg_mid.apply(instr);
                    const value = runtime.stackPop();
                    runtime.registers[dest_reg] = value;
                },
                0b01 => { // PUSH
                    const src_reg = bitmask.operand.reg_mid.apply(instr);
                    const value = runtime.registers[src_reg];
                    runtime.stackPush(value);
                },
                0b10 => { // RETS
                    runtime.pc = runtime.stackPop();
                },
                0b11 => { // CALL
                    runtime.stackPush(runtime.pc);
                    const pc_offset = bitmask.operand.pc_offset_10.applySext(instr);
                    runtime.pc +%= pc_offset;
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
