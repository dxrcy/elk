const Breakpoints = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

entries: std.ArrayList(Entry),
gpa: Allocator,

const Entry = struct {
    address: u16,
    is_label: bool,
};

pub fn init(gpa: Allocator) Breakpoints {
    return .{ .entries = .empty, .gpa = gpa };
}

pub fn deinit(breakpoints: *Breakpoints) void {
    breakpoints.entries.deinit(breakpoints.gpa);
}

pub fn insert(breakpoints: *Breakpoints, address: u16, is_label: bool) error{OutOfMemory}!bool {
    for (breakpoints.entries.items) |entry| {
        if (entry.address == address)
            return false;
    }

    var index: usize = breakpoints.entries.items.len;
    for (breakpoints.entries.items, 0..) |entry, i| {
        if (entry.address >= address) {
            index = i;
            break;
        }
    }

    try breakpoints.entries.insert(
        breakpoints.gpa,
        index,
        .{ .address = address, .is_label = is_label },
    );
    return true;
}

pub fn remove(breakpoints: *Breakpoints, address: u16) bool {
    var new_length: usize = 0;
    for (0..breakpoints.entries.items.len) |j| {
        if (breakpoints.entries.items[j].address == address)
            continue;
        breakpoints.entries.items[new_length] = breakpoints.entries.items[j];
        new_length += 1;
    }

    const removed = new_length < breakpoints.entries.items.len;
    breakpoints.entries.shrinkRetainingCapacity(new_length);
    return removed;
}
