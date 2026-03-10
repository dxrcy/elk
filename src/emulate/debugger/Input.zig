const Input = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const control_code = std.ascii.control_code;

const Runtime = @import("../Runtime.zig");

lines: Lines,

reader: *Io.Reader,
writer: *Io.Writer,

pub fn init(gpa: Allocator, reader: *Io.Reader, writer: *Io.Writer) Input {
    return .{
        .lines = .{
            .edit = .{
                .buffer = &.{},
                .length = 0,
            },
            .history = .{
                .store = .empty,
                .gpa = gpa,
            },
            .cursor = 0,
            .scrollback = null,
        },
        .reader = reader,
        .writer = writer,
    };
}

pub fn deinit(input: *Input) void {
    input.lines.history.store.deinit(input.lines.history.gpa);
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

    input.lines.becomeActive();
    const line = input.lines.getCurrent();
    input.lines.history.push(line);
    return line;
}

fn handleNextKey(input: *Input) error{ EndOfStream, ReadFailed }!Runtime.Control {
    assert(input.lines.cursor <= input.lines.getCurrent().len);

    const key = try input.readKey() orelse
        return .@"continue";

    switch (key) {
        .enter => return .@"break",
        .eot => return error.EndOfStream,

        .char => |char| input.lines.insert(char),
        .bs => input.lines.remove(),

        .escape => |escape| switch (escape) {
            .cursor_up => input.lines.historyBack(),
            .cursor_down => input.lines.historyForward(),
            .cursor_forward => input.lines.seek(.right),
            .cursor_back => input.lines.seek(.left),
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
    try input.writer.print("{?:04}", .{input.lines.scrollback});
    try input.writer.print(prompt, .{});
    try input.writer.print("{s}", .{input.lines.getCurrent()});
    try input.writer.print("\x1b[{}G", .{input.lines.cursor + prompt.len + 1 + 4});
}

const Lines = struct {
    edit: Edit,
    history: History,
    cursor: usize,
    scrollback: ?usize,

    pub fn getCurrent(lines: *const Lines) []const u8 {
        if (lines.scrollback) |scrollback| {
            return lines.history.getLast(scrollback);
        } else {
            return lines.edit.buffer[0..lines.edit.length];
        }
    }

    pub fn becomeActive(lines: *Lines) void {
        const scrollback = lines.scrollback orelse
            return;

        const historic = lines.history.getLast(scrollback);

        const length = @min(historic.len, lines.edit.buffer.len);
        @memcpy(lines.edit.buffer[0..length], historic[0..length]);
        lines.edit.length = length;

        lines.scrollback = null;
    }

    pub fn resetCursor(lines: *Lines) void {
        lines.cursor = lines.getCurrent().len;
    }

    pub fn clear(lines: *Lines) void {
        lines.edit.length = 0;
        lines.cursor = 0;
    }

    pub fn insert(lines: *Lines, char: u8) void {
        if (lines.edit.length >= lines.edit.buffer.len)
            return;

        lines.becomeActive();

        lines.edit.buffer[lines.edit.length] = char;
        lines.edit.length += 1;
        lines.cursor += 1;
    }

    pub fn remove(lines: *Lines) void {
        if (lines.cursor == 0)
            return;

        lines.becomeActive();

        // Shift characters down
        if (lines.cursor < lines.edit.length) {
            for (lines.cursor..lines.edit.length) |i| {
                lines.edit.buffer[i - 1] = lines.edit.buffer[i];
            }
        }

        lines.edit.length -= 1;
        lines.cursor -= 1;
    }

    pub fn seek(lines: *Lines, direction: enum { left, right }) void {
        switch (direction) {
            .left => if (lines.cursor > 0) {
                lines.cursor -= 1;
            },
            .right => if (lines.cursor < lines.edit.length) {
                lines.cursor += 1;
            },
        }
    }

    pub fn historyBack(lines: *Lines) void {
        if (lines.history.length() == 0)
            return;

        if (lines.scrollback) |*scrollback| {
            if (scrollback.* + 1 < lines.history.length())
                scrollback.* += 1;
        } else {
            lines.scrollback = 0;
        }

        lines.resetCursor();
    }

    pub fn historyForward(lines: *Lines) void {
        const scrollback = lines.scrollback orelse
            return;

        lines.scrollback = if (scrollback == 0) null else scrollback - 1;

        lines.resetCursor();
    }
};

const Edit = struct {
    buffer: []u8,
    length: usize,
};

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
