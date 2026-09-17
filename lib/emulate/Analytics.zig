const Analytics = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Instruction = std.meta.Tag(@import("decode.zig").Instruction);
const Map = std.AutoHashMap;

time: struct {
    user_ns: u64,
    supervisor_ns: u64,
    io_ns: u64,
},

labels: Map([]const u8, u16),

instruction: std.EnumMap(Instruction, usize),
instruction_branch: [8]usize,
instruction_trap: [256]usize,

execute: Map(u16, usize),

memory: struct {
    size: ?u16,
    read: Map(u16, usize),
    write: Map(u16, usize),
},

register: struct {
    read: [8]usize,
    write: [8]usize,
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
        .instruction = .initFull(0),
        .instruction_branch = @splat(0),
        .instruction_trap = @splat(0),
        .execute = .init(gpa),
        .memory = .{
            .size = null,
            .read = .init(gpa),
            .write = .init(gpa),
        },
        .register = .{
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
    analytics.execute.deinit();
    analytics.memory.read.deinit();
    analytics.memory.write.deinit();
}
