const Runtime = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const MEMORY_SIZE = 0x1_0000;

memory: *[MEMORY_SIZE]u16,
registers: [8]u16,
pc: u16,
condition: Condition,

newline: bool,
io: Io,

const Condition = enum(u3) {
    negative = 0b100,
    zero = 0b010,
    positive = 0b001,
};

pub fn init(io: Io, allocator: Allocator) !Runtime {
    const buffer = try allocator.alloc(u16, MEMORY_SIZE);
    @memset(buffer, 0x0000);

    return .{
        .memory = buffer[0..MEMORY_SIZE],
        .registers = @splat(0x0000),
        .pc = 0x0000,
        .condition = .zero,
        .newline = true,
        .io = io,
    };
}

pub fn deinit(runtime: Runtime, allocator: Allocator) void {
    defer allocator.free(runtime.memory);
}

pub const Error =
    Io.Writer.Error ||
    error{
        IncorrectPadding,
        InvalidOperand,
        UnsupportedTrap,
        UnsupportedRti,
        ReservedOpcode,
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
    reserved = 0xd,
};

const TrapVect = enum(u8) {
    getc = 0x20,
    out = 0x21,
    puts = 0x22,
    in = 0x23,
    putsp = 0x24,
    halt = 0x25,
    putn = 0x26,
    reg = 0x27,
    _,
};

pub fn ensureNewline(runtime: *Runtime) Io.Writer.Error!void {
    if (!runtime.newline)
        try runtime.writeChar('\n');
}

fn writeChar(runtime: *Runtime, char: u8) Io.Writer.Error!void {
    var writer = Io.File.stdout().writer(runtime.io, &.{});
    try writer.interface.writeByte(char);
    try writer.interface.flush();
    runtime.newline = char == '\n';
}

fn setRegister(runtime: *Runtime, register: u3, value: u16) void {
    runtime.registers[register] = value;

    runtime.condition =
        if (value < 0)
            .negative
        else if (value == 0)
            .zero
        else
            .positive;
}

pub fn run(runtime: *Runtime) Error!void {
    while (true) {
        // TODO: Check pc in bounds

        const instr = runtime.memory[runtime.pc];
        runtime.pc += 1;

        // Conversion cannot fail
        const opcode: Opcode = @enumFromInt(bitmask.opcode.apply(instr));

        switch (opcode) {
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
                if (bitmask.padding.not.apply(instr) != 0b11111)
                    return error.IncorrectPadding;
                runtime.setRegister(dest_reg, ~runtime.registers[src_reg]);
            },

            .br => {
                const mask: u3 = bitmask.operand.condition_mask.apply(instr);
                // Cannot have NO flags. `BR` is assembled as `BRnzp`
                if (mask == 0b000) {
                    return error.InvalidOperand;
                }
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
                    0 => { // JSR
                        const pc_offset = bitmask.operand.pc_offset_11.applySext(instr);
                        runtime.pc +%= pc_offset;
                    },
                    1 => { // JSRR
                        if (bitmask.padding.jsrr_high.apply(instr) != 0 or
                            bitmask.padding.jsrr_low.apply(instr) != 0)
                            return error.IncorrectPadding;
                        const base_reg = bitmask.operand.reg_mid.apply(instr);
                        runtime.pc = runtime.registers[base_reg];
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
                const offset = bitmask.operand.offset_6.apply(instr);
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
                const offset = bitmask.operand.offset_6.apply(instr);
                const address = runtime.registers[base_reg] + offset;
                runtime.memory[address] = runtime.registers[src_reg];
            },

            .trap => {
                const trap_vect: TrapVect = @enumFromInt(bitmask.operand.trap_vect.apply(instr));

                switch (trap_vect) {
                    .puts => {
                        var i: usize = runtime.registers[0];
                        while (true) : (i += 1) {
                            const word: u8 = @truncate(runtime.memory[i]);
                            if (word == 0x00)
                                break;
                            try runtime.writeChar(word);
                        }
                    },

                    .halt => {
                        break;
                    },

                    else => {
                        // TODO:
                        std.log.warn("unimplemented trap vector: {t}", .{trap_vect});
                    },

                    _ => {
                        return error.UnsupportedTrap;
                    },
                }
            },

            .rti => return error.UnsupportedRti,

            // TODO: Support lace stack extension (behind feature flag)
            .reserved => return error.ReservedOpcode,
        }
    }
}

const bitmask = struct {
    pub const opcode: Mask = .new(12, 15);

    pub const flag = struct {
        pub const add_and: Mask = .new(5, 5);
        pub const jsr_jsrr: Mask = .new(11, 11);
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
        pub const pc_offset_11: Mask = .new(0, 10);
        pub const condition_mask: Mask = .new(9, 11);
    };
};

pub const Mask = struct {
    lowest: u4,
    highest: u4,

    fn new(lowest: u4, highest: u4) Mask {
        return .{ .lowest = lowest, .highest = highest };
    }

    pub fn apply(comptime mask: Mask, word: u16) @Int(
        .unsigned,
        mask.highest - mask.lowest + 1,
    ) {
        assert(mask.lowest <= mask.highest);
        return @truncate(word >> mask.lowest);
    }

    pub fn applySext(comptime mask: Mask, word: u16) u16 {
        return signExtend(apply(mask, word));
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
        try expect(signExtend(@as(u2, 0b101)) == 0b1111_1111_1111_1101);
        try expect(signExtend(@as(u3, 0b0101)) == 0b0000_0000_0000_0101);
    }

    test apply {
        const expect = std.testing.expect;

        try expect(apply(.new(0, 15), 0b1010_1010_0101_0101) == 0b1010_1010_0101_0101);

        try expect(apply(.new(0, 0), 0b1010_1010_0101_0101) == 0b1);
        try expect(apply(.new(0, 1), 0b1010_1010_0101_0101) == 0b01);
        try expect(apply(.new(0, 2), 0b1010_1010_0101_0101) == 0b101);
        try expect(apply(.new(0, 3), 0b1010_1010_0101_0101) == 0b0101);
        try expect(apply(.new(0, 4), 0b1010_1010_0101_0101) == 0b10101);

        try expect(apply(.new(15, 15), 0b1010_1010_0101_0101) == 0b1);
        try expect(apply(.new(13, 15), 0b1010_1010_0101_0101) == 0b101);
        try expect(apply(.new(12, 15), 0b1010_1010_0101_0101) == 0b1010);

        try expect(apply(.new(1, 4), 0b1010_1010_0101_0101) == 0b1010);
        try expect(apply(.new(2, 4), 0b1010_1010_0101_0101) == 0b101);
        try expect(apply(.new(11, 14), 0b1010_1010_0101_0101) == 0b0101);
        try expect(apply(.new(11, 13), 0b1010_1010_0101_0101) == 0b101);
    }

    test applySext {
        const expect = std.testing.expect;

        try expect(applySext(.new(0, 15), 0b1010_1010_0101_0101) == 0b1010_1010_0101_0101);

        try expect(applySext(.new(0, 0), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1111);
        try expect(applySext(.new(0, 1), 0b1010_1010_0101_0101) == 0b0000_0000_0000_0001);
        try expect(applySext(.new(0, 2), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
        try expect(applySext(.new(0, 3), 0b1010_1010_0101_0101) == 0b0000_0000_0000_0101);
        try expect(applySext(.new(0, 4), 0b1010_1010_0101_0101) == 0b1111_1111_1111_0101);

        try expect(applySext(.new(15, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1111);
        try expect(applySext(.new(14, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1110);
        try expect(applySext(.new(13, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
        try expect(applySext(.new(12, 15), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1010);
        //
        try expect(applySext(.new(1, 4), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1010);
        try expect(applySext(.new(2, 4), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
        try expect(applySext(.new(11, 14), 0b1010_1010_0101_0101) == 0b0000_0000_0000_0101);
        try expect(applySext(.new(11, 13), 0b1010_1010_0101_0101) == 0b1111_1111_1111_1101);
    }
};
