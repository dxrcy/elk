const Runtime = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MEMORY_SIZE = 0x1_0000;

memory: *[MEMORY_SIZE]u16,

pub fn init(allocator: Allocator) !Runtime {
    const buffer = try allocator.alloc(u16, MEMORY_SIZE);
    @memset(buffer, 0x0000);

    return .{
        .memory = buffer[0..MEMORY_SIZE],
    };
}

pub fn deinit(runtime: Runtime, allocator: Allocator) void {
    defer allocator.free(runtime.memory);
}
