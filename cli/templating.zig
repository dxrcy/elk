const std = @import("std");
const assert = std.debug.assert;
const ArgIterator = std.process.Args.Iterator;

const log = std.log.scoped(.cli);

pub const Path = union(enum) {
    stdio,
    regular: []const u8,

    pub fn asRegular(path: Path) ![]const u8 {
        return switch (path) {
            .stdio => error.UnsupportedStdio,
            .regular => |regular| regular,
        };
    }
};

pub const PositionalListing = struct {
    value: type,
};

pub const NamedListing = struct {
    short: ?u8 = null,
    long: []const u8,
    value: type = void,
    value_parser: ?ValueParser = null,

    const Id = @EnumLiteral();
    const ValueParser = fn ([]const u8, *anyopaque) error{InvalidArgumentValue}!void;
};

pub fn Args(comptime template: anytype) type {
    return struct {
        positional: PositionalArgs(template.positional) = .{},
        named: NamedArgs(template.named) = .{},
    };
}

pub fn PositionalArgs(comptime template: anytype) type {
    return ArgStruct(template, false);
}
pub fn NamedArgs(comptime template: anytype) type {
    return ArgStruct(template, true);
}

fn ArgStruct(comptime template: anytype, comptime optional_fields: bool) type {
    const fields = @typeInfo(@TypeOf(template)).@"struct".fields;

    var info: struct {
        names: [fields.len][]const u8,
        types: [fields.len]type,
        attrs: [fields.len]std.builtin.Type.StructField.Attributes,
    } = undefined;

    for (fields, 0..) |field, i| {
        const ValueRaw = @field(template, field.name).value;
        const Value = if (optional_fields)
            if (ValueRaw == void) bool else ?ValueRaw
        else
            ValueRaw;
        const default: Value = if (optional_fields)
            if (ValueRaw == void) false else null
        else
            undefined;

        info.names[i] = field.name;
        info.types[i] = Value;
        info.attrs[i] = .{ .default_value_ptr = &default };
    }

    return @Struct(.auto, null, &info.names, &info.types, &info.attrs);
}

pub fn parse(comptime template: anytype, iter: *ArgIterator) error{
    ParseFailed,
    Empty,
    Help,
    Version,
}!Args(template) {
    // TODO: Validate cli template types

    var args: Args(template) = .{};
    var positional_count: usize = 0;
    var total_count: usize = 0;

    _ = iter.next();
    while (iter.next()) |string| {
        total_count += 1;

        const flag_opt = Flag.parse(string) catch {
            log.err("invalid flag name `{s}`", .{string});
            return error.ParseFailed;
        };

        if (flag_opt) |flag| {
            try checkMetaArgs(flag);
            try addNamedArg(template.named, &args.named, flag, iter);
        } else {
            try addPositionalArg(&args.positional, &positional_count, string);
        }
    }

    if (total_count == 0)
        return error.Empty;

    if (positional_count < @typeInfo(@TypeOf(args.positional)).@"struct".fields.len) {
        const name = @typeInfo(@TypeOf(args.positional)).@"struct".fields[positional_count].name;
        log.err("expected positional argument `{s}`", .{name});
        return error.ParseFailed;
    }

    return args;
}

fn checkMetaArgs(flag: Flag) error{ Help, Version }!void {
    if (flag.matchesListing(.{ .short = 'h', .long = "help" }))
        return error.Help;
    if (flag.matchesListing(.{ .short = 'v', .long = "version" }))
        return error.Version;
}

fn addPositionalArg(
    args: anytype,
    positional_count: *usize,
    string: []const u8,
) error{ParseFailed}!void {
    inline for (@typeInfo(@TypeOf(args.*)).@"struct".fields, 0..) |field, i| {
        if (i == positional_count.*) {
            const value = parseValue(field.type, string) catch {
                log.err("invalid value for argument `{s}`", .{field.name});
                return error.ParseFailed;
            };
            @field(args, field.name) = value;
            positional_count.* += 1;
            return;
        }
    }

    log.err("unexpected positional argument", .{});
    return error.ParseFailed;
}

fn addNamedArg(
    comptime template: anytype,
    args: *NamedArgs(template),
    flag: Flag,
    iter: *ArgIterator,
) error{ParseFailed}!void {
    inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
        const listing: NamedListing = @field(template, field.name);

        if (flag.matchesListing(listing)) {
            if (isValueSet(@field(args, field.name))) {
                log.err("duplicate instance of flag `{f}`", .{flag});
                return error.ParseFailed;
            }

            const value = try parseFlagValue(listing.value, listing.value_parser, flag, iter);
            @field(args, field.name) = value;
            return;
        }
    }

    log.err("invalid flag name `{f}`", .{flag});
    return error.ParseFailed;
}

pub fn isValueSet(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => value,
        .optional => value != null,
        else => unreachable,
    };
}

fn parseFlagValue(
    comptime T: type,
    comptime parser_opt: ?NamedListing.ValueParser,
    flag: Flag,
    iter: *ArgIterator,
) error{ParseFailed}!(if (T == void) bool else T) {
    if (T == void) {
        comptime assert(parser_opt == null);
        return true;
    }

    const string = iter.next() orelse {
        log.err("expected value for flag `{f}`", .{flag});
        return error.ParseFailed;
    };

    if (Flag.isValid(string)) {
        log.err("expected value for flag `{f}`, found flag", .{flag});
        return error.ParseFailed;
    }

    if (parser_opt) |parser| {
        var value: T = undefined;
        parser(string, @ptrCast(&value)) catch {
            log.err("invalid value for flag `{f}`", .{flag});
            return error.ParseFailed;
        };
        return value;
    }

    return parseValue(T, string) catch {
        log.err("invalid value for flag `{f}`", .{flag});
        return error.ParseFailed;
    };
}

fn parseValue(comptime T: type, string: []const u8) error{InvalidArgumentValue}!T {
    assert(!Flag.isValid(string));

    switch (T) {
        else => @compileError("unsupported flag value"),
        void => comptime unreachable,

        []const u8 => {
            return string;
        },

        Path => {
            if (std.mem.eql(u8, string, "-"))
                return .stdio;
            return .{ .regular = string };
        },
    }

    return error.InvalidArgumentValue;
}

const Flag = union(enum) {
    short: u8,
    long: []const u8,

    pub fn isValid(string: []const u8) bool {
        return (Flag.parse(string) catch
            return false) != null;
    }

    pub fn parse(string: []const u8) error{ExpectedShortFlag}!?Flag {
        if (std.mem.cutPrefix(u8, string, "--")) |long|
            return .{ .long = long };
        if (std.mem.cutPrefix(u8, string, "-")) |short| {
            if (short.len > 1)
                return error.ExpectedShortFlag;
            if (short.len == 0)
                return null;
            return .{ .short = short[0] };
        }
        return null;
    }

    pub fn format(flag: Flag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (flag) {
            .short => |short| writer.print("-{c}", .{short}),
            .long => |long| writer.print("--{s}", .{long}),
        };
    }

    fn matchesListing(flag: Flag, template: NamedListing) bool {
        return switch (flag) {
            .short => |short| template.short == short,
            .long => |long| std.mem.eql(u8, template.long, long),
        };
    }
};
