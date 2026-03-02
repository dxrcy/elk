const std = @import("std");
const assert = std.debug.assert;

const Mask = @import("Mask.zig");

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

comptime {
    for (
        @typeInfo(Opcode).@"enum".fields,
        @typeInfo(Instruction).@"union".fields,
    ) |opcode, instr|
        assert(std.mem.eql(u8, opcode.name, instr.name));
}

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

    pub const Register = u3;
    pub const RegImm5 = union(enum) {
        register: Register,
        immediate: i5,
    };

    pub fn decode(word: u16) error{IncorrectPadding}!Instruction {
        // Conversion cannot fail
        const opcode: Opcode = @enumFromInt(bitmask.opcode.apply(word));

        switch (opcode) {
            inline .add, .@"and" => |grouped_opcode| {
                const dest = bitmask.operand.reg_high.apply(word);
                const src_a = bitmask.operand.reg_mid.apply(word);
                const src_b: Instruction.RegImm5 =
                    src_b: switch (bitmask.flag.add_and.apply(word)) {
                        0 => { // Register
                            if (bitmask.padding.add_and.apply(word) != 0)
                                return error.IncorrectPadding;
                            break :src_b .{
                                .register = bitmask.operand.reg_low.apply(word),
                            };
                        },
                        1 => .{
                            .immediate = bitmask.operand.imm_5.applySigned(word),
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
                const dest = bitmask.operand.reg_high.apply(word);
                const src = bitmask.operand.reg_mid.apply(word);
                if (bitmask.padding.not.apply(word) != 0b111111)
                    return error.IncorrectPadding;
                return .{ .not = .{
                    .dest = dest,
                    .src = src,
                } };
            },

            .br => {
                const mask: u3 = bitmask.operand.condition_mask.apply(word);
                const pc_offset = bitmask.operand.pc_offset_9.applySigned(word);
                return .{ .br = .{
                    .mask = mask,
                    .pc_offset = pc_offset,
                } };
            },

            .jmp_ret => {
                const base = bitmask.operand.reg_mid.apply(word);
                if (bitmask.padding.jmp_ret_high.apply(word) != 0 or
                    bitmask.padding.jmp_ret_low.apply(word) != 0)
                    return error.IncorrectPadding;
                return .{ .jmp_ret = .{
                    .base = base,
                } };
            },

            .jsr_jsrr => {
                switch (bitmask.flag.jsr_jsrr.apply(word)) {
                    1 => { // JSR
                        const pc_offset = bitmask.operand.pc_offset_11.applySigned(word);
                        return .{ .jsr_jsrr = .{
                            .jsr = .{ .pc_offset = pc_offset },
                        } };
                    },
                    0 => { // JSRR
                        if (bitmask.padding.jsrr_high.apply(word) != 0 or
                            bitmask.padding.jsrr_low.apply(word) != 0)
                            return error.IncorrectPadding;
                        const base = bitmask.operand.reg_mid.apply(word);
                        return .{ .jsr_jsrr = .{
                            .jsrr = .{ .base = base },
                        } };
                    },
                }
            },

            inline .lea, .ld, .ldi => |grouped_opcode| {
                const dest = bitmask.operand.reg_high.apply(word);
                const pc_offset = bitmask.operand.pc_offset_9.applySigned(word);
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
                const dest = bitmask.operand.reg_high.apply(word);
                const base = bitmask.operand.reg_mid.apply(word);
                const offset = bitmask.operand.offset_6.applySigned(word);
                return .{ .ldr = .{
                    .dest = dest,
                    .base = base,
                    .offset = offset,
                } };
            },

            inline .st, .sti => |grouped_opcode| {
                const src = bitmask.operand.reg_high.apply(word);
                const pc_offset = bitmask.operand.pc_offset_9.applySigned(word);
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
                const src = bitmask.operand.reg_high.apply(word);
                const base = bitmask.operand.reg_mid.apply(word);
                const offset = bitmask.operand.offset_6.applySigned(word);
                return .{ .str = .{
                    .src = src,
                    .base = base,
                    .offset = offset,
                } };
            },

            .trap => {
                const vect = bitmask.operand.trap_vect.apply(word);
                return .{ .trap = .{
                    .vect = vect,
                } };
            },

            .rti => {
                return .rti;
            },

            .pop_push_rets_call => {
                switch (bitmask.flag.pop_push_rets_call.apply(word)) {
                    0b00 => { // POP
                        const dest = bitmask.operand.reg_mid.apply(word);
                        return .{ .pop_push_rets_call = .{
                            .pop = .{ .dest = dest },
                        } };
                    },
                    0b01 => { // PUSH
                        const src = bitmask.operand.reg_mid.apply(word);
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
                        const pc_offset = bitmask.operand.pc_offset_10.applySigned(word);
                        return .{ .pop_push_rets_call = .{
                            .call = .{ .pc_offset = pc_offset },
                        } };
                    },
                }
            },
        }
    }
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
        pub const trap_vect: Mask = .new(0, 7);
        pub const offset_6: Mask = .new(0, 5);
        pub const pc_offset_9: Mask = .new(0, 8);
        pub const pc_offset_10: Mask = .new(0, 9);
        pub const pc_offset_11: Mask = .new(0, 10);
        pub const condition_mask: Mask = .new(9, 11);
    };
};
