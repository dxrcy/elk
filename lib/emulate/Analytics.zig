const Analytics = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Instruction = std.meta.Tag(@import("decode.zig").Instruction);
const Map = std.AutoHashMap;

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

time: struct {
    user_ns: u64,
    supervisor_ns: u64,
    io_ns: u64,
},

labels: Map([]const u8, u16),

instructions: InstructionMap,

executes: Map(u16, usize),

registers: struct {
    read: [8]usize,
    write: [8]usize,
},

memory: struct {
    size: ?u16,
    read: Map(u16, usize),
    write: Map(u16, usize),
},

io: struct {
    input: usize,
    output: usize,
},

pub fn init(gpa: Allocator) Analytics {
    return .{
        .time = .{
            .user_ns = 0,
            .supervisor_ns = 0,
            .io_ns = 0,
        },
        .labels = .init(gpa),
        .instructions = .{},
        .executes = .init(gpa),
        .memory = .{
            .size = null,
            .read = .init(gpa),
            .write = .init(gpa),
        },
        .registers = .{
            .read = @splat(0),
            .write = @splat(0),
        },
        .io = .{
            .input = 0,
            .output = 0,
        },
    };
}

pub fn deinit(analytics: *Analytics) void {
    analytics.labels.deinit();
    analytics.executes.deinit();
    analytics.memory.read.deinit();
    analytics.memory.write.deinit();
}

pub fn format(analytics: *const Analytics, writer: *Io.Writer) error{WriteFailed}!void {
    try writer.print("|-- time\n", .{});
    try writer.print("|   |-- user {}\n", .{analytics.time.user_ns});
    try writer.print("|   |-- supervisor {}\n", .{analytics.time.supervisor_ns});
    try writer.print("|   |-- io {}\n", .{analytics.time.io_ns});

    try writer.print("|-- labels\n", .{});
    {
        var it = analytics.labels.iterator();
        while (it.next()) |label|
            try writer.print("|   |-- {s} x{x:04}\n", .{ label.key_ptr.*, label.value_ptr.* });
    }

    try writer.print("|-- instructions\n", .{});
    inline for (std.meta.fields(Instruction)) |field|
        try writer.print(
            "|   |-- {s} {}\n",
            .{ field.name, @field(analytics.instructions, field.name) },
        );

    try writer.print("|-- execute\n", .{});
    {
        var it = analytics.executes.iterator();
        while (it.next()) |execute|
            try writer.print("|   |-- x{x:04} {}\n", .{ execute.key_ptr.*, execute.value_ptr.* });
    }

    try writer.print("|-- registers\n", .{});
    try writer.print("|   |-- read\n", .{});
    for (analytics.registers.read, 0..8) |register, i|
        try writer.print("|   |   |-- r{} {}\n", .{ i, register });
    try writer.print("|   |-- write\n", .{});
    for (analytics.registers.write, 0..8) |register, i|
        try writer.print("|       |-- r{} {}\n", .{ i, register });

    try writer.print("|-- memory\n", .{});
    try writer.print("|   |-- size {?}\n", .{analytics.memory.size});
    try writer.print("|   |-- read\n", .{});
    {
        var it = analytics.memory.read.iterator();
        while (it.next()) |memory|
            try writer.print("|   |   |-- x{x:04} {}\n", .{ memory.key_ptr.*, memory.value_ptr.* });
    }
    try writer.print("|   |-- write\n", .{});
    {
        var it = analytics.memory.write.iterator();
        while (it.next()) |memory|
            try writer.print("|       |-- x{x:04} {}\n", .{ memory.key_ptr.*, memory.value_ptr.* });
    }

    try writer.print("|-- io\n", .{});
    try writer.print("    |-- input {}\n", .{analytics.io.input});
    try writer.print("    |-- output {}\n", .{analytics.io.output});
}
