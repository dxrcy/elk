const History = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

store: std.ArrayList(u8),
gpa: Allocator,

pub fn readFromFile(history: *History, io: Io, file: Io.File) !void {
    try readFileAlloc(io, history.gpa, file, &history.store);
}

fn readFileAlloc(io: Io, gpa: Allocator, file: Io.File, list: *std.ArrayList(u8)) !void {
    const size = try file.length(io);
    try list.ensureTotalCapacity(gpa, size + 1); // Add trailing \n

    const bytes_read = try file.readPositionalAll(io, list.allocatedSlice(), 0);
    assert(bytes_read == size);
    list.items.len = size;
    list.appendAssumeCapacity('\n');
}

pub fn clear(history: *History) void {
    history.store.clearAndFree(history.gpa);
}

pub fn length(history: *const History) usize {
    return std.mem.countScalar(u8, history.store.items, '\n');
}

pub fn push(history: *History, line: []const u8) error{OutOfMemory}!void {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    assert(trimmed.len == line.len);
    assert(trimmed.len > 0);
    if (history.store.items.len > 0)
        assert(history.store.items[history.store.items.len - 1] == '\n');

    // Don't push sequential duplicates
    if (history.store.items.len > 0) {
        if (std.mem.eql(u8, line, history.getLast(0)))
            return;
    }

    history.store.ensureUnusedCapacity(history.gpa, line.len + 1) catch
        try history.shiftToEnsureUnusedCapacity(line.len + 1);

    history.store.appendSliceAssumeCapacity(line);
    history.store.appendAssumeCapacity('\n');
}

fn shiftToEnsureUnusedCapacity(history: *History, additional_count: usize) error{OutOfMemory}!void {
    assert(history.store.items.len + additional_count > history.store.capacity);

    const new_start = history.findShiftIndex(additional_count) orelse
        return error.OutOfMemory;

    for (0.., new_start..history.store.items.len) |i, j|
        history.store.items[i] = history.store.items[j];
    history.store.items.len -= new_start;

    assert(history.store.items.len + additional_count <= history.store.capacity);
}

fn findShiftIndex(history: *const History, additional_count: usize) ?usize {
    if (history.store.items.len < additional_count)
        return null;

    var unused_capacity: usize = 0;
    while (unused_capacity < history.store.items.len) {
        const rest = history.store.items[unused_capacity..];
        const next_line_length = std.mem.findScalar(u8, rest, '\n') orelse
            break;
        unused_capacity += next_line_length + "\n".len;
        if (unused_capacity >= additional_count)
            return unused_capacity;
    }
    return history.store.items.len;
}

pub fn getLast(history: *const History, recent_index: usize) []const u8 {
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
