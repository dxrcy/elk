const Input = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const control_code = std.ascii.control_code;

const Runtime = @import("../Runtime.zig");

buffer: []u8,
history: History,

length: usize,
cursor: usize,
scrollback: ?usize,

reader: *Io.Reader,
writer: *Io.Writer,

pub fn init(gpa: Allocator, reader: *Io.Reader, writer: *Io.Writer) Input {
    return .{
        .buffer = &.{},
        .history = .{ .store = .empty, .gpa = gpa },
        .length = 0,
        .cursor = 0,
        .scrollback = null,
        .reader = reader,
        .writer = writer,
    };
}

pub fn deinit(input: *Input) void {
    input.history.store.deinit(input.history.gpa);
}

pub fn readLine(input: *Input) ![]const u8 {
    var eof = false;

    while (true) {
        try input.writePrompt();
        try input.writer.flush();

        const control: Runtime.Control = input.handleNextKey() catch |err| switch (err) {
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

    input.becomeActive();
    const line = input.getCurrent();
    input.history.push(line);
    return line;
}

fn handleNextKey(input: *Input) error{ EndOfStream, ReadFailed }!Runtime.Control {
    assert(input.cursor <= input.getCurrent().len);

    const key = try input.readKey() orelse
        return .@"continue";

    switch (key) {
        .enter => return .@"break",
        .eot => return error.EndOfStream,

        .char => |char| input.insert(char),
        .bs => input.remove(),

        .escape => |escape| switch (escape) {
            .cursor_up => input.historyBack(),
            .cursor_down => input.historyForward(),
            .cursor_forward => input.seek(.right),
            .cursor_back => input.seek(.left),
        },
    }
    return .@"continue";
}

const Key = union(enum) {
    char: u8,
    enter,
    eot,
    bs,
    escape: Escape,

    pub const Escape = enum {
        cursor_up,
        cursor_down,
        cursor_forward,
        cursor_back,
    };
};

fn readKey(input: *Input) error{ EndOfStream, ReadFailed }!?Key {
    return switch (try input.readByte()) {
        0x20...0x7e => |char| .{ .char = char },

        '\n' => .enter,
        control_code.eot => .eot,
        control_code.bs, control_code.del => .bs,

        control_code.esc => if (try input.readByte() == '[') {
            const escape: Key.Escape = switch (try input.readByte()) {
                'A' => .cursor_up,
                'B' => .cursor_down,
                'C' => .cursor_forward,
                'D' => .cursor_back,
                else => return null,
            };
            return .{ .escape = escape };
        } else null,

        else => null,
    };
}

fn readByte(input: *Input) error{ EndOfStream, ReadFailed }!u8 {
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

fn getCurrent(input: *const Input) []const u8 {
    if (input.scrollback) |scrollback| {
        return input.history.getLast(scrollback);
    } else {
        return input.buffer[0..input.length];
    }
}

fn resetCursor(input: *Input) void {
    input.cursor = input.getCurrent().len;
}

fn becomeActive(input: *Input) void {
    const scrollback = input.scrollback orelse
        return;

    const historic = input.history.getLast(scrollback);

    const length = @min(historic.len, input.buffer.len);
    @memcpy(input.buffer[0..length], historic[0..length]);
    input.length = length;

    input.scrollback = null;
}

pub fn clear(input: *Input) void {
    input.length = 0;
    input.cursor = 0;
}

fn insert(input: *Input, char: u8) void {
    if (input.length >= input.buffer.len)
        return;

    input.becomeActive();

    input.buffer[input.length] = char;
    input.length += 1;
    input.cursor += 1;
}

fn remove(input: *Input) void {
    if (input.cursor == 0)
        return;

    input.becomeActive();

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
    if (input.history.length() == 0)
        return;

    if (input.scrollback) |*scrollback| {
        if (scrollback.* + 1 < input.history.length())
            scrollback.* += 1;
    } else {
        input.scrollback = 0;
    }

    input.resetCursor();
}

fn historyForward(input: *Input) void {
    const scrollback = input.scrollback orelse
        return;

    input.scrollback = if (scrollback == 0) null else scrollback - 1;

    input.resetCursor();
}

const History = struct {
    store: std.ArrayList(u8),
    gpa: Allocator,

    fn push(history: *History, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0)
            return;

        // Don't push sequential duplicates
        if (history.store.items.len > 0) {
            if (std.mem.eql(u8, trimmed, history.getLast(0)))
                return;
        }

        history.store.ensureUnusedCapacity(history.gpa, line.len + 1) catch {
            // TODO: Shift items down until enough room is available
            return;
        };

        history.store.appendSliceAssumeCapacity(line);
        history.store.appendAssumeCapacity('\n');
    }

    fn length(history: *const History) usize {
        return std.mem.countScalar(u8, history.store.items, '\n');
    }

    fn getLast(history: *const History, recent_index: usize) []const u8 {
        assert(history.store.items.len > 0);

        var end: usize = history.store.items.len - 1;
        {
            var count: usize = recent_index;
            while (end > 0) : (end -= 1) {
                if (history.store.items[end] == '\n') {
                    if (count == 0)
                        break;
                    count -= 1;
                }
            }
        }

        const slice = history.store.items[0..end];

        return if (std.mem.findScalarLast(u8, slice, '\n')) |start|
            slice[start + 1 ..]
        else
            slice;
    }
};
