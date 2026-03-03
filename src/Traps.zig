const Traps = @This();

const std = @import("std");
const assert = std.debug.assert;

pub const Callback = @import("callback.zig").Callback;
const Runtime = @import("emulate/Runtime.zig");
const builtin_traps = @import("emulate/builtin_traps.zig");

entries: [1 << 8]Entry,

pub const Error =
    Runtime.IoError ||
    error{ TrapFailed, Halt };

pub const Result = Error!void;

pub const Entry = struct {
    alias: ?[]const u8,
    callback: ?Callback(&.{*Runtime}, Result),

    const unset: Entry = .{ .alias = null, .callback = null };

    fn isSet(entry: *const Entry) bool {
        return entry.alias != null or
            entry.callback != null;
    }
};

pub const Standard = enum(u8) {
    getc = 0x20,
    out = 0x21,
    puts = 0x22,
    in = 0x23,
    putsp = 0x24,
    halt = 0x25,
};
pub const Debug = enum(u8) {
    putn = 0x26,
    reg = 0x27,
};

pub fn register(traps: *Traps, vect: u8, entry: Entry) void {
    assert(!traps.entries[vect].isSet());
    traps.entries[vect] = entry;
}

pub fn initData(traps: *Traps, vect: u8, comptime Data: type, data: Data) void {
    const callback = &(traps.entries[vect].callback orelse
        unreachable);
    callback.initData(Data, data);
}

pub fn initBuiltins(comptime enums: []const type) Traps {
    if (!@inComptime()) @compileError("must be called at comptime");

    comptime {
        var traps: Traps = .{ .entries = @splat(.unset) };
        for (enums) |Enum| {
            for (@typeInfo(Enum).@"enum".fields) |field| {
                const vect = field.value;
                const entry: Entry = .{
                    .alias = field.name,
                    .callback = .withoutData(@field(builtin_traps, field.name)),
                };
                traps.register(vect, entry);
            }
        }
        return traps;
    }
}
