const History = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

store: std.ArrayList(u8),
gpa: Allocator,

pub fn length(history: *const History) usize {
    return std.mem.countScalar(u8, history.store.items, '\n');
}

pub fn push(history: *History, line: []const u8) void {
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
