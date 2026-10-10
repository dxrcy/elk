const Runtime = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const elk = @import("../root.zig");
const Policies = elk.Policies;
const Traps = elk.Traps;
const Provider = elk.Provider;
const Debugger = @import("debugger/Debugger.zig");
const Tty = @import("Tty.zig");

pub const Callback = @import("../callback.zig").Callback;
pub const Instruction = @import("decode.zig").Instruction;
pub const Analytics = @import("Analytics.zig");

pub const memory_size = 0x1_0000;
pub const user_memory_start = 0x3000;
pub const user_memory_end = 0xFDFF;
const memory_init_user = 0x0000;
const memory_init_privileged = 0xdead;

// Avoid directly read OR modify **memory or general-purpose registers** *from within runtime base*
// (ie. from within this file).
// ALWAYS use helpers such as `runtime.setMemory`, and pass `.untracked` to opt-out of analytics.
// This ensures that analytics are tracked properly.
// These values may be read/modified OUTSIDE of runtime base (eg. by debugger or runtime callsite),
// and for other uses (such as `printRegisters`), since analytics should not track this.
// Note that this requirement does NOT (currently) include PC or condition code.
state: State,

traps: *const Traps,
hooks: Hooks,
analytics: Analytics,
policies: Policies,
debugger: ?*Debugger,
use_decoration: bool,
instruction_limit: ?usize,
instruction_count: usize,

reader: *Io.Reader,
writer: *Io.Writer,
writer_is_newline: bool,
tty: Tty,

/// Whether to track an action via analytics.
const Track = enum {
    tracked,
    untracked,

    /// Includes `OutOfMemory` in error set `E`, if `.tracked`.
    pub fn ErrorSet(comptime track: Track, E: type) type {
        _ = @typeInfo(E).error_set;
        return switch (track) {
            .tracked => return E || error{OutOfMemory},
            .untracked => return E,
        };
    }
};

pub const State = struct {
    memory: *[memory_size]u16,
    registers: [8]u16,
    pc: u16,
    condition: Condition,

    pub fn init(gpa: Allocator, random: ?std.Random) Allocator.Error!State {
        const memory = try gpa.create([memory_size]u16);

        if (random) |rand| {
            rand.bytes(std.mem.sliceAsBytes(memory));
        } else {
            @memset(memory[0..memory_size], memory_init_privileged);
            @memset(memory[user_memory_start .. user_memory_end + 1], memory_init_user);
        }

        // Hack for `Random.array` until #36929 is merged into stdlib
        const registers: [8]u16 = if (random) |rand| @bitCast(rand.array(u8, 2 * 8)) else @splat(0);
        const condition = if (random) |rand| rand.enumValue(Condition) else .zero;

        return .{
            .memory = memory,
            .registers = registers,
            .pc = 0x0000,
            .condition = condition,
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
        defer gpa.destroy(state.memory);
    }
};

const Error = Exception || HostError;

/// The user's program or configuration (traps, policies) is erroneous.
pub const Exception = error{
    IncorrectPadding,
    UnhandledTrap,
    UnsupportedRti,
    UnpermittedOpcode,
    UnpermittedMemoryAccess,
    TrapFailed,
    InstructionLimitReached,
};

/// Stdio or terminal failure.
pub const HostError =
    Allocator.Error ||
    Io.Writer.Error ||
    Io.Reader.Error ||
    error{ EndOfStream, TermiosFailed };

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
    io: Io,
    gpa: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    traps: *const Traps,
    hooks: Hooks = .{},
    policies: Policies,
    debugger: ?*Debugger = null,
    random: ?std.Random = null,
    use_decoration: bool = true,
    instruction_limit: ?usize = null,
}) !Runtime {
    return .{
        .state = try .init(params.gpa, params.random),
        .traps = params.traps,
        .analytics = .init(params.io, params.gpa),
        .hooks = params.hooks,
        .policies = params.policies,
        .debugger = params.debugger,
        .use_decoration = params.use_decoration,
        .reader = params.reader,
        .writer = params.writer,
        .writer_is_newline = true,
        .tty = .uninit,
        .instruction_limit = params.instruction_limit,
        .instruction_count = 0,
    };
}

pub fn deinit(runtime: *Runtime, gpa: Allocator) void {
    runtime.state.deinit(gpa);
    runtime.analytics.deinit();
}

pub fn readFromFile(runtime: *Runtime, io: Io, file: Io.File, buffer: []u8) !void {
    var reader = file.reader(io, buffer);

    const origin = reader.interface.takeInt(u16, .big) catch |err| switch (err) {
        else => |e| return e,
        error.EndOfStream => return error.FileTooSmall,
    };
    runtime.state.pc = origin;

    var i: u16 = 0;
    while (true) : (i += 1) {
        const high = reader.interface.takeByte() catch |err| switch (err) {
            else => |e| return e,
            error.EndOfStream => break,
        };
        const low = reader.interface.takeByte() catch |err| switch (err) {
            else => |e| return e,
            error.EndOfStream => return error.FileNotAligned,
        };
        const word = (@as(u16, high) << 8) | low;
        const address = std.math.cast(u16, origin + i) orelse
            return error.FileTooLarge;
        try runtime.setMemory(address, word, .untracked);
    }

    runtime.analytics.setSize(i);
}

pub fn patchLabelValue(
    runtime: *Runtime,
    name: []const u8,
    raw_word: u16,
    symbols: Provider.Symbols,
) error{ SymbolNotFound, UnpermittedMemoryAccess }!void {
    const address = symbols.getAddress(name) orelse
        return error.SymbolNotFound;
    try runtime.setMemory(address, raw_word, .untracked);
}

pub fn run(runtime: *Runtime) Error!void {
    runtime.analytics.startTime(.total);
    defer runtime.analytics.endTime(.total);

    if (runtime.debugger) |debugger|
        try debugger.startMessage(runtime.use_decoration);

    while (true) {
        if (runtime.debugger) |debugger| {
            if (try debugger.invoke(runtime)) |control| switch (control) {
                .@"continue" => continue,
                .@"break" => break,
            };
        }

        runtime.runNextInstruction() catch |err| switch (err) {
            error.OutOfMemory,
            error.WriteFailed,
            error.ReadFailed,
            error.EndOfStream,
            error.TermiosFailed,
            => |err2| return err2,

            else => |event| {
                if (runtime.debugger) |debugger| {
                    if (debugger.state.status != .inactive) {
                        try debugger.catchEvent(event, runtime);
                        continue;
                    }
                }
                switch (event) {
                    error.Halt => break,
                    else => |exception| return exception,
                }
            },
        };
    }
}

fn runNextInstruction(runtime: *Runtime) (Error || error{Halt})!void {
    // Track execution before fetching, this is more helpful.
    try runtime.analytics.addMemoryExecute(runtime.state.pc);
    const word = try runtime.getMemory(runtime.state.pc, .untracked);
    runtime.state.pc += 1;

    if (runtime.hooks.pre_decode) |pre_decode|
        try pre_decode.call(.{ runtime, word });

    const instruction: Instruction = try .decode(word);
    try runtime.runInstruction(instruction);
}

pub fn runInstruction(runtime: *Runtime, instruction: Instruction) (Error || error{Halt})!void {
    if (runtime.hooks.pre_execute) |pre_execute|
        try pre_execute.call(.{ runtime, instruction });

    if (runtime.debugger) |debugger|
        try debugger.preExecute(runtime, instruction);

    if (runtime.instruction_limit) |limit| {
        if (runtime.instruction_count >= limit)
            return error.InstructionLimitReached;
        runtime.instruction_count += 1;
    }

    runtime.analytics.addInstruction(instruction);

    switch (instruction) {
        inline .add, .@"and" => |operands, subset| {
            const lhs = runtime.getRegister(operands.src_a, .tracked);
            const rhs: u16 = switch (operands.src_b) {
                .register => |register| runtime.getRegister(register, .tracked),
                .immediate => |immediate| signExtend(immediate),
            };
            runtime.setRegister(operands.dest, switch (subset) {
                .add => lhs +% rhs,
                .@"and" => lhs & rhs,
                else => comptime unreachable,
            }, .tracked);
        },
        .not => |operands| {
            runtime.setRegister(
                operands.dest,
                ~runtime.getRegister(operands.src, .tracked),
                .tracked,
            );
        },

        .br => |operands| {
            // No-op case
            if (operands.mask == 0b000)
                return;
            if (@intFromEnum(runtime.state.condition) & operands.mask != 0)
                runtime.state.pc +%= signExtend(operands.pc_offset);
        },

        .jmp_ret => |operands| {
            runtime.state.pc = runtime.getRegister(operands.base, .tracked);
        },
        .jsr_jsrr => |variant| {
            const previous_pc = runtime.state.pc;
            switch (variant) {
                .jsr => |operands| {
                    runtime.state.pc +%= signExtend(operands.pc_offset);
                },
                .jsrr => |operands| {
                    runtime.state.pc = runtime.getRegister(operands.base, .tracked);
                },
            }
            runtime.setRegisterNoCc(7, previous_pc, .tracked);
        },

        .lea => |operands| {
            const address = runtime.state.pc +% signExtend(operands.pc_offset);
            runtime.setRegisterNoCc(operands.dest, address, .tracked);
        },
        .ld => |operands| {
            const address = runtime.state.pc +% signExtend(operands.pc_offset);
            const value = try runtime.getMemory(address, .tracked);
            runtime.setRegister(operands.dest, value, .tracked);
        },
        .ldi => |operands| {
            const indirect = runtime.state.pc +% signExtend(operands.pc_offset);
            const address = try runtime.getMemory(indirect, .tracked);
            const value = try runtime.getMemory(address, .tracked);
            runtime.setRegister(operands.dest, value, .tracked);
        },
        .ldr => |operands| {
            const address = runtime.getRegister(operands.base, .tracked) +% signExtend(
                operands.offset,
            );
            const value = try runtime.getMemory(address, .tracked);
            runtime.setRegister(operands.dest, value, .tracked);
        },
        .st => |operands| {
            const address = runtime.state.pc +% signExtend(operands.pc_offset);
            try runtime.setMemory(address, runtime.getRegister(operands.src, .tracked), .tracked);
        },
        .sti => |operands| {
            const indirect = runtime.state.pc +% signExtend(operands.pc_offset);
            const address = try runtime.getMemory(indirect, .tracked);
            try runtime.setMemory(address, runtime.getRegister(operands.src, .tracked), .tracked);
        },
        .str => |operands| {
            const address = runtime.getRegister(operands.base, .tracked) +%
                signExtend(operands.offset);
            try runtime.setMemory(address, runtime.getRegister(operands.src, .tracked), .tracked);
        },

        .trap => |operands| {
            const callback = runtime.traps.entries[operands.vect].callback orelse
                // No trap callback declared
                // Either trap was never registered, or only registered for alias
                return error.UnhandledTrap;
            runtime.analytics.startTime(.supervisor);
            defer runtime.analytics.endTime(.supervisor);
            try callback.call(.{runtime});
        },

        .rti => return error.UnsupportedRti,
        .reserved => return error.UnpermittedOpcode,
    }
}

fn getRegister(runtime: *Runtime, register: u3, comptime track: Track) u16 {
    if (track == .tracked)
        runtime.analytics.addRegisterRead(register);
    return runtime.state.registers[register];
}

fn setRegister(runtime: *Runtime, register: u3, value: u16, comptime track: Track) void {
    runtime.setRegisterNoCc(register, value, track);
    runtime.state.condition = asConditionCode(value);
}

// TODO: Rename from "cc" to "condition (code)"
fn setRegisterNoCc(runtime: *Runtime, register: u3, value: u16, comptime track: Track) void {
    if (track == .tracked)
        runtime.analytics.addRegisterWrite(register);
    runtime.state.registers[register] = value;
}

pub fn asConditionCode(value: u16) Condition {
    return if (@as(i16, @bitCast(value)) < 0)
        .negative
    else if (value == 0)
        .zero
    else
        .positive;
}

pub fn getMemory(
    runtime: *Runtime,
    address: u16,
    comptime track: Track,
) track.ErrorSet(error{UnpermittedMemoryAccess})!u16 {
    try runtime.checkMemoryAccess(address);
    if (track == .tracked)
        try runtime.analytics.addMemoryRead(address);
    return runtime.state.memory[address];
}

pub fn setMemory(
    runtime: *Runtime,
    address: u16,
    value: u16,
    comptime track: Track,
) track.ErrorSet(error{UnpermittedMemoryAccess})!void {
    try runtime.checkMemoryAccess(address);
    if (track == .tracked)
        try runtime.analytics.addMemoryWrite(address);
    runtime.state.memory[address] = value;
}

pub fn checkMemoryAccess(runtime: *const Runtime, address: u16) error{UnpermittedMemoryAccess}!void {
    if (runtime.policies.extension.supervisor_memory == .permit)
        return;
    switch (address) {
        user_memory_start...user_memory_end => {},
        else => return error.UnpermittedMemoryAccess,
    }
}

pub fn readByte(runtime: *const Runtime) error{ EndOfStream, EndOfText, ReadFailed }!u8 {
    var char: u8 = undefined;
    runtime.reader.readSliceAll(@ptrCast(&char)) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.ReadFailed,
    };
    return switch (char) {
        else => char,
        std.ascii.control_code.etx => error.EndOfText,
    };
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

    if (!runtime.use_decoration) {
        for (runtime.state.registers, 0..8) |word, i|
            try runtime.writer.print("r{} x{X:04}\n", .{ i, word });
        try runtime.writer.print("PC x{X:04}\n", .{runtime.state.pc});
        try runtime.writer.print("CC {b:03}\n", .{runtime.state.condition});
        return;
    }

    try runtime.writer.print("+----------------------------------+\n", .{});
    try runtime.writer.print("|       hex      int    uint   chr |\n", .{});

    for (runtime.state.registers, 0..8) |word, i| {
        try runtime.writer.print("| r{}  ", .{i});
        try runtime.printIntegerForms(word);
        try runtime.writer.print(" |\n", .{});
    }

    try runtime.writer.print("+----------------+-----------------+\n", .{});
    try runtime.writer.print(
        "|    PC x{X:04}    |   CC {s}   |\n",
        .{ runtime.state.pc, switch (runtime.state.condition) {
            .negative => "NEGATIVE",
            .zero => "  ZERO  ",
            .positive => "POSITIVE",
        } },
    );
    try runtime.writer.print("+----------------+-----------------+\n", .{});
}

pub fn printInteger(runtime: *Runtime, integer: u16) error{WriteFailed}!void {
    try runtime.ensureWriterNewline();

    if (!runtime.use_decoration) {
        try runtime.writer.print("x{X:04}\n", .{integer});
        return;
    }

    try runtime.writer.print("+------------------------------+\n", .{});
    try runtime.writer.print("|   hex      int    uint   chr |\n", .{});

    try runtime.writer.print("| ", .{});
    try runtime.printIntegerForms(integer);
    try runtime.writer.print(" |\n", .{});

    try runtime.writer.print("+------------------------------+\n", .{});
}

fn printIntegerForms(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    assert(runtime.use_decoration);
    try runtime.writer.print(
        "x{X:04}  {:7}  {:6}   ",
        .{ word, @as(i16, @bitCast(word)), word },
    );
    try runtime.printDisplayChar(word);
}

fn printDisplayChar(runtime: *Runtime, word: u16) error{WriteFailed}!void {
    assert(runtime.use_decoration);
    const ascii = [0x80]*const [3]u8{
        "NUL", "SOH", "STX",  "ETX", "EOT",  "ENQ", "ACK", "BEL",
        " BS", " HT", " LF",  " VT", " FF",  " CR", " SO", " SI",
        "DLE", "DC1", "DC2",  "DC3", "DC4",  "NAK", "SYN", "ETB",
        "CAN", " EM", "SUB",  "ESC", " FS",  " GS", " RS", " US",
        " SP", " ! ", " \" ", " # ", " $ ",  " % ", " & ", " ' ",
        " ( ", " ) ", " * ",  " + ", " , ",  " - ", " . ", " / ",
        " 0 ", " 1 ", " 2 ",  " 3 ", " 4 ",  " 5 ", " 6 ", " 7 ",
        " 8 ", " 9 ", " : ",  " ; ", " < ",  " = ", " > ", " ? ",
        " @ ", " A ", " B ",  " C ", " D ",  " E ", " F ", " G ",
        " H ", " I ", " J ",  " K ", " L ",  " M ", " N ", " O ",
        " P ", " Q ", " R ",  " S ", " T ",  " U ", " V ", " W ",
        " X ", " Y ", " Z ",  " [ ", " \\ ", " ] ", " ^ ", " _ ",
        " ` ", " a ", " b ",  " c ", " d ",  " e ", " f ", " g ",
        " h ", " i ", " j ",  " k ", " l ",  " m ", " n ", " o ",
        " p ", " q ", " r ",  " s ", " t ",  " u ", " v ", " w ",
        " x ", " y ", " z ",  " { ", " | ",  " } ", " ~ ", "DEL",
    };
    const display = if (word > 0x7F) "---" else ascii[word];
    try runtime.writer.print("{s}", .{display});
}

pub fn stringzAt(runtime: *Runtime, address: u16) Stringz {
    return .{
        .runtime = runtime,
        .address = address,
        .end = false,
    };
}

pub const Stringz = struct {
    runtime: *Runtime,
    address: u16,
    end: bool,

    pub fn next(stringz: *Stringz) error{ UnpermittedMemoryAccess, OutOfMemory }!?u16 {
        if (stringz.end)
            return null;
        const word = try stringz.runtime.getMemory(stringz.address, .untracked);
        if (word == 0x0000) {
            stringz.end = true;
            return null;
        }
        stringz.address += 1;
        return word;
    }
};

pub fn signExtend(value: anytype) u16 {
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
