const std = @import("std");
const assert = std.debug.assert;

const Bitmask = @import("Bitmask.zig");

comptime {
    for (
        @typeInfo(Opcode).@"enum".fields,
        @typeInfo(Instruction).@"union".fields,
    ) |opcode, instruction|
        assert(std.mem.eql(u8, opcode.name, instruction.name));
}

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
    pop_push_rets_call = 0xd,
};

const bitmasks = struct {
    pub const opcode: Bitmask = .new(.unsigned, 12, 15, 4);

    pub const flag = struct {
        pub const add_and: Bitmask = .new(.unsigned, 5, 5, 1);
        pub const jsr_jsrr: Bitmask = .new(.unsigned, 11, 11, 1);
        pub const pop_push_rets_call: Bitmask = .new(.unsigned, 10, 11, 2);
    };

    pub const padding = struct {
        pub const add_and: Bitmask = .new(.unsigned, 3, 4, 2);
        pub const not: Bitmask = .new(.unsigned, 0, 5, 6);
        pub const jmp_ret_high: Bitmask = .new(.unsigned, 9, 11, 3);
        pub const jmp_ret_low: Bitmask = .new(.unsigned, 0, 5, 6);
        pub const jsrr_high: Bitmask = .new(.unsigned, 9, 11, 3);
        pub const jsrr_low: Bitmask = .new(.unsigned, 0, 5, 6);
        pub const rti: Bitmask = .new(.unsigned, 0, 11, 12);
        pub const trap: Bitmask = .new(.unsigned, 8, 11, 4);
    };

    pub const operand = struct {
        pub const reg_high: Bitmask = .new(.unsigned, 9, 11, 3);
        pub const reg_mid: Bitmask = .new(.unsigned, 6, 8, 3);
        pub const reg_low: Bitmask = .new(.unsigned, 0, 2, 3);
        pub const imm_5: Bitmask = .new(.signed, 0, 4, 5);
        pub const trap_vect: Bitmask = .new(.unsigned, 0, 7, 8);
        pub const offset_6: Bitmask = .new(.signed, 0, 5, 6);
        pub const pc_offset_9: Bitmask = .new(.signed, 0, 8, 9);
        pub const pc_offset_10: Bitmask = .new(.signed, 0, 9, 10);
        pub const pc_offset_11: Bitmask = .new(.signed, 0, 10, 11);
        pub const condition_mask: Bitmask = .new(.unsigned, 9, 11, 3);
    };
};

pub const Instruction = union(enum) {
    add: AddAndOperands,
    @"and": AddAndOperands,
    not: struct {
        dest: Register,
        src: Register,
    },
    br: struct {
        mask: u3,
        pc_offset: i9,
    },
    jmp_ret: struct {
        base: Register,
    },
    jsr_jsrr: union(enum) {
        jsr: struct {
            pc_offset: i11,
        },
        jsrr: struct {
            base: Register,
        },
    },
    lea: LeaLdLdiOperands,
    ld: LeaLdLdiOperands,
    ldi: LeaLdLdiOperands,
    ldr: struct {
        dest: Register,
        base: Register,
        offset: i6,
    },
    st: StStiOperands,
    sti: StStiOperands,
    str: struct {
        src: Register,
        base: Register,
        offset: i6,
    },
    trap: struct {
        vect: u8,
    },
    rti,
    pop_push_rets_call: union(enum) {
        pop: struct {
            dest: Register,
        },
        push: struct {
            src: Register,
        },
        rets: void,
        call: struct {
            pc_offset: i10,
        },
    },

    const AddAndOperands = struct {
        dest: Register,
        src_a: Register,
        src_b: RegImm5,
    };
    const LeaLdLdiOperands = struct {
        dest: Register,
        pc_offset: i9,
    };
    const StStiOperands = struct {
        src: Register,
        pc_offset: i9,
    };

    const Register = u3;
    const RegImm5 = union(enum) {
        register: Register,
        immediate: i5,
    };

    pub fn decode(word: u16) error{IncorrectPadding}!Instruction {
        // Conversion cannot fail
        const opcode: Opcode = @enumFromInt(bitmasks.opcode.apply(word));

        switch (opcode) {
            inline .add, .@"and" => |grouped_opcode| {
                const dest = bitmasks.operand.reg_high.apply(word);
                const src_a = bitmasks.operand.reg_mid.apply(word);
                const src_b: Instruction.RegImm5 =
                    src_b: switch (bitmasks.flag.add_and.apply(word)) {
                        0 => { // Register
                            if (bitmasks.padding.add_and.apply(word) != 0)
                                return error.IncorrectPadding;
                            break :src_b .{
                                .register = bitmasks.operand.reg_low.apply(word),
                            };
                        },
                        1 => .{
                            .immediate = bitmasks.operand.imm_5.apply(word),
                        },
                    };
                const operands: AddAndOperands = .{
                    .dest = dest,
                    .src_a = src_a,
                    .src_b = src_b,
                };
                return switch (grouped_opcode) {
                    .add => .{ .add = operands },
                    .@"and" => .{ .@"and" = operands },
                    else => comptime unreachable,
                };
            },

            .not => {
                const dest = bitmasks.operand.reg_high.apply(word);
                const src = bitmasks.operand.reg_mid.apply(word);
                if (bitmasks.padding.not.apply(word) != 0b111111)
                    return error.IncorrectPadding;
                return .{ .not = .{
                    .dest = dest,
                    .src = src,
                } };
            },

            .br => {
                const mask: u3 = bitmasks.operand.condition_mask.apply(word);
                const pc_offset = bitmasks.operand.pc_offset_9.apply(word);
                return .{ .br = .{
                    .mask = mask,
                    .pc_offset = pc_offset,
                } };
            },

            .jmp_ret => {
                const base = bitmasks.operand.reg_mid.apply(word);
                if (bitmasks.padding.jmp_ret_high.apply(word) != 0 or
                    bitmasks.padding.jmp_ret_low.apply(word) != 0)
                    return error.IncorrectPadding;
                return .{ .jmp_ret = .{
                    .base = base,
                } };
            },

            .jsr_jsrr => {
                switch (bitmasks.flag.jsr_jsrr.apply(word)) {
                    1 => { // JSR
                        const pc_offset = bitmasks.operand.pc_offset_11.apply(word);
                        return .{ .jsr_jsrr = .{
                            .jsr = .{ .pc_offset = pc_offset },
                        } };
                    },
                    0 => { // JSRR
                        if (bitmasks.padding.jsrr_high.apply(word) != 0 or
                            bitmasks.padding.jsrr_low.apply(word) != 0)
                            return error.IncorrectPadding;
                        const base = bitmasks.operand.reg_mid.apply(word);
                        return .{ .jsr_jsrr = .{
                            .jsrr = .{ .base = base },
                        } };
                    },
                }
            },

            inline .lea, .ld, .ldi => |grouped_opcode| {
                const dest = bitmasks.operand.reg_high.apply(word);
                const pc_offset = bitmasks.operand.pc_offset_9.apply(word);
                const operands: LeaLdLdiOperands = .{
                    .dest = dest,
                    .pc_offset = pc_offset,
                };
                switch (grouped_opcode) {
                    .lea => return .{ .lea = operands },
                    .ld => return .{ .ld = operands },
                    .ldi => return .{ .ldi = operands },
                    else => comptime unreachable,
                }
            },

            .ldr => {
                const dest = bitmasks.operand.reg_high.apply(word);
                const base = bitmasks.operand.reg_mid.apply(word);
                const offset = bitmasks.operand.offset_6.apply(word);
                return .{ .ldr = .{
                    .dest = dest,
                    .base = base,
                    .offset = offset,
                } };
            },

            inline .st, .sti => |grouped_opcode| {
                const src = bitmasks.operand.reg_high.apply(word);
                const pc_offset = bitmasks.operand.pc_offset_9.apply(word);
                const operands: StStiOperands = .{
                    .src = src,
                    .pc_offset = pc_offset,
                };
                switch (grouped_opcode) {
                    .st => return .{ .st = operands },
                    .sti => return .{ .sti = operands },
                    else => comptime unreachable,
                }
            },

            .str => {
                const src = bitmasks.operand.reg_high.apply(word);
                const base = bitmasks.operand.reg_mid.apply(word);
                const offset = bitmasks.operand.offset_6.apply(word);
                return .{ .str = .{
                    .src = src,
                    .base = base,
                    .offset = offset,
                } };
            },

            .trap => {
                if (bitmasks.padding.trap.apply(word) != 0)
                    return error.IncorrectPadding;
                const vect = bitmasks.operand.trap_vect.apply(word);
                return .{ .trap = .{
                    .vect = vect,
                } };
            },

            .rti => {
                if (bitmasks.padding.rti.apply(word) != 0)
                    return error.IncorrectPadding;
                return .rti;
            },

            .pop_push_rets_call => {
                switch (bitmasks.flag.pop_push_rets_call.apply(word)) {
                    0b00 => { // POP
                        const dest = bitmasks.operand.reg_mid.apply(word);
                        return .{ .pop_push_rets_call = .{
                            .pop = .{ .dest = dest },
                        } };
                    },
                    0b01 => { // PUSH
                        const src = bitmasks.operand.reg_mid.apply(word);
                        return .{ .pop_push_rets_call = .{
                            .push = .{ .src = src },
                        } };
                    },
                    0b10 => { // RETS
                        return .{
                            .pop_push_rets_call = .rets,
                        };
                    },
                    0b11 => { // CALL
                        const pc_offset = bitmasks.operand.pc_offset_10.apply(word);
                        return .{ .pop_push_rets_call = .{
                            .call = .{ .pc_offset = pc_offset },
                        } };
                    },
                }
            },
        }
    }

    pub fn format(instruction: Instruction, writer: *std.Io.Writer) error{WriteFailed}!void {
        // TODO: Print negative PC offsets as -0x1 not 0x-1
        switch (instruction) {
            .add => |operands| {
                try writer.print(" add r{} r{}", .{ operands.dest, operands.src_a });
                switch (operands.src_b) {
                    .register => |register| try writer.print(" r{}", .{register}),
                    .immediate => |immediate| try writer.print(" 0x{x}", .{immediate}),
                }
            },

            .@"and" => |operands| {
                try writer.print(" and r{} r{}", .{ operands.dest, operands.src_a });
                switch (operands.src_b) {
                    .register => |register| try writer.print(" r{}", .{register}),
                    .immediate => |immediate| try writer.print(" 0x{x}", .{immediate}),
                }
            },

            .not => |operands| {
                try writer.print(" not r{} r{}", .{ operands.dest, operands.src });
            },

            .br => |operands| {
                const mnemonic = switch (operands.mask) {
                    0b000, 0b111 => "br",
                    0b100 => "brn",
                    0b010 => "brz",
                    0b001 => "brp",
                    0b110 => "brnz",
                    0b011 => "brzp",
                    0b101 => "brnp",
                };
                try writer.print("{s:4} 0x{x}", .{ mnemonic, operands.pc_offset });
            },

            .jmp_ret => |operands| {
                if (operands.base == 7)
                    try writer.print(" ret", .{})
                else
                    try writer.print(" jmp r{}", .{operands.base});
            },

            .jsr_jsrr => |variant| switch (variant) {
                .jsr => |operands| {
                    try writer.print(" jsr 0x{x}", .{operands.pc_offset});
                },
                .jsrr => |operands| {
                    try writer.print("jsrr r{}", .{operands.base});
                },
            },

            .lea, .ld, .ldi => |operands, opcode| {
                try writer.print("{t:4} r{} 0x{x}", .{ opcode, operands.dest, operands.pc_offset });
            },

            .ldr => |operands| {
                try writer.print(" ldr r{} r{} 0x{x}", .{ operands.dest, operands.base, operands.offset });
            },

            .st, .sti => |operands, opcode| {
                try writer.print("{t:4} r{} 0x{x}", .{ opcode, operands.src, operands.pc_offset });
            },

            .str => |operands| {
                try writer.print(" str r{} r{} 0x{x}", .{ operands.src, operands.base, operands.offset });
            },

            .trap => |operands| {
                try writer.print("trap 0x{x:02}", .{operands.vect});
            },

            .rti => {
                try writer.print(" rti", .{});
            },

            .pop_push_rets_call => |variant| switch (variant) {
                .pop => |operands| {
                    try writer.print(" pop r{}", .{operands.dest});
                },
                .push => |operands| {
                    try writer.print("push r{}", .{operands.src});
                },
                .rets => {
                    try writer.print("rets", .{});
                },
                .call => |operands| {
                    try writer.print("call 0x{x}", .{operands.pc_offset});
                },
            },
        }
    }
};
