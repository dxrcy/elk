const Operand = @import("Air.zig").Operand;

/// Note that some instructions (`Statement` variants) share the same 4-bit
/// opcode, eg. `jsr` and `jsrr`, which are distinguished by a flag bit.
pub const Statement = union(enum) {
    raw_word: u16,

    add: struct {
        dest: Operand.Register,
        src_a: Operand.Register,
        src_b: Operand.RegImm5,
    },
    @"and": struct {
        dest: Operand.Register,
        src_a: Operand.Register,
        src_b: Operand.RegImm5,
    },
    not: struct {
        dest: Operand.Register,
        src: Operand.Register,
    },
    br: struct {
        condition: Operand.ConditionMask,
        dest: Operand.PcOffset(9),
    },
    jmp: struct {
        base: Operand.Register,
    },
    ret: struct {},
    jsr: struct {
        dest: Operand.PcOffset(11),
    },
    jsrr: struct {
        base: Operand.Register,
    },
    lea: struct {
        dest: Operand.Register,
        src: Operand.PcOffset(9),
    },
    ld: struct {
        dest: Operand.Register,
        src: Operand.PcOffset(9),
    },
    ldi: struct {
        dest: Operand.Register,
        src: Operand.PcOffset(9),
    },
    ldr: struct {
        dest: Operand.Register,
        base: Operand.Register,
        offset: Operand.Offset6,
    },
    st: struct {
        src: Operand.Register,
        dest: Operand.PcOffset(9),
    },
    sti: struct {
        src: Operand.Register,
        dest: Operand.PcOffset(9),
    },
    str: struct {
        src: Operand.Register,
        base: Operand.Register,
        offset: Operand.Offset6,
    },
    trap: struct {
        vect: Operand.TrapVect,
    },
    push: struct {
        src: Operand.Register,
    },
    pop: struct {
        dest: Operand.Register,
    },
    call: struct {
        dest: Operand.PcOffset(10),
    },
    rets: struct {},
    rti: struct {},

    pub fn encode(statement: Statement) u16 {
        switch (statement) {
            .raw_word => |raw| {
                return raw;
            },
            .add => |operands| {
                var raw: u16 = 0x1000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.src_a.value.bits() << 6;
                raw |= operands.src_b.value.bits();
                return raw;
            },
            .@"and" => |operands| {
                var raw: u16 = 0x5000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.src_a.value.bits() << 6;
                raw |= operands.src_b.value.bits();
                return raw;
            },
            .not => |operands| {
                var raw: u16 = 0x9000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.src.value.bits() << 6;
                raw |= 0b111111;
                return raw;
            },
            .br => |operands| {
                var raw: u16 = 0x0000;
                raw |= operands.condition.value.bits() << 9;
                raw |= operands.dest.value.bits();
                return raw;
            },
            .jmp => |operands| {
                var raw: u16 = 0xc000;
                raw |= operands.base.value.bits() << 6;
                return raw;
            },
            .ret => {
                return 0xc1c0;
            },
            .jsr => |operands| {
                var raw: u16 = 0x4800;
                raw |= operands.dest.value.bits();
                return raw;
            },
            .jsrr => |operands| {
                var raw: u16 = 0x4000;
                raw |= operands.base.value.bits() << 6;
                return raw;
            },
            .lea => |operands| {
                var raw: u16 = 0xe000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.src.value.bits();
                return raw;
            },
            .ld => |operands| {
                var raw: u16 = 0x2000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.src.value.bits();
                return raw;
            },
            .ldi => |operands| {
                var raw: u16 = 0xa000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.src.value.bits();
                return raw;
            },
            .ldr => |operands| {
                var raw: u16 = 0x6000;
                raw |= operands.dest.value.bits() << 9;
                raw |= operands.base.value.bits() << 6;
                raw |= operands.offset.value.bits();
                return raw;
            },
            .st => |operands| {
                var raw: u16 = 0x3000;
                raw |= operands.src.value.bits() << 9;
                raw |= operands.dest.value.bits();
                return raw;
            },
            .sti => |operands| {
                var raw: u16 = 0xb000;
                raw |= operands.src.value.bits() << 9;
                raw |= operands.dest.value.bits();
                return raw;
            },
            .str => |operands| {
                var raw: u16 = 0x7000;
                raw |= operands.src.value.bits() << 9;
                raw |= operands.base.value.bits() << 6;
                raw |= operands.offset.value.bits();
                return raw;
            },
            .trap => |operands| {
                var raw: u16 = 0xf000;
                raw |= operands.vect.value.bits();
                return raw;
            },
            .push => |operands| {
                var raw: u16 = 0xd400;
                raw |= operands.src.value.bits() << 6;
                return raw;
            },
            .pop => |operands| {
                var raw: u16 = 0xd000;
                raw |= operands.dest.value.bits() << 6;
                return raw;
            },
            .call => |operands| {
                var raw: u16 = 0xdc00;
                raw |= operands.dest.value.bits();
                return raw;
            },
            .rets => {
                return 0xd800;
            },
            .rti => {
                return 0x8000;
            },
        }
    }
};
