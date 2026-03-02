const Traps = @This();

const std = @import("std");
const assert = std.debug.assert;

const Runtime = @import("emulate/Runtime.zig");
const builtin_traps = @import("emulate/builtin_traps.zig");

entries: [1 << 8]?Entry,

pub const Error =
    Runtime.IoError ||
    error{ TrapFailed, Halt };

pub const Result = Error!void;

pub const Entry = struct {
    alias: []const u8,
    procedure: Procedure,
    data: *const anyopaque,

    pub const Procedure = *const fn (*Runtime, *const anyopaque) Result;
};

pub const default: Traps = blk: {
    const Alias = enum(u8) {
        getc = 0x20,
        out = 0x21,
        puts = 0x22,
        in = 0x23,
        putsp = 0x24,
        halt = 0x25,
        putn = 0x26,
        reg = 0x27,
    };

    var traps: Traps = .{ .entries = @splat(null) };
    for (@typeInfo(Alias).@"enum".fields) |field| {
        const entry: Entry = .{
            .alias = field.name,
            .procedure = @field(builtin_traps, field.name),
            .data = undefined,
        };
        traps.register(field.value, entry);
    }
    break :blk traps;
};

pub fn register(
    traps: *Traps,
    vect: u8,
    entry: Entry,
) void {
    traps.entries[vect] = entry;
}
