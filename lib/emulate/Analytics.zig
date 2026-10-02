const Analytics = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.AutoHashMap;
const assert = std.debug.assert;

const elk = @import("../root.zig");
const Provider = elk.Provider;
const Instruction = @import("decode.zig").Instruction;

const Data = struct {
    // TODO: Add 'debug' time, including debugger, runtime hooks, etc
    const Time = enum { total, supervisor, io };

    // TODO: Add more instruction-specific variants
    // Eg. br is struct{ n: usize, nz: usize, ... }
    // Eg. add is struct{ reg: usize, immediate: usize }
    // Eg. Split pop_push_rets_call
    const Instructions = struct {
        regular: struct {
            add: usize = 0,
            @"and": usize = 0,
            not: usize = 0,
            jmp_ret: usize = 0,
            jsr_jsrr: usize = 0,
            lea: usize = 0,
            ld: usize = 0,
            ldi: usize = 0,
            ldr: usize = 0,
            st: usize = 0,
            sti: usize = 0,
            str: usize = 0,
            trap: usize = 0,
            rti: usize = 0,
            pop_push_rets_call: usize = 0,
            noop: usize = 0,
        } = .{},
        br: struct {
            n: usize = 0,
            z: usize = 0,
            p: usize = 0,
            nz: usize = 0,
            zp: usize = 0,
            np: usize = 0,
            nzp: usize = 0,
        } = .{},
    };

    time: std.EnumArray(Time, Io.Duration),
    symbols: std.StringHashMap(u16),
    instructions: Instructions,
    addresses: Map(u16, usize),
    registers: struct {
        read: [8]usize,
        write: [8]usize,
    },
    memory: struct {
        size: u16,
        read: Map(u16, usize),
        write: Map(u16, usize),
    },
    io: struct {
        read: usize,
        write: usize,
    },

    pub fn init(gpa: Allocator) Data {
        return .{
            .time = .initFill(.zero),
            .symbols = .init(gpa),
            .instructions = .{},
            .addresses = .init(gpa),
            .memory = .{
                .size = 0,
                .read = .init(gpa),
                .write = .init(gpa),
            },
            .registers = .{
                .read = @splat(0),
                .write = @splat(0),
            },
            .io = .{
                .read = 0,
                .write = 0,
            },
        };
    }

    pub fn deinit(data: *Data) void {
        data.symbols.deinit();
        data.addresses.deinit();
        data.memory.read.deinit();
        data.memory.write.deinit();
    }

    pub fn format(data: *const Data, writer: *Io.Writer) error{WriteFailed}!void {
        // TODO: This whole function is quite ugly -- clean it up!

        const user_time: Io.Duration = .{
            .nanoseconds = data.time.get(.total).nanoseconds -
                data.time.get(.supervisor).nanoseconds,
        };
        try writer.print("|-- time {f}\n", .{data.time.get(.total)});
        try writer.print("|   |-- user {f}\n", .{user_time});
        try writer.print("|   |-- supervisor {f}\n", .{data.time.get(.supervisor)});
        try writer.print("|   |-- io {f}\n", .{data.time.get(.io)});

        try writer.print("|-- symbol {}\n", .{data.symbols.count()});
        {
            var it = data.symbols.iterator();
            while (it.next()) |symbol|
                try writer.print("|   |-- {s} x{x:04}\n", .{ symbol.key_ptr.*, symbol.value_ptr.* });
        }

        {
            var count: usize = 0;
            inline for (std.meta.fields(@TypeOf(data.instructions.regular))) |field|
                count += @field(data.instructions.regular, field.name);
            inline for (std.meta.fields(@TypeOf(data.instructions.br))) |field|
                count += @field(data.instructions.br, field.name);
            try writer.print("|-- instruction {}\n", .{count});
        }
        inline for (std.meta.fields(@TypeOf(data.instructions.regular))) |field| {
            const count = @field(data.instructions.regular, field.name);
            if (count > 0)
                try writer.print(
                    "|   |-- {s} {}\n",
                    .{ field.name, count },
                );
        }

        {
            var count: usize = 0;
            inline for (std.meta.fields(@TypeOf(data.instructions.br))) |field|
                count += @field(data.instructions.br, field.name);
            try writer.print("|   |-- br {}\n", .{count});
        }
        inline for (std.meta.fields(@TypeOf(data.instructions.br))) |field| {
            const count = @field(data.instructions.br, field.name);
            if (count > 0)
                try writer.print(
                    "|       |-- {s} {}\n",
                    .{ field.name, @field(data.instructions.br, field.name) },
                );
        }

        {
            var count: usize = 0;
            var it = data.addresses.iterator();
            while (it.next()) |address|
                count += address.value_ptr.*;
            try writer.print("|-- address {}\n", .{count});
        }
        {
            var it = data.addresses.iterator();
            while (it.next()) |address|
                try writer.print("|   |-- x{x:04} {}\n", .{ address.key_ptr.*, address.value_ptr.* });
        }

        try writer.print("|-- register\n", .{});
        {
            var count: usize = 0;
            for (data.registers.read) |register| count += register;
            try writer.print("|   |-- read {}\n", .{count});
        }
        for (data.registers.read, 0..8) |register, i|
            try writer.print("|   |   |-- r{} {}\n", .{ i, register });
        {
            var count: usize = 0;
            for (data.registers.write) |register| count += register;
            try writer.print("|   |-- write {}\n", .{count});
        }
        for (data.registers.write, 0..8) |register, i|
            try writer.print("|       |-- r{} {}\n", .{ i, register });

        try writer.print("|-- memory\n", .{});
        try writer.print("|   |-- size {}\n", .{data.memory.size});
        {
            var count: usize = 0;
            var it = data.memory.read.iterator();
            while (it.next()) |memory|
                count += memory.value_ptr.*;
            try writer.print("|   |-- read {}\n", .{count});
        }
        {
            var it = data.memory.read.iterator();
            while (it.next()) |memory|
                try writer.print("|   |   |-- x{x:04} {}\n", .{ memory.key_ptr.*, memory.value_ptr.* });
        }
        {
            var count: usize = 0;
            var it = data.memory.write.iterator();
            while (it.next()) |memory|
                count += memory.value_ptr.*;
            try writer.print("|   |-- write {}\n", .{count});
        }
        {
            var it = data.memory.write.iterator();
            while (it.next()) |memory|
                try writer.print("|       |-- x{x:04} {}\n", .{ memory.key_ptr.*, memory.value_ptr.* });
        }

        try writer.print("|-- io {}\n", .{data.io.read + data.io.write});
        try writer.print("    |-- read {}\n", .{data.io.read});
        try writer.print("    |-- write {}\n", .{data.io.write});
    }
};

data: Data,
io: Io,
time: std.EnumArray(Data.Time, ?Io.Timestamp),

pub fn init(io: Io, gpa: Allocator) Analytics {
    return .{
        .data = .init(gpa),
        .io = io,
        .time = .initFill(null),
    };
}

pub fn deinit(analytics: *Analytics) void {
    analytics.data.deinit();
}

pub fn startTime(analytics: *Analytics, comptime mode: Data.Time) void {
    assert(analytics.time.get(mode) == null);
    analytics.time.set(mode, .now(analytics.io, .awake));
}

pub fn endTime(analytics: *Analytics, comptime mode: Data.Time) void {
    const then = analytics.time.get(mode) orelse
        unreachable;
    analytics.time.set(mode, null);

    const duration = then.untilNow(analytics.io, .awake);
    analytics.data.time.set(mode, .{
        .nanoseconds = analytics.data.time.get(mode).nanoseconds + duration.nanoseconds,
    });
}

pub fn addSymbols(analytics: *Analytics, provider: Provider) error{OutOfMemory}!void {
    switch (provider) {
        .none => {},
        .assembly => |assembly| {
            for (assembly.air.labels.items) |label|
                try analytics.data.symbols.putNoClobber(
                    label.span.view(assembly.source), // FIXME: UAF possibility???
                    label.index + assembly.air.origin,
                );
        },
        .symbols => |symbols| {
            for (symbols.items) |symbol|
                try analytics.data.symbols.putNoClobber(
                    symbol.name, // FIXME: UAF possibility???
                    symbol.address,
                );
        },
    }
}

pub fn addInstruction(analytics: *Analytics, instruction: Instruction) void {
    switch (instruction) {
        inline else => |_, tag| {
            @field(analytics.data.instructions.regular, @tagName(tag)) += 1;
        },
        .br => |br| switch (br.mask) {
            0b000 => analytics.data.instructions.regular.noop += 1,
            0b100 => analytics.data.instructions.br.n += 1,
            0b010 => analytics.data.instructions.br.z += 1,
            0b001 => analytics.data.instructions.br.p += 1,
            0b110 => analytics.data.instructions.br.nz += 1,
            0b011 => analytics.data.instructions.br.zp += 1,
            0b101 => analytics.data.instructions.br.np += 1,
            0b111 => analytics.data.instructions.br.nzp += 1,
        },
    }
}

pub fn addAddress(analytics: *Analytics, address: u16) error{OutOfMemory}!void {
    try analytics.data.addresses.put(
        address,
        (analytics.data.addresses.get(address) orelse 0) + 1,
    );
}

pub fn addRegisterRead(analytics: *Analytics, register: u3) void {
    analytics.data.registers.read[register] += 1;
}

pub fn addRegisterWrite(analytics: *Analytics, register: u3) void {
    analytics.data.registers.write[register] += 1;
}

pub fn setMemorySize(analytics: *Analytics, size: u16) void {
    analytics.data.memory.size = size;
}

pub fn addMemoryRead(analytics: *Analytics, address: u16) error{OutOfMemory}!void {
    try analytics.data.memory.read.put(
        address,
        (analytics.data.memory.read.get(address) orelse 0) + 1,
    );
}

pub fn addMemoryWrite(analytics: *Analytics, address: u16) error{OutOfMemory}!void {
    try analytics.data.memory.write.put(
        address,
        (analytics.data.memory.write.get(address) orelse 0) + 1,
    );
}

pub fn addIoRead(analytics: *Analytics) void {
    analytics.data.io.read += 1;
}

pub fn addIoWrite(analytics: *Analytics) void {
    analytics.data.io.write += 1;
}
