const Breakpoints = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Air = @import("../../compile/Air.zig");
const Debugger = @import("Debugger.zig");

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

pub fn initFrom(
    gpa: Allocator,
    air: *const Air,
) error{OutOfMemory}!Breakpoints {
    var breakpoints: Breakpoints = .init(gpa);
    assert(air.lines.items.len + air.origin <= std.math.maxInt(u16));
    for (air.labels.items) |*label| {
        if (label.kind != .breakpoint)
            continue;
        // May not have been inserted, if multiple breakpoint labels exist for a line
        _ = try breakpoints.insert(label.index + air.origin, true);
    }
    return breakpoints;
}

pub fn contains(breakpoints: *const Breakpoints, address: u16) bool {
    for (breakpoints.entries.items) |entry| {
        if (entry.address == address)
            return true;
    }
    return false;
}

pub fn insert(breakpoints: *Breakpoints, address: u16, is_label: bool) error{OutOfMemory}!bool {
    if (breakpoints.contains(address))
        return false;

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
