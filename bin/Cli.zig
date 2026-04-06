const Cli = @This();

const std = @import("std");
const Args = std.process.Args;

const elk = @import("elk");

operation: Operation,
policies: elk.Policies,
strictness: elk.Reporter.Options.Strictness,
verbosity: elk.Reporter.Stderr.Verbosity,

const Operation = union(enum) {
    assemble_emulate: struct {
        input: []const u8,
        debug: ?Debug,
    },
    assemble: struct {
        input: []const u8,
        output: ?[]const u8,
        export_symbols: bool,
        export_listing: bool,
    },
    emulate: struct {
        input: []const u8,
        debug: ?Debug,
    },
    format: struct {
        input: []const u8,
        output: ?[]const u8,
    },
    clean: struct {
        input: []const u8,
    },

    const Debug = struct {
        commands: ?[]const u8,
        history_file: ?[]const u8,
        import_symbols: ?[]const u8,
    };
};

const my_template = .{
    .positional = .{
        .input = PositionalArg{
            .value = []const u8,
        },
        .foo = PositionalArg{
            .value = []const u8,
        },
    },
    .named = .{
        .assemble = NamedArg{
            .short = 'a',
            .long = "assemble",
            .conflicts = &.{"emulate"},
        },
        .emulate = NamedArg{
            .short = 'e',
            .long = "emulate",
            .conflicts = &.{"assemble"},
        },
        .output = NamedArg{
            .short = 'o',
            .long = "output",
            .value = []const u8,
            .requires = &.{"assemble"},
        },
        .debug = NamedArg{
            .short = 'd',
            .long = "debug",
            .conflicts = &.{"assemble"},
        },
    },
};

pub fn parse(args: *Args.Iterator) anyerror!Cli {
    const values = try parseTemplate(my_template, args);

    inline for (std.meta.fields(@TypeOf(my_template.named))) |field| {
        std.debug.print("{s}: {any}\n", .{
            field.name,
            @field(values.named, field.name),
        });
    }

    inline for (std.meta.fields(@TypeOf(values.positional))) |field| {
        std.debug.print("{s}: {any}\n", .{
            field.name,
            @field(values.positional, field.name),
        });
    }

    std.debug.print("-- END OF CLI PARSING -- \n", .{});
    std.process.exit(0);
}

const PositionalArg = struct {
    value: type = void,
};

const NamedArg = struct {
    short: ?u8 = null,
    long: Name,
    requires: []const Name = &.{},
    conflicts: []const Name = &.{},
    value: type = void,

    const Name = []const u8;
};

fn TemplateArgs(comptime template: anytype) type {
    return struct {
        positional: PositionalArgStruct(template.positional),
        named: NamedArgStruct(template.named),
    };
}

fn parseTemplate(comptime template: anytype, args: *Args.Iterator) !TemplateArgs(template) {
    // TODO: Validate cli template types

    _ = args.next();

    var positional_args: PositionalArgStruct(template.positional) = .{};
    var named_values: NamedArgStruct(template.named) = .{};

    while (args.next()) |arg_string| {
        std.debug.print("[{s}]\n", .{arg_string});

        const arg_name = try FlagName.parse(arg_string) orelse {
            try addPositionalArg(&positional_args, arg_string);
            continue;
        };

        std.debug.print("{}\n", .{arg_name});

        try parseFlag(template.named, args, &named_values, arg_name);
    }

    try checkDependencies(template.named, &named_values);

    return .{
        .positional = positional_args,
        .named = named_values,
    };
}

fn addPositionalArg(args: anytype, string: []const u8) !void {
    const fields = @typeInfo(@TypeOf(args.*)).@"struct".fields;

    inline for (fields) |field| {
        if (@field(args, field.name) == null) {
            const value_type = @typeInfo(field.type).optional.child;
            const value = try parseValue(value_type, string);
            @field(args, field.name) = value;
            return;
        }
    }

    return error.UnexpectedPositionalArg;
}

fn PositionalArgStruct(comptime positional: anytype) type {
    const fields = @typeInfo(@TypeOf(positional)).@"struct".fields;

    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;

    for (fields, 0..) |field, i| {
        const value_type = @field(positional, field.name).value;

        field_names[i] = field.name;
        field_types[i] = ?value_type;
        field_attrs[i] = .{
            .default_value_ptr = &@as(?value_type, null),
        };
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn NamedArgStruct(comptime named: anytype) type {
    const fields = @typeInfo(@TypeOf(named)).@"struct".fields;

    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;

    for (fields, 0..) |field, i| {
        const value_type = @field(named, field.name).value;

        field_names[i] = field.name;
        field_types[i] = ?value_type;
        field_attrs[i] = .{
            .default_value_ptr = &@as(?value_type, null),
        };
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

fn parseFlag(
    comptime named: anytype,
    args: *Args.Iterator,
    named_values: *NamedArgStruct(named),
    flag_name: FlagName,
) !void {
    const fields = @typeInfo(@TypeOf(named)).@"struct".fields;

    inline for (fields) |field| {
        const arg_info: NamedArg = @field(named, field.name);

        if (flag_name.eql(arg_info)) {
            if (@field(named_values, field.name) != null)
                return error.DuplicateFlag;

            const value = try parseFlagValue(arg_info.value, args);
            @field(named_values, field.name) = value;
            return;
        }
    }

    return error.InvalidFlag;
}

fn checkDependencies(comptime named: anytype, named_values: *const NamedArgStruct(named)) !void {
    const fields = @typeInfo(@TypeOf(named)).@"struct".fields;

    inline for (fields) |field| {
        const arg_info: NamedArg = @field(named, field.name);

        if (@field(named_values, field.name) != null) {
            if (!hasExpectedDependencies(named, arg_info.requires, named_values, true))
                return error.MissingRequirement;
            if (!hasExpectedDependencies(named, arg_info.conflicts, named_values, false))
                return error.ConflictingFlag;
        }
    }
}

fn hasExpectedDependencies(
    comptime named: anytype,
    comptime dependencies: []const NamedArg.Name,
    named_values: *const NamedArgStruct(named),
    comptime expected: bool,
) bool {
    for (dependencies) |dependency| {
        if (hasDependency(named, dependency, named_values) != expected)
            return false;
    }
    return true;
}

fn hasDependency(
    comptime named: anytype,
    dependency: NamedArg.Name,
    named_values: *const NamedArgStruct(named),
) bool {
    const fields = @typeInfo(@TypeOf(named)).@"struct".fields;

    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, dependency)) {
            return @field(named_values, field.name) != null;
        }
    }
    unreachable; // conflict entry is not a valid field name
}

fn parseFlagValue(comptime T: type, args: *Args.Iterator) !T {
    if (T == void)
        return;

    const string = args.next() orelse
        return error.ExpectedFlagValue;

    return try parseValue(T, string);
}

fn parseValue(comptime T: type, string: []const u8) !T {
    switch (T) {
        else => @compileError("unsupported flag value"),
        void => comptime unreachable,

        []const u8 => {
            return string;
        },
    }

    return error.InvalidArgumentValue;
}

const FlagName = union(enum) {
    short: u8,
    long: []const u8,

    pub fn parse(string: []const u8) !?FlagName {
        if (std.mem.cutPrefix(u8, string, "--")) |long|
            return .{ .long = long };
        if (std.mem.cutPrefix(u8, string, "-")) |short| {
            if (short.len > 1)
                return error.ExpectedShortFlag;
            return .{ .short = short[0] };
        }
        return null;
    }

    fn eql(flag_name: FlagName, arg_info: NamedArg) bool {
        switch (flag_name) {
            .short => |short| return arg_info.short == short,
            .long => |long| return std.mem.eql(u8, arg_info.long, long),
        }
    }
};
