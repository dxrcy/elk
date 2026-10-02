const Analytics = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.AutoHashMap;
const assert = std.debug.assert;

const Instruction = std.meta.Tag(@import("decode.zig").Instruction);

// TODO: Add more instruction-specific variants
// Eg. br is struct{ n: usize, nz: usize, ... }
// Eg. add is struct{ reg: usize, immediate: usize }
// Eg. Split pop_push_rets_call
const InstructionMap = struct {
    add: usize = 0,
    @"and": usize = 0,
    not: usize = 0,
    br: usize = 0,
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
};

const Data = struct {
    time: struct {
        total: Io.Duration,
        supervisor: Io.Duration,
        io: Io.Duration,
        // TODO: Add 'debug' time, including debugger, runtime hooks, etc
    },
    labels: Map([]const u8, u16),
    instructions: InstructionMap,
    executes: Map(u16, usize),
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
            .time = .{
                .total = .zero,
                .supervisor = .zero,
                .io = .zero,
            },
            .labels = .init(gpa),
            .instructions = .{},
            .executes = .init(gpa),
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
        data.labels.deinit();
        data.executes.deinit();
        data.memory.read.deinit();
        data.memory.write.deinit();
    }

    pub fn format(data: *const Data, writer: *Io.Writer) error{WriteFailed}!void {
        try writer.print("|-- time\n", .{});
        try writer.print("|   |-- total {f}\n", .{data.time.total});
        try writer.print("|   |-- supervisor {f}\n", .{data.time.supervisor});
        try writer.print("|   |-- io {f}\n", .{data.time.io});

        try writer.print("|-- labels\n", .{});
        {
            var it = data.labels.iterator();
            while (it.next()) |label|
                try writer.print("|   |-- {s} x{x:04}\n", .{ label.key_ptr.*, label.value_ptr.* });
        }

        try writer.print("|-- instructions\n", .{});
        inline for (std.meta.fields(Instruction)) |field|
            try writer.print(
                "|   |-- {s} {}\n",
                .{ field.name, @field(data.instructions, field.name) },
            );

        try writer.print("|-- execute\n", .{});
        {
            var it = data.executes.iterator();
            while (it.next()) |execute|
                try writer.print("|   |-- x{x:04} {}\n", .{ execute.key_ptr.*, execute.value_ptr.* });
        }

        try writer.print("|-- registers\n", .{});
        try writer.print("|   |-- read\n", .{});
        for (data.registers.read, 0..8) |register, i|
            try writer.print("|   |   |-- r{} {}\n", .{ i, register });
        try writer.print("|   |-- write\n", .{});
        for (data.registers.write, 0..8) |register, i|
            try writer.print("|       |-- r{} {}\n", .{ i, register });

        try writer.print("|-- memory\n", .{});
        try writer.print("|   |-- size {}\n", .{data.memory.size});
        try writer.print("|   |-- read\n", .{});
        {
            var it = data.memory.read.iterator();
            while (it.next()) |memory|
                try writer.print("|   |   |-- x{x:04} {}\n", .{ memory.key_ptr.*, memory.value_ptr.* });
        }
        try writer.print("|   |-- write\n", .{});
        {
            var it = data.memory.write.iterator();
            while (it.next()) |memory|
                try writer.print("|       |-- x{x:04} {}\n", .{ memory.key_ptr.*, memory.value_ptr.* });
        }

        try writer.print("|-- io\n", .{});
        try writer.print("    |-- read {}\n", .{data.io.read});
        try writer.print("    |-- write {}\n", .{data.io.write});
    }
};

data: Data,
io: Io,
time: struct {
    total: ?Io.Timestamp,
    supervisor: ?Io.Timestamp,
    io: ?Io.Timestamp,
    // TODO: Add 'debug' time, including debugger, runtime hooks, etc
},

pub fn init(io: Io, gpa: Allocator) Analytics {
    return .{
        .data = .init(gpa),
        .io = io,
        .time = .{
            .total = null,
            .supervisor = null,
            .io = null,
        },
    };
}

pub fn deinit(analytics: *Analytics) void {
    analytics.data.deinit();
}

pub fn addInstruction(analytics: *Analytics, instruction: Instruction) void {
    switch (instruction) {
        inline else => |tag| {
            @field(analytics.data.instructions, @tagName(tag)) += 1;
        },
    }
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

pub fn addIoRead(analytics: *Analytics) void {
    analytics.data.io.read += 1;
}

pub fn addIoWrite(analytics: *Analytics) void {
    analytics.data.io.write += 1;
}

const Mode = enum {
    total,
    supervisor,
};

pub fn startTime(analytics: *Analytics, comptime mode: Mode) void {
    assert(@field(analytics.time, @tagName(mode)) == null);
    @field(analytics.time, @tagName(mode)) = .now(analytics.io, .awake);
}

pub fn endTime(analytics: *Analytics, comptime mode: Mode) void {
    const then = @field(analytics.time, @tagName(mode)) orelse
        unreachable;
    @field(analytics.time, @tagName(mode)) = null;

    const duration = then.untilNow(analytics.io, .awake);
    @field(analytics.data.time, @tagName(mode)) = .{
        .nanoseconds = @field(analytics.data.time, @tagName(mode)).nanoseconds +
            duration.nanoseconds,
    };
}
