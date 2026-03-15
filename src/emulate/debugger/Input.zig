const Input = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const control_code = std.ascii.control_code;

const Runtime = @import("../Runtime.zig");
const Editor = @import("editor/Editor.zig");

editor: Editor,
reader: *Io.Reader,
writer: *Io.Writer,

pub const Key = union(enum) {
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

pub fn init(gpa: Allocator, reader: *Io.Reader, writer: *Io.Writer, buffer: []u8) Input {
    return .{
        .editor = .init(gpa, buffer),
        .reader = reader,
        .writer = writer,
    };
}

pub fn deinit(input: *Input) void {
    input.editor.deinit();
}

pub fn readLine(input: *Input) ![]const u8 {
    input.editor.clear();
    var eof = false;

    while (true) {
        try input.writePrompt();
        try input.writer.flush();

        const key = input.readKey() catch |err| switch (err) {
            else => |err2| return err2,
            error.EndOfStream => {
                eof = true;
                break;
            },
        } orelse
            continue;

        input.editor.handleKey(key) catch |err| switch (err) {
            else => |err2| return err2,
            error.EndOfLine => {
                break;
            },
            error.EndOfStream => {
                eof = true;
                break;
            },
        };
    }

    try input.writer.print("\n", .{});
    try input.writer.flush();

    if (eof) {
        input.editor.clear();
        return error.EndOfStream;
    }

    input.editor.makeLive();
    const line = input.editor.getString();
    input.editor.history.push(line);
    return line;
}

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
    try input.writer.print(prompt, .{});
    try input.writer.print("{s}", .{input.editor.getString()});
    try input.writer.print("\x1b[{}G", .{input.editor.cursor + prompt.len + 1});
}
