const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const log = std.log.scoped(.cli);

pub fn Options(comptime template: anytype) type {
    return struct {
        flags: FlagValues(template),
        pos: std.ArrayList([]const u8),

        pub fn parse(arena: Allocator, args: []const []const u8) !Options(template) {
            return parseCli(template, arena, args);
        }

        pub fn deinit(options: *@This(), arena: Allocator) void {
            options.pos.deinit(arena);
        }

        // TODO: Replace with a `nextPos` method ?
        pub fn getPos(options: *const @This(), index: usize, name: @EnumLiteral()) ![]const u8 {
            if (options.pos.items.len <= index) {
                log.err("missing positional argument '{t}'", .{name});
                return error.ParseFailed;
            }
            return options.pos.items[index];
        }
    };
}

pub const types = struct {
    pub const string: Flag.Value = .{
        .type = []const u8,
        .parser = struct {
            fn parser(dest: *anyopaque, src: []const u8) !void {
                cast([]const u8, dest).* = src;
            }
        }.parser,
    };

    pub const integer: Flag.Value = .{
        .type = i32,
        .parser = struct {
            fn parser(dest: *anyopaque, src: []const u8) !void {
                cast(i32, dest).* =
                    std.fmt.parseInt(i32, src, 10) catch
                        return error.ParseFailed;
            }
        }.parser,
    };

    pub const path: Flag.Value = .{
        .type = Path,
        .parser = struct {
            fn parser(dest: *anyopaque, src: []const u8) !void {
                cast(Path, dest).* =
                    if (std.mem.eql(u8, src, "-")) .stdio else .{ .regular = src };
            }
        }.parser,
    };

    fn cast(comptime T: type, dest: *anyopaque) *?T {
        return @as(*?T, @ptrCast(@alignCast(dest)));
    }

    pub const Path = union(enum) {
        stdio,
        regular: []const u8,

        pub fn asRegular(self: Path) ![]const u8 {
            return switch (self) {
                .stdio => error.UnsupportedStdio,
                .regular => |regular| regular,
            };
        }
    };
};

pub const Flag = struct {
    short: ?u8 = null,
    long: []const u8,
    value: ?Value = null,

    const Value = struct {
        type: type,
        parser: Parser,
        const Parser = fn (dest: *anyopaque, src: []const u8) error{ParseFailed}!void;
    };
};

fn FlagValues(comptime template: anytype) type {
    const fields = @typeInfo(@TypeOf(template)).@"struct".fields;

    var info: struct {
        names: [fields.len][]const u8,
        types: [fields.len]type,
        attrs: [fields.len]std.builtin.Type.StructField.Attributes,
    } = undefined;

    for (fields, 0..) |field, i| {
        const value = @field(template, field.name).value;
        // NOTE: If `?T` poses an issue (due to undefined layout), we can instead use a custom
        // `extern` optional type.
        const Value = if (value) |v| ?v.type else bool;
        const default: Value = if (value) |_| null else false;

        info.names[i] = field.name;
        info.types[i] = Value;
        info.attrs[i] = .{ .default_value_ptr = &default };
    }

    return @Struct(.auto, null, &info.names, &info.types, &info.attrs);
}

pub fn collectArgs(arena: Allocator, args: std.process.Args) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).empty;
    var iter = try args.iterateAllocator(arena);
    defer iter.deinit();

    _ = iter.next();
    while (iter.next()) |arg| {
        try list.append(arena, arg);
    }

    return list;
}

fn parseCli(
    comptime template: anytype,
    arena: Allocator,
    args: []const []const u8,
) !Options(template) {
    var flag_args = std.ArrayList(FlagArg).empty;
    var pos_args = std.ArrayList([]const u8).empty;
    defer flag_args.deinit(arena);

    try parseArgs(template, arena, args, &flag_args, &pos_args);
    const flags = try parseFlagValues(template, args, flag_args.items);

    return .{
        .flags = flags,
        .pos = pos_args,
    };
}

const FlagArg = struct {
    item: *const FlagItem,
    short: bool,
    index: usize,
    value: ?usize,
};

/// Runtime version of `Flag`.
const FlagItem = struct {
    key: []const u8,
    short: ?u8,
    long: []const u8,
    parser: ?*const Flag.Value.Parser,
};

fn getFlagItems(
    comptime template: anytype,
) [@typeInfo(@TypeOf(template)).@"struct".fields.len]FlagItem {
    const fields = @typeInfo(@TypeOf(template)).@"struct".fields;
    comptime var flag_items: [fields.len]FlagItem = undefined;
    inline for (fields, 0..) |field, i| {
        const flag: *const Flag = @ptrCast(@alignCast(field.default_value_ptr.?));
        flag_items[i] = .{
            .key = field.name,
            .short = flag.short,
            .long = flag.long,
            .parser = if (flag.value) |value| value.parser else null,
        };
    }
    return flag_items;
}

fn parseArgs(
    comptime template: anytype,
    arena: Allocator,
    args: []const []const u8,
    flag_args: *std.ArrayList(FlagArg),
    pos_args: *std.ArrayList([]const u8),
) !void {
    var error_count: usize = 0;
    const flag_items = comptime getFlagItems(template);

    var recent_flag: ?usize = null;
    // Has the end-of-options marker (`--`) been reached already?
    var is_end_of_options = false;

    for (args, 0..) |arg, i| {
        if (is_end_of_options) {
            try pos_args.append(arena, arg);
            continue;
        }

        if (recent_flag) |index| {
            recent_flag = null;
            const kind, _ = cutArgPrefix(arg);
            if (kind == .value and !isEndOfOptionsMarker(arg)) {
                assert(flag_args.items[index].value == null);
                flag_args.items[index].value = i;
                continue;
            } else {
                // Expected non-flag argument, handle later, when parsing the flag value
            }
        }

        if (isEndOfOptionsMarker(arg)) {
            is_end_of_options = true;
            continue;
        }
        if (parseMetaArg(arg)) |_|
            continue;

        const kind, const name = cutArgPrefix(arg);
        switch (kind) {
            .short => {
                assert(name.len > 0);
                if (name.len > 1) {
                    for (name) |char| {
                        const item = getFlagItemShort(&flag_items, char) orelse {
                            log.err("invalid flag: -{c} in {s}", .{ char, arg });
                            error_count += 1;
                            continue;
                        };
                        if (item.parser) |_| {
                            log.err(
                                "cannot combine short flags which require values: -{c} (--{s}) in {s}",
                                .{ char, item.long, arg },
                            );
                            error_count += 1;
                            continue;
                        }
                        try flag_args.append(
                            arena,
                            .{ .item = item, .short = true, .index = i, .value = null },
                        );
                    }
                } else {
                    const item = getFlagItemShort(&flag_items, name[0]) orelse {
                        log.err("invalid flag: {s}", .{arg});
                        error_count += 1;
                        continue;
                    };
                    if (item.parser) |_|
                        recent_flag = flag_args.items.len; // Parse later
                    try flag_args.append(
                        arena,
                        .{ .item = item, .short = true, .index = i, .value = null },
                    );
                }
            },

            .long => {
                const item = getFlagItemLong(&flag_items, name) orelse {
                    log.err("invalid flag: {s}", .{arg});
                    error_count += 1;
                    continue;
                };
                if (item.parser) |_|
                    recent_flag = flag_args.items.len; // Parse later
                try flag_args.append(
                    arena,
                    .{ .item = item, .short = false, .index = i, .value = null },
                );
            },

            .value => {
                try pos_args.append(arena, arg);
            },
        }
    }

    try checkErrors(error_count);
}

fn parseFlagValues(
    comptime template: anytype,
    args: []const []const u8,
    flag_args: []const FlagArg,
) !FlagValues(template) {
    var error_count: usize = 0;
    var flags: FlagValues(template) = .{};

    for (flag_args) |arg| {
        const field = getField(&flags, arg.item.key);

        if (arg.item.parser) |parser| {
            const value_index = arg.value orelse {
                // This is disgusting...
                log.err("{f}", .{struct {
                    pub fn format(self: @This(), w: *Writer) !void {
                        try w.print("missing value for flag {s}", .{self.args[self.arg.index]});
                        if (self.arg.short)
                            try w.print(" (--{s})", .{self.arg.item.long});
                        if (self.arg.index + 1 < self.args.len)
                            try w.print(", found '{s}'", .{self.args[self.arg.index + 1]});
                    }
                    args: []const []const u8,
                    arg: FlagArg,
                }{ .args = args, .arg = arg }});
                error_count += 1;
                continue;
            };

            try parser(field, args[value_index]);
        } else {
            const field_bool: *bool = @ptrCast(field);
            field_bool.* = true;
        }
    }

    try checkErrors(error_count);
    return flags;
}

fn checkErrors(error_count: usize) error{ParseFailed}!void {
    if (error_count > 0) {
        log.err("{} errors", .{error_count});
        return error.ParseFailed;
    }
}

pub fn checkGroup(
    comptime name: @EnumLiteral(),
    comptime Group: type,
    flags: anytype,
) error{ParseFailed}!void {
    const GroupFmt = struct {
        pub fn format(_: @This(), writer: *Writer) !void {
            for (std.meta.tags(Group), 0..) |tag, i| {
                if (i > 0)
                    try writer.print(", ", .{});
                try writer.print("{t}", .{tag});
            }
        }
    };

    var existing = false;
    inline for (comptime std.meta.tags(Group)) |flag| {
        if (isFlagSet(@field(flags, @tagName(flag)))) {
            if (!existing) {
                existing = true;
            } else {
                log.err(
                    "multiple flags given for '{t}': must be one of [{f}]",
                    .{ name, GroupFmt{} },
                );
                return error.ParseFailed;
            }
        }
    }
}

pub fn checkConflicts(
    comptime name: @EnumLiteral(),
    comptime requires: []const @EnumLiteral(),
    comptime conflicts: []const @EnumLiteral(),
    flags: anytype,
) error{ParseFailed}!void {
    inline for (requires) |require| {
        if (isFlagSet(@field(flags, @tagName(require)))) {
            log.err("flag `{t}` cannot be used without required flag `{t}`", .{ name, require });
            return error.ParseFailed;
        }
    }
    inline for (conflicts) |conflict| {
        if (isFlagSet(@field(flags, @tagName(conflict)))) {
            log.err("flag `{t}` cannot be used with conflicting flag `{t}`", .{ name, conflict });
            return error.ParseFailed;
        }
    }
}

pub fn isFlagSet(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => value,
        .optional => value != null,
        else => comptime unreachable,
    };
}

fn getField(flags: anytype, key: []const u8) *anyopaque {
    const fields = @typeInfo(@TypeOf(flags.*)).@"struct".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            return &@field(flags, field.name);
        }
    }
    unreachable;
}

fn getFlagItemShort(items: []const FlagItem, name: u8) ?*const FlagItem {
    for (items) |*item| {
        const short = item.short orelse
            continue;
        if (name == short)
            return item;
    }
    return null;
}

fn getFlagItemLong(items: []const FlagItem, name: []const u8) ?*const FlagItem {
    for (items) |*item| {
        if (std.mem.eql(u8, item.long, name))
            return item;
    }
    return null;
}

pub const MetaArg = enum { help, version };

pub fn getMetaArg(args: []const []const u8) ?MetaArg {
    for (args) |arg| {
        if (isEndOfOptionsMarker(arg))
            return null;
        if (parseMetaArg(arg)) |meta|
            return meta;
    }
    return null;
}

fn parseMetaArg(arg: []const u8) ?MetaArg {
    const kind, const name = cutArgPrefix(arg);
    if (kind == .short and std.mem.eql(u8, name, "h"))
        return .help;
    if (kind == .long and std.mem.eql(u8, name, "help"))
        return .help;
    if (kind == .short and std.mem.eql(u8, name, "v"))
        return .version;
    if (kind == .long and std.mem.eql(u8, name, "version"))
        return .version;
    return null;
}

test parseMetaArg {
    const expect = std.testing.expect;

    try expect(parseMetaArg("") == null);
    try expect(parseMetaArg("h") == null);
    try expect(parseMetaArg("help") == null);
    try expect(parseMetaArg("--h") == null);
    try expect(parseMetaArg("-help") == null);
    try expect(parseMetaArg("--helpx") == null);
    try expect(parseMetaArg("---help") == null);
    try expect(parseMetaArg("-h") == .help);
    try expect(parseMetaArg("--help") == .help);
    try expect(parseMetaArg("-v") == .version);
    try expect(parseMetaArg("--version") == .version);
}

fn isEndOfOptionsMarker(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--");
}

fn cutArgPrefix(arg: []const u8) struct {
    enum { short, long, value },
    []const u8,
} {
    const FLAG_CHAR: u8 = '-';
    if (arg.len >= 2 and arg[0] == FLAG_CHAR and arg[1] != FLAG_CHAR)
        return .{ .short, arg[1..] };
    if (arg.len >= 3 and arg[0] == FLAG_CHAR and arg[1] == FLAG_CHAR and arg[2] != FLAG_CHAR)
        return .{ .long, arg[2..] };
    return .{ .value, arg };
}

test cutArgPrefix {
    const expect = std.testing.expect;

    const eql = struct {
        const T = @typeInfo(@TypeOf(cutArgPrefix)).@"fn".return_type.?;
        fn eql(a: T, b: T) bool {
            return a[0] == b[0] and std.mem.eql(u8, a[1], b[1]);
        }
    }.eql;

    try expect(eql(cutArgPrefix(""), .{ .value, "" }));
    try expect(eql(cutArgPrefix("a"), .{ .value, "a" }));
    try expect(eql(cutArgPrefix("abc"), .{ .value, "abc" }));
    try expect(eql(cutArgPrefix("-"), .{ .value, "-" }));
    try expect(eql(cutArgPrefix("--"), .{ .value, "--" }));
    try expect(eql(cutArgPrefix("---"), .{ .value, "---" }));
    try expect(eql(cutArgPrefix("---abc"), .{ .value, "---abc" }));
    try expect(eql(cutArgPrefix("-a"), .{ .short, "a" }));
    try expect(eql(cutArgPrefix("-abc"), .{ .short, "abc" }));
    try expect(eql(cutArgPrefix("--a"), .{ .long, "a" }));
    try expect(eql(cutArgPrefix("--abc"), .{ .long, "abc" }));
}
