const Runtime = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const MEMORY_SIZE = 0x1_0000;

memory: *[MEMORY_SIZE]u16,
registers: [8]u16,
pc: u16,
condition: Condition,

const Condition = enum(u3) {
    negative = 0b100,
    zero = 0b010,
    positive = 0b001,
};

pub fn init(allocator: Allocator) !Runtime {
    const buffer = try allocator.alloc(u16, MEMORY_SIZE);
    @memset(buffer, 0x0000);

    return .{
        .memory = buffer[0..MEMORY_SIZE],
        .registers = @splat(0x0000),
        .pc = 0x0000,
        .condition = .zero,
    };
}

pub fn deinit(runtime: Runtime, allocator: Allocator) void {
    defer allocator.free(runtime.memory);
}

// TODO:
pub const Error = error{};

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

pub fn run(runtime: *Runtime) Error!void {
    while (true) {
        // TODO: Check pc in bounds

        const instr = runtime.memory[runtime.pc];
        runtime.pc += 1;

        std.log.debug("instruction: 0x{x:04}", .{instr});
        std.log.debug("registers: {any}", .{runtime.registers});

        // Conversion cannot fail
        const opcode: Opcode = @enumFromInt(bitmask.apply(.opcode, instr));

        std.log.info("{t}", .{opcode});

        // TODO:
        switch (opcode) {
            inline .add, .@"and" => |arith_opcode| {
                const dest_reg = bitmask.apply(.reg_high, instr);
                const src_reg = bitmask.apply(.reg_mid, instr);

                const rhs = if (bitmask.apply(.flag_add_and, instr) == 0) blk: {
                    if (bitmask.apply(.padding_add_and, instr) != 0)
                        std.log.warn("invalid padding for {t}", .{arith_opcode});
                    const rhs_reg = bitmask.apply(.reg_low, instr);
                    break :blk runtime.registers[rhs_reg];
                } else bitmask.applySext(.imm_5, instr);

                const lhs = runtime.registers[src_reg];
                const result = switch (arith_opcode) {
                    .add => lhs +% rhs,
                    .@"and" => lhs & rhs,
                    else => comptime unreachable,
                };
                runtime.setRegister(dest_reg, result);
            },

            .not => {
                const dest_reg = bitmask.apply(.reg_high, instr);
                const src_reg = bitmask.apply(.reg_mid, instr);
                if (bitmask.apply(.padding_not, instr) != 0b11111)
                    std.log.warn("invalid padding for not", .{});
                runtime.setRegister(dest_reg, ~runtime.registers[src_reg]);
            },

            .br => {
                const mask: u3 = bitmask.apply(.condition_mask, instr);
                // Cannot have NO flags. `BR` is assembled as `BRnzp`
                if (mask == 0b000) {
                    std.log.warn("invalid condition mask for br[nzp]", .{});
                    continue;
                }
                const pc_offset = bitmask.applySext(.pc_offset_9, instr);
                if (@intFromEnum(runtime.condition) & mask != 0) {
                    runtime.pc +%= pc_offset;
                }
            },

            .jmp_ret => {
                const base_reg = bitmask.apply(.reg_mid, instr);
                if (bitmask.apply(.padding_jmp_ret_high, instr) != 0 or
                    bitmask.apply(.padding_jmp_ret_low, instr) != 0)
                    std.log.warn("invalid padding for jmp/ret", .{});
                runtime.pc = runtime.registers[base_reg];
            },

            .lea => {
                const dest_reg = bitmask.apply(.reg_high, instr);
                const pc_offset = bitmask.applySext(.pc_offset_9, instr);
                runtime.setRegister(dest_reg, runtime.pc +% pc_offset);
            },

            .trap => {
                const trap_vect: TrapVect = @enumFromInt(bitmask.apply(.trap_vect, instr));
                std.log.info("trap 0x{x:02}", .{trap_vect});

                switch (trap_vect) {
                    .puts => {
                        var i: usize = runtime.registers[0];
                        while (true) : (i += 1) {
                            const word: u8 = @truncate(runtime.memory[i]);
                            if (word == 0x00)
                                break;
                            // TODO: Print to output object
                            std.debug.print("{c}", .{word});
                        }
                    },

                    .halt => {
                        break;
                    },

                    _ => {
                        std.log.err("unsupported trap vector: 0x{x:02}", .{trap_vect});
                    },
                    else => {
                        std.log.warn("unimplemented trap vector: {t}", .{trap_vect});
                    },
                }
            },

            else => {
                std.log.warn("unimplemented opcode: {t}", .{opcode});
                break;
            },
        }
    }
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

const bitmask = struct {
    pub const Mask = struct {
        lowest: u4,
        highest: u4,

        // Instruction metadata
        pub const opcode: Mask = .new(12, 15);
        pub const flag_add_and: Mask = .new(5, 5);
        pub const padding_add_and: Mask = .new(3, 4);
        pub const padding_not: Mask = .new(0, 5);
        pub const padding_jmp_ret_high: Mask = .new(9, 11);
        pub const padding_jmp_ret_low: Mask = .new(0, 5);
        // Operands
        pub const reg_high: Mask = .new(9, 11);
        pub const reg_mid: Mask = .new(6, 8);
        pub const reg_low: Mask = .new(0, 2);
        pub const imm_5: Mask = .new(0, 4);
        pub const trap_vect: Mask = .new(0, 8);
        pub const pc_offset_9: Mask = .new(0, 8);
        pub const condition_mask: Mask = .new(9, 11);

        fn new(lowest: u4, highest: u4) Mask {
            return .{ .lowest = lowest, .highest = highest };
        }
    };

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
