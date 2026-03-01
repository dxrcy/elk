const Traps = @This();

const std = @import("std");
const assert = std.debug.assert;

entries: []const Entry,

pub const Entry = struct {
    vect: u8,
    alias: []const u8,
};

pub fn fromEnum(comptime T: type) Traps {
    comptime {
        const info = @typeInfo(T).@"enum";
        const fields = info.fields;
        assert(info.tag_type == u8);

        var entries: [fields.len]Entry = undefined;
        for (fields, 0..) |field, i| {
            entries[i] = .{
                .alias = field.name,
                .vect = field.value,
            };
        }

        const entries_const = entries; // Workaround
        return .{ .entries = &entries_const };
    }
}
