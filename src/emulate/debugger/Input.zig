const Input = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const control_code = std.ascii.control_code;

const Runtime = @import("../Runtime.zig");

length: usize,
cursor: usize,

buffer: []u8,

history: std.ArrayList(u8),
scrollback: ?usize,

reader: *Io.Reader,
writer: *Io.Writer,
gpa: Allocator,

pub fn init(gpa: Allocator, reader: *Io.Reader, writer: *Io.Writer) Input {
    return .{
        .length = 0,
        .cursor = 0,
        .buffer = &.{},
        .history = .empty,
        .scrollback = null,
        .reader = reader,
        .writer = writer,
        .gpa = gpa,
    };
}

pub fn deinit(input: *Input) void {
    input.history.deinit(input.gpa);
}

pub fn clear(input: *Input) void {
    input.length = 0;
    input.cursor = 0;
}

pub fn readLine(input: *Input) ![]const u8 {
    var eof = false;

    while (true) {
        try input.writePrompt();
        try input.writer.flush();

        const control: Runtime.Control = input.readLineChar() catch |err| switch (err) {
            else => |err2| return err2,
            error.EndOfStream => {
                eof = true;
                break;
            },
        };

        switch (control) {
            .@"continue" => continue,
            .@"break" => break,
        }
    }

    try input.writer.print("\n", .{});
    try input.writer.flush();

    if (eof)
        return error.EndOfStream;

    const line = input.buffer[0..input.length];
    input.historyPush(line);
    return line;
}

fn readLineChar(input: *Input) !Runtime.Control {
    assert(input.cursor <= input.length);

    const char = try input.readByte();

    switch (char) {
        '\n',
        => return .@"break",

        control_code.eot,
        => return error.EndOfStream,

        0x20...0x7e,
        => input.insert(char),

        control_code.bs,
        control_code.del,
        => input.remove(),

        control_code.esc => {
            if (try input.readByte() == '[') {
                switch (try input.readByte()) {
                    'A' => input.historyBack(),
                    'B' => input.historyForward(),
                    'C' => input.seek(.left),
                    'D' => input.seek(.right),
                    else => {},
                }
            }
        },

        else => {},
    }

    return .@"continue";
}

fn readByte(input: *Input) !u8 {
    var char: u8 = undefined;
    input.reader.readSliceAll(@ptrCast(&char)) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.ReadFailed,
    };
    return char;
}

fn writePrompt(input: *const Input) !void {
    const prompt = "> ";

    try input.writer.print("\r\x1b[K", .{});
    try input.writer.print("{?:04}", .{input.scrollback});
    try input.writer.print(prompt, .{});
    try input.writer.print("{s}", .{input.getCurrent()});
    try input.writer.print("\x1b[{}G", .{input.cursor + prompt.len + 1 + 4});
}

pub fn getCurrent(input: *const Input) []const u8 {
    if (input.scrollback) |scrollback| {
        return input.historyGet(scrollback);
    } else {
        return input.buffer[0..input.length];
    }
}

fn insert(input: *Input, char: u8) void {
    if (input.length >= input.buffer.len)
        return;
    input.buffer[input.length] = char;
    input.length += 1;
    input.cursor += 1;
}

fn remove(input: *Input) void {
    if (input.cursor == 0)
        return;

    // Shift characters down
    if (input.cursor < input.length) {
        for (input.cursor..input.length) |i| {
            input.buffer[i - 1] = input.buffer[i];
        }
    }

    input.cursor -= 1;
    input.length -= 1;
}

fn seek(input: *Input, direction: enum { left, right }) void {
    switch (direction) {
        .left => if (input.cursor > 0) {
            input.cursor -= 1;
        },
        .right => if (input.cursor < input.length) {
            input.cursor += 1;
        },
    }
}

fn historyBack(input: *Input) void {
    if (input.history.items.len == 0)
        return;

    if (input.scrollback) |*scrollback| {
        if (scrollback.* + 1 < input.historyLength())
            scrollback.* += 1;
    } else {
        input.scrollback = 0;
    }
}

fn historyForward(input: *Input) void {
    const scrollback = input.scrollback orelse
        return;

    input.scrollback = if (scrollback == 0) null else scrollback - 1;
}

fn historyPush(input: *Input, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0)
        return;

    input.history.ensureUnusedCapacity(input.gpa, line.len + 1) catch {
        // TODO: Shift items down until enough room is available
        return;
    };

    input.history.appendSliceAssumeCapacity(line);
    input.history.appendAssumeCapacity('\n');
}

fn historyLength(input: *const Input) usize {
    return std.mem.countScalar(u8, input.history.items, '\n');
}

fn historyGet(input: *const Input, recent_index: usize) []const u8 {
    assert(input.history.items.len > 0);

    var end: usize = input.history.items.len - 1;
    {
        var count: usize = recent_index;
        while (end > 0) : (end -= 1) {
            if (input.history.items[end] == '\n') {
                if (count == 0)
                    break;
                count -= 1;
            }
        }
    }

    const slice = input.history.items[0..end];

    return if (std.mem.findScalarLast(u8, slice, '\n')) |start|
        slice[start + 1 ..]
    else
        slice;
}
