const std = @import("std");
const Io = std.Io;

pub fn writeDeclTree(comptime T: type, writer: *Io.Writer) error{WriteFailed}!void {
    try writeDecl(T, @typeName(T), writer);
    try writeDeclsRecursive(T, "", writer);
    try writer.flush();
}

fn writeDeclsRecursive(
    comptime T: type,
    comptime line: []const u8,
    writer: *Io.Writer,
) error{WriteFailed}!void {
    const lines = struct {
        const mid_active = "├── ";
        const end_active = "└── ";
        const mid_inactive = "│   ";
        const end_inactive = "    ";
    };

    switch (@typeInfo(T)) {
        else => {},
        inline .@"struct", .@"enum", .@"union", .@"opaque" => |info| {
            inline for (info.decls, 0..) |decl, i| {
                const is_end = i + 1 >= info.decls.len;
                const this_line = line ++ if (is_end) lines.end_active else lines.mid_active;
                const child_line = line ++ if (is_end) lines.end_inactive else lines.mid_inactive;

                try writer.print("\x1b[2m{s}\x1b[0m", .{this_line});
                try writeDecl(@field(T, decl.name), decl.name, writer);

                if (@TypeOf(@field(T, decl.name)) == type)
                    try writeDeclsRecursive(@field(T, decl.name), child_line, writer);
            }
        },
    }
}

fn writeDecl(
    comptime decl: anytype,
    comptime name: []const u8,
    writer: *Io.Writer,
) error{WriteFailed}!void {
    const tag = if (@TypeOf(decl) == type) switch (@typeInfo(decl)) {
        inline else => |_, tag| tag,
    } else @typeInfo(@TypeOf(decl));

    const tag_color = switch (tag) {
        .@"struct" => 32,
        .@"union" => 33,
        .@"enum" => 34,
        .@"fn" => 35,
        else => 31,
    };

    try writer.print("\x1b[{}m{t}\x1b[0m", .{ tag_color, tag });
    try writer.print(" \x1b[3m{s}\x1b[0m\n", .{name});
}
