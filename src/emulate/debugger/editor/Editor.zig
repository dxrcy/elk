const Editor = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Key = @import("../Input.zig").Key;
const Live = @import("Live.zig");
const History = @import("History.zig");

live: Live,
history: History,
cursor: usize,
scrollback: ?usize,

pub fn init(gpa: Allocator, buffer: []u8) Editor {
    return .{
        .live = .{
            .buffer = buffer,
            .length = 0,
        },
        .history = .{
            .store = .empty,
            .gpa = gpa,
        },
        .cursor = 0,
        .scrollback = null,
    };
}

pub fn deinit(editor: *Editor) void {
    editor.history.store.deinit(editor.history.gpa);
}

pub fn handleKey(editor: *Editor, key: Key) !void {
    assert(editor.cursor <= editor.getString().len);

    switch (key) {
        .enter => return error.EndOfLine,
        .eot => return error.EndOfStream,

        .char => |char| editor.insert(char),
        .bs => editor.remove(),

        .escape => |escape| switch (escape) {
            .cursor_up => editor.seekHistory(.backward),
            .cursor_down => editor.seekHistory(.forward),
            .cursor_forward => editor.seekLine(.right),
            .cursor_back => editor.seekLine(.left),
        },
    }
}

pub fn setBuffer(editor: *Editor, buffer: []u8) void {
    editor.live.buffer = buffer;
}

pub fn getString(editor: *const Editor) []const u8 {
    return if (editor.scrollback) |scrollback|
        editor.history.getLast(scrollback)
    else
        editor.live.getString();
}

pub fn makeLive(editor: *Editor) void {
    const scrollback = editor.scrollback orelse
        return;

    const historic = editor.history.getLast(scrollback);
    editor.live.copyFrom(historic);
    editor.scrollback = null;
}

pub fn clear(editor: *Editor) void {
    editor.live.clear();
    editor.cursor = 0;
}

fn resetCursor(editor: *Editor) void {
    editor.cursor = editor.getString().len;
}

fn insert(editor: *Editor, char: u8) void {
    if (editor.live.length >= editor.live.buffer.len)
        return;

    editor.makeLive();
    editor.live.insert(editor.cursor, char);
    editor.cursor += 1;
}

fn remove(editor: *Editor) void {
    if (editor.cursor == 0)
        return;

    editor.makeLive();
    editor.live.remove(editor.cursor);
    editor.cursor -= 1;
}

fn seekLine(editor: *Editor, direction: enum { left, right }) void {
    switch (direction) {
        .left => if (editor.cursor > 0) {
            editor.cursor -= 1;
        },
        .right => if (editor.cursor < editor.live.length) {
            editor.cursor += 1;
        },
    }
}

fn seekHistory(editor: *Editor, direction: enum { backward, forward }) void {
    switch (direction) {
        .backward => {
            if (editor.history.length() == 0)
                return;
            if (editor.scrollback) |*scrollback| {
                if (scrollback.* + 1 < editor.history.length())
                    scrollback.* += 1;
            } else {
                editor.scrollback = 0;
            }
        },
        .forward => {
            const scrollback = editor.scrollback orelse
                return;
            editor.scrollback = if (scrollback == 0) null else scrollback - 1;
        },
    }
    editor.resetCursor();
}
