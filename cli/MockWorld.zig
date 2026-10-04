// Simulates a superflat Minecraft world in memory
// - sparse block overrides over deterministic fallback terrain
// - fake player position
const MockWorld = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const mcz = @import("mcz");

const elk = @import("elk");

player: mcz.Coordinate = .{ .x = 0, .y = 0, .z = 0 },
blocks: std.AutoHashMap(mcz.Coordinate, mcz.Block),

pub const max_height: i32 = 319;
pub const min_height: i32 = -64;

pub fn init(gpa: Allocator) MockWorld {
    return .{ .blocks = .init(gpa) };
}

pub fn deinit(mock: *MockWorld) void {
    mock.blocks.deinit();
}

fn fallback(coordinate: mcz.Coordinate) mcz.Block {
    return switch (coordinate.y) {
        min_height + 3 => mcz.blocks.grass,
        min_height + 2 => mcz.blocks.dirt,
        min_height + 1 => mcz.blocks.dirt,
        min_height => mcz.blocks.bedrock,
        else => mcz.blocks.air,
    };
}

pub fn getBlock(mock: *const MockWorld, coordinate: mcz.Coordinate) mcz.Block {
    return mock.blocks.get(coordinate) orelse fallback(coordinate);
}

pub fn setBlock(
    mock: *MockWorld,
    coordinate: mcz.Coordinate,
    block: mcz.Block,
) Allocator.Error!void {
    if (coordinate.y < min_height or coordinate.y > max_height)
        return;
    try mock.blocks.put(coordinate, block);
}

pub fn getHeight(mock: *const MockWorld, coordinate: mcz.Coordinate2D) i32 {
    var y: i32 = max_height;
    while (y >= min_height) : (y -= 1) {
        if (mock.getBlock(coordinate.withHeight(y)).id != mcz.blocks.air.id)
            return y;
    }
    return min_height;
}

pub fn chat(runtime: *elk.Runtime, mock: *MockWorld) elk.Traps.Result {
    _ = mock;
    try runtime.ensureWriterNewline();
    for ("(chat) ") |byte| {
        try runtime.writeChar(byte);
    }
    for (runtime.state.memory[runtime.state.registers[0]..]) |word| {
        if (word == 0x0000)
            break;
        const byte: u8 = @truncate(word);
        const char = switch (byte) {
            '\n' | '\t' => ' ',
            '\x20'...'\x7e' => byte,
            else => continue,
        };
        try runtime.writeChar(char);
    }
    try runtime.writeChar('\n');
    try runtime.writer.flush();
}

pub fn getp(runtime: *elk.Runtime, mock: *MockWorld) elk.Traps.Result {
    runtime.state.registers[0] = toWord(mock.player.x);
    runtime.state.registers[1] = toWord(mock.player.y);
    runtime.state.registers[2] = toWord(mock.player.z);
}

pub fn setp(runtime: *elk.Runtime, mock: *MockWorld) elk.Traps.Result {
    mock.player = .{
        .x = fromWord(runtime.state.registers[0]),
        .y = fromWord(runtime.state.registers[1]),
        .z = fromWord(runtime.state.registers[2]),
    };
}

pub fn getb(runtime: *elk.Runtime, mock: *MockWorld) elk.Traps.Result {
    const coordinate: mcz.Coordinate = .{
        .x = fromWord(runtime.state.registers[0]),
        .y = fromWord(runtime.state.registers[1]),
        .z = fromWord(runtime.state.registers[2]),
    };
    runtime.state.registers[3] = @truncate(mock.getBlock(coordinate).id);
}

pub fn setb(runtime: *elk.Runtime, mock: *MockWorld) elk.Traps.Result {
    const coordinate: mcz.Coordinate = .{
        .x = fromWord(runtime.state.registers[0]),
        .y = fromWord(runtime.state.registers[1]),
        .z = fromWord(runtime.state.registers[2]),
    };
    const block: mcz.Block = .{
        .id = runtime.state.registers[3],
        .mod = 0,
    };
    try mock.setBlock(coordinate, block);
}

pub fn geth(runtime: *elk.Runtime, mock: *MockWorld) elk.Traps.Result {
    const coordinate: mcz.Coordinate2D = .{
        .x = fromWord(runtime.state.registers[0]),
        .z = fromWord(runtime.state.registers[2]),
    };
    runtime.state.registers[1] = toWord(mock.getHeight(coordinate));
}

fn toWord(value: i32) u16 {
    return @bitCast(@as(i16, @truncate(value)));
}

fn fromWord(value: u16) i32 {
    return @as(i16, @bitCast(value));
}
