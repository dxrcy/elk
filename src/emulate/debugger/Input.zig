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
    ctrl_c,
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

fn readKey(input: *Input) error{ EndOfStream, ReadFailed, WriteFailed }!?Key {
    var reader: KeyReader = .{ .reader = input.reader, .writer = input.writer };
    try reader.enableKittyProtocol();
    const key = try reader.readKey();
    try reader.disableKittyProtocol();
    return key;
}

const KeyReader = struct {
    reader: *Io.Reader,
    writer: *Io.Writer,

    pub fn enableKittyProtocol(key_reader: *KeyReader) error{WriteFailed}!void {
        key_reader.writer.writeAll("\x1b[>1u") catch
            return error.WriteFailed;
        key_reader.writer.flush() catch
            return error.WriteFailed;
    }

    pub fn disableKittyProtocol(key_reader: *KeyReader) error{WriteFailed}!void {
        key_reader.writer.writeAll("\x1b[<u") catch
            return error.WriteFailed;
        key_reader.writer.flush() catch
            return error.WriteFailed;
    }

    pub fn readKey(key_reader: *KeyReader) error{ EndOfStream, ReadFailed, WriteFailed }!?Key {
        var sequence: Sequence = .{ .buffer = undefined, .len = 0 };
        try key_reader.readSequence(&sequence);

        const slice = sequence.buffer[0..sequence.len];
        assert(slice.len > 0);

        switch (slice[0]) {
            control_code.esc => {},
            control_code.cr, control_code.lf => return .enter,
            control_code.bs, control_code.del => return .bs,
            else => return .{ .char = slice[0] },
        }

        if (slice.len < 2 or slice[1] != '[')
            return null;

        const csi = slice[2..];

        if (std.mem.eql(u8, csi, "99;5u"))
            return .ctrl_c;

        const escape_sequences = [_]struct { []const u8, Key.Escape }{
            .{ "A", .cursor_up },
            .{ "B", .cursor_down },
            .{ "C", .cursor_forward },
            .{ "D", .cursor_back },
        };

        for (escape_sequences) |entry| {
            const key, const value = entry;
            if (std.mem.eql(u8, csi, key))
                return .{ .escape = value };
        }

        std.debug.print("[{s}]\n", .{csi});

        return null;
    }

    fn readSequence(key_reader: *KeyReader, sequence: *Sequence) error{ EndOfStream, ReadFailed }!void {
        switch (try key_reader.readByte(sequence)) {
            else => {},

            control_code.esc => {
                if (try key_reader.readByte(sequence) != '[')
                    return;

                var i: usize = 0;
                while (i < 10) : (i += 1) {
                    const char = try key_reader.readByte(sequence);

                    switch (char) {
                        '0'...'9' => {},
                        ';' => {},
                        else => break,
                    }
                }
            },
        }
    }

    const Sequence = struct {
        buffer: [20]u8,
        len: usize,
    };

    fn readByte(key_reader: *KeyReader, sequence: *Sequence) error{ EndOfStream, ReadFailed }!u8 {
        assert(sequence.buffer.len > sequence.len);
        const byte = &sequence.buffer[sequence.len];
        key_reader.reader.readSliceAll(@ptrCast(byte)) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        sequence.len += 1;
        return byte.*;
    }
};

fn writePrompt(input: *const Input) !void {
    const prompt = "> ";
    try input.writer.print("\r\x1b[K", .{});
    try input.writer.print("{t:8}", .{input.editor.mode});
    try input.writer.print(prompt, .{});
    try input.writer.print("{s}", .{input.editor.getString()});
    try input.writer.print("\x1b[{}G", .{input.editor.cursor + prompt.len + 1 + 8});
}
