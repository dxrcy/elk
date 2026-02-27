const Runtime = @This();

const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const MEMORY_SIZE = 0x1_0000;

memory: *[MEMORY_SIZE]u16,
registers: [8]u16,
pc: u16,
condition: Condition,

tty: Tty,
writer: NewlineTracker,
io: Io,

const NewlineTracker = struct {
    is_newline: bool,
    inner: Io.File.Writer,
    interface: Io.Writer,

    pub fn new(buffer: []u8, io: Io) NewlineTracker {
        return .{
            .is_newline = true,
            .inner = Io.File.stdout().writer(io, buffer),
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = &.{},
            },
        };
    }

    pub fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const writer: *NewlineTracker = @alignCast(@fieldParentPtr("interface", io_w));

        assert(data.len <= 1);
        if (data.len == 0)
            return 0;

        const count = try writer.inner.interface.vtable.drain(&writer.inner.interface, data, splat);
        if (count > 0) {
            const index = (count / splat) - 1; // Probably correct
            writer.is_newline = data[0][index] == '\n';
        }
        return count;
    }

    pub fn ensureNewline(writer: *NewlineTracker) Io.Writer.Error!void {
        if (!writer.is_newline)
            try writer.interface.writeByte('\n');
    }
};

const Condition = enum(u3) {
    negative = 0b100,
    zero = 0b010,
    positive = 0b001,
};

pub fn init(write_buffer: []u8, io: Io, allocator: Allocator) !Runtime {
    const buffer = try allocator.alloc(u16, MEMORY_SIZE);
    @memset(buffer, 0x0000);

    return .{
        .memory = buffer[0..MEMORY_SIZE],
        .registers = @splat(0x0000),
        .pc = 0x0000,
        .condition = .zero,
        .tty = .uninit,
        .writer = .new(write_buffer, io),
        .io = io,
    };
}

pub fn deinit(runtime: Runtime, allocator: Allocator) void {
    defer allocator.free(runtime.memory);
}

pub const Error = RuntimeError || IoError;

const RuntimeError = error{
    IncorrectPadding,
    InvalidOperand,
    UnsupportedTrap,
    UnsupportedRti,
    ReservedOpcode,
};

const IoError = error{
    WriteFailed,
    ReadFailed,
    TermiosFailed,
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

fn readByte(runtime: *const Runtime) error{ReadFailed}!u8 {
    var reader = Io.File.stdin().reader(runtime.io, &.{});
    var char: u8 = undefined;
    reader.interface.readSliceAll(@ptrCast(&char)) catch
        return error.ReadFailed;
    return char;
}

pub fn run(runtime: *Runtime) Error!void {
    while (true) {
        const instr = runtime.memory[runtime.pc];
        runtime.pc +%= 1;

        // Conversion cannot fail
        const opcode: Opcode = @enumFromInt(bitmask.opcode.apply(instr));

        switch (opcode) {
            .rti => return error.UnsupportedRti,
            // TODO: Support lace stack extension (behind feature flag)
            .reserved => return error.ReservedOpcode,

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
                    _ => return error.UnsupportedTrap,

                    .halt => {
                        break;
                    },

                    inline .in, .getc => {
                        if (trap_vect == .in) {
                            try runtime.writer.ensureNewline();
                            try runtime.writer.interface.writeAll("Input> ");
                            try runtime.writer.interface.flush();
                        }

                        if (runtime.tty.state == .uninit)
                            try runtime.tty.init();
                        try runtime.tty.enableRawMode();

                        const char = try runtime.readByte();

                        try runtime.tty.disableRawMode();

                        if (trap_vect == .in) {
                            try runtime.writer.interface.writeByte(char);
                            try runtime.writer.ensureNewline();
                            try runtime.writer.interface.flush();
                        }

                        runtime.registers[0] = char;
                    },

                    .out => {
                        const word: u8 = @truncate(runtime.registers[0]);
                        try runtime.writer.interface.writeByte(word);
                        try runtime.writer.interface.flush();
                    },

                    .puts => {
                        var i: usize = runtime.registers[0];
                        while (true) : (i += 1) {
                            const word: u8 = @truncate(runtime.memory[i]);
                            if (word == 0x00)
                                break;
                            try runtime.writer.interface.writeByte(word);
                        }
                        try runtime.writer.interface.flush();
                    },

                    .putsp => {
                        var i: usize = runtime.registers[0];
                        while (true) : (i += 1) {
                            const words: [2]u8 = @bitCast(runtime.memory[i]);
                            if (words[0] == 0x00)
                                break;
                            try runtime.writer.interface.writeByte(words[1]);
                            if (words[1] == 0x00)
                                break;
                            try runtime.writer.interface.writeByte(words[1]);
                        }
                        try runtime.writer.interface.flush();
                    },

                    .putn => {
                        try runtime.writer.ensureNewline();
                        try runtime.writer.interface.print("{}\n", .{runtime.registers[0]});
                        try runtime.writer.interface.flush();
                    },

                    .reg => {
                        try runtime.printRegisters();
                        try runtime.writer.interface.flush();
                    },
                }
            },
        }
    }
}

fn printRegisters(runtime: *Runtime) error{WriteFailed}!void {
    try runtime.writer.ensureNewline();
    try runtime.writer.interface.print("+------------------------------------+\n", .{});
    try runtime.writer.interface.print("|        hex     int     uint    chr |\n", .{});

    for (runtime.registers, 0..8) |word, i| {
        try runtime.writer.interface.print("| R{}  ", .{i});
        try runtime.printIntegerForms(word);
        try runtime.writer.interface.print(" |\n", .{});
    }

    try runtime.writer.interface.print("+------------------+-----------------+\n", .{});
    try runtime.writer.interface.print(
        "|    PC  0x{x:04}    |   CC {s}   |\n",
        .{ runtime.pc, switch (runtime.condition) {
            .negative => "NEGATIVE",
            .zero => "  ZERO  ",
            .positive => "POSITIVE",
        } },
    );
    try runtime.writer.interface.print("+------------------+-----------------+\n", .{});
}

fn printIntegerForms(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    try runtime.writer.interface.print(
        "0x{x:04}  {:6}  {:7}    ",
        .{ word, word, @as(i16, @bitCast(word)) },
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

const Tty = struct {
    const HANDLE = posix.STDIN_FILENO;

    state: union(enum) {
        uninit,
        not_a_tty,
        /// Original `termios` state.
        modified: posix.termios,
        /// Original (and current) `termios` state.
        unmodified: posix.termios,
    },

    const uninit: Tty = .{ .state = .uninit };

    pub fn init(tty: *Tty) error{TermiosFailed}!void {
        assert(tty.state == .uninit);
        const termios = posix.tcgetattr(HANDLE) catch |err| switch (err) {
            error.NotATerminal => {
                tty.state = .not_a_tty;
                return;
            },
            error.Unexpected => return error.TermiosFailed,
        };
        tty.state = .{ .unmodified = termios };
    }

    pub fn enableRawMode(tty: *Tty) error{TermiosFailed}!void {
        const termios = switch (tty.state) {
            .not_a_tty => return,
            .uninit, .modified => unreachable,
            .unmodified => |termios| termios,
        };
        try setTermios(applyRawMode(termios));
        tty.state = .{ .modified = termios };
    }

    pub fn disableRawMode(tty: *Tty) error{TermiosFailed}!void {
        const termios = switch (tty.state) {
            .not_a_tty => return,
            .uninit, .unmodified => unreachable,
            .modified => |termios| termios,
        };
        try setTermios(termios);
        tty.state = .{ .unmodified = termios };
    }

    fn applyRawMode(termios: posix.termios) posix.termios {
        var termios_raw = termios;
        termios_raw.lflag.ICANON = false;
        termios_raw.lflag.ECHO = false;
        return termios_raw;
    }

    fn setTermios(termios: posix.termios) error{TermiosFailed}!void {
        posix.tcsetattr(HANDLE, .NOW, termios) catch |err| switch (err) {
            // If stdin is not a terminal, we wouldn't have the termios value.
            error.NotATerminal => unreachable,
            error.Unexpected,
            error.ProcessOrphaned,
            => return error.TermiosFailed,
        };
    }
};

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
