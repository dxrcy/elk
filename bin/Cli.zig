const Cli = @This();

const std = @import("std");
const ArgIterator = std.process.Args.Iterator;

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
        .input = templates.PositionalListing{
            .value = []const u8,
        },
        .foo = templates.PositionalListing{
            .value = []const u8,
        },
    },
    .named = .{
        .assemble = templates.NamedListing{
            .short = 'a',
            .long = "assemble",
            .conflicts = &.{.emulate},
        },
        .emulate = templates.NamedListing{
            .short = 'e',
            .long = "emulate",
            .conflicts = &.{.assemble},
        },
        .output = templates.NamedListing{
            .short = 'o',
            .long = "output",
            .value = []const u8,
            .requires = &.{.assemble},
        },
        .debug = templates.NamedListing{
            .short = 'd',
            .long = "debug",
            .conflicts = &.{.assemble},
        },
    },
};

pub fn parse(args: *ArgIterator) anyerror!Cli {
    const values = try templates.parse(my_template, args);

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

const templates = struct {
    pub const PositionalListing = struct {
        value: type,
    };

    pub const NamedListing = struct {
        short: ?u8 = null,
        long: []const u8,
        requires: []const Id = &.{},
        conflicts: []const Id = &.{},
        value: type = void,

        const Id = @EnumLiteral();
    };

    pub fn Args(comptime template: anytype) type {
        return struct {
            positional: ArgStruct(template.positional) = .{},
            named: ArgStruct(template.named) = .{},
        };
    }

    pub fn ArgStruct(comptime template: anytype) type {
        const fields = @typeInfo(@TypeOf(template)).@"struct".fields;

        var info: struct {
            names: [fields.len][]const u8,
            types: [fields.len]type,
            attrs: [fields.len]std.builtin.Type.StructField.Attributes,
        } = undefined;

        for (fields, 0..) |field, i| {
            const value_type = @field(template, field.name).value;

            info.names[i] = field.name;
            info.types[i] = ?value_type;
            info.attrs[i] = .{
                .default_value_ptr = &@as(?value_type, null),
            };
        }

        return @Struct(.auto, null, &info.names, &info.types, &info.attrs);
    }

    fn parse(comptime template: anytype, iter: *ArgIterator) !Args(template) {
        // TODO: Validate cli template types

        var args: Args(template) = .{};

        _ = iter.next();
        while (iter.next()) |string| {
            if (try Flag.parse(string)) |flag| {
                try addNamedArg(template.named, &args.named, flag, iter);
            } else {
                try addPositionalArg(&args.positional, string);
            }
        }

        try checkDependencies(template.named, &args.named);

        return args;
    }

    fn addPositionalArg(args: anytype, string: []const u8) !void {
        inline for (@typeInfo(@TypeOf(args.*)).@"struct".fields) |field| {
            if (@field(args, field.name) == null) {
                const Value = @typeInfo(field.type).optional.child;
                const value = try parseValue(Value, string);
                @field(args, field.name) = value;
                return;
            }
        }
        return error.UnexpectedPositionalArg;
    }

    fn addNamedArg(
        comptime template: anytype,
        args: *ArgStruct(template),
        flag: Flag,
        iter: *ArgIterator,
    ) !void {
        inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
            const listing: NamedListing = @field(template, field.name);

            if (flag.matchesListing(listing)) {
                if (@field(args, field.name) != null)
                    return error.DuplicateFlag;

                const value = try parseFlagValue(listing.value, iter);
                @field(args, field.name) = value;
                return;
            }
        }
        return error.InvalidFlag;
    }

    fn checkDependencies(comptime template: anytype, args: *const ArgStruct(template)) !void {
        inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
            const listing: NamedListing = @field(template, field.name);

            if (@field(args, field.name) != null) {
                if (!hasAnyDependency(template, listing.requires, args) and listing.requires.len > 0)
                    return error.MissingRequirement;
                if (hasAnyDependency(template, listing.conflicts, args))
                    return error.ConflictingFlag;
            }
        }
    }

    fn hasAnyDependency(
        comptime template: anytype,
        comptime dependencies: []const NamedListing.Id,
        args: *const ArgStruct(template),
    ) bool {
        inline for (dependencies) |dependency| {
            if (hasDependency(template, dependency, args))
                return true;
        }
        return false;
    }

    fn hasDependency(
        comptime template: anytype,
        dependency: NamedListing.Id,
        args: *const ArgStruct(template),
    ) bool {
        inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(dependency)))
                return @field(args, field.name) != null;
        }
        unreachable; // conflict entry is not a valid field name
    }

    fn parseFlagValue(comptime T: type, iter: *ArgIterator) !T {
        if (T == void)
            return;
        const string = iter.next() orelse
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

    const Flag = union(enum) {
        short: u8,
        long: []const u8,

        pub fn parse(string: []const u8) !?Flag {
            if (std.mem.cutPrefix(u8, string, "--")) |long|
                return .{ .long = long };
            if (std.mem.cutPrefix(u8, string, "-")) |short| {
                if (short.len > 1)
                    return error.ExpectedShortFlag;
                return .{ .short = short[0] };
            }
            return null;
        }

        fn matchesListing(flag: Flag, template: NamedListing) bool {
            return switch (flag) {
                .short => |short| template.short == short,
                .long => |long| std.mem.eql(u8, template.long, long),
            };
        }
    };
};
