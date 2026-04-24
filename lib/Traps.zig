const Traps = @This();

const std = @import("std");
const assert = std.debug.assert;

const Runtime = @import("emulate/Runtime.zig");
const builtin_traps = @import("emulate/builtin_traps.zig");

pub const Callback = @import("callback.zig").Callback;

entries: [1 << 8]Entry,

pub const Error =
    Runtime.HostError ||
    error{ TrapFailed, Halt };

pub const Result = Error!void;

pub const Entry = struct {
    alias: ?[]const u8,
    callback: ?Callback(&.{*Runtime}, Result),

    pub const unset: Entry = .{ .alias = null, .callback = null };

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
    assert(traps.canRegister(vect, entry));
    traps.entries[vect] = entry;
}

pub fn canRegister(traps: *Traps, vect: u8, entry: Entry) bool {
    if (traps.entries[vect].isSet())
        return false;
    if (entry.alias) |alias| {
        @setEvalBranchQuota(5_000);
        if (traps.hasAlias(alias))
            return false;
    }
    return true;
}

fn hasAlias(traps: *Traps, alias: []const u8) bool {
    for (traps.entries) |entry| {
        const other_alias = entry.alias orelse
            continue;
        if (std.mem.eql(u8, other_alias, alias))
            return true;
    }
    return false;
}

pub fn registerSets(comptime enums: []const type) Traps {
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

pub fn initData(traps: *Traps, vect: u8, comptime Data: type, data: Data) void {
    const callback = &(traps.entries[vect].callback orelse
        unreachable);
    callback.initData(Data, data);
}
