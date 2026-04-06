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
        input: templates.Path,
        debug: ?Debug,
    },
    assemble: struct {
        input: templates.Path,
        output: ?templates.Path,
        output_mode: enum { assembly, symbols, listing },
    },
    emulate: struct {
        input: templates.Path,
        debug: ?Debug,
    },
    format: struct {
        input: templates.Path,
        output: ?templates.Path,
    },
    clean: struct {
        input: templates.Path,
    },

    const Debug = struct {
        commands: ?[]const u8,
        history_file: ?templates.Path,
        import_symbols: ?[]const u8,
    };
};

const my_template = .{
    .positional = .{
        .input = templates.PositionalListing{
            .value = templates.Path,
        },
    },

    .named = .{
        .assemble = templates.NamedListing{
            .short = 'a',
            .long = "assemble",
            .conflicts = &.{ .emulate, .format, .clean },
        },
        .emulate = templates.NamedListing{
            .short = 'e',
            .long = "emulate",
            .conflicts = &.{ .assemble, .format, .clean },
        },
        .format = templates.NamedListing{
            .long = "format",
            .conflicts = &.{ .assemble, .emulate, .clean },
        },
        .clean = templates.NamedListing{
            .long = "emulate",
            .conflicts = &.{ .assemble, .emulate, .format },
        },

        .output = templates.NamedListing{
            .short = 'o',
            .long = "output",
            .value = templates.Path,
            .requires = &.{ .assemble, .format },
        },

        .export_symbols = templates.NamedListing{
            .long = "export-symbols",
            .requires = &.{.assemble},
            .conflicts = &.{.export_listing},
        },
        .export_listing = templates.NamedListing{
            .long = "export-listing",
            .requires = &.{.assemble},
            .conflicts = &.{.export_symbols},
        },

        .debug = templates.NamedListing{
            .short = 'd',
            .long = "debug",
            .conflicts = &.{ .assemble, .format, .clean },
        },

        .commands = templates.NamedListing{
            .short = 'c',
            .long = "commands",
            .value = []const u8,
            .requires = &.{.debug},
        },
        .history_file = templates.NamedListing{
            .long = "history-file",
            .value = templates.Path,
            .requires = &.{.debug},
        },
        .import_symbols = templates.NamedListing{
            .long = "import-symbols",
            .value = []const u8,
            .requires = &.{.debug},
        },

        .strict = templates.NamedListing{
            .long = "strict",
            .conflicts = &.{.relaxed},
        },
        .relaxed = templates.NamedListing{
            .long = "relaxed",
            .conflicts = &.{.strict},
        },
        .quiet = templates.NamedListing{
            .short = 'q',
            .long = "quiet",
        },
        .permit = templates.NamedListing{
            .short = 'p',
            .long = "permit",
            .value = []const u8,
        },
    },
};

pub fn parse(iter: *ArgIterator) anyerror!Cli {
    const args = try templates.parse(my_template, iter);

    return .{
        .operation = parseOperation(&args),
        // TODO: Parse policies
        .policies = .default,
        .strictness = if (args.named.strict)
            .strict
        else if (args.named.relaxed)
            .relaxed
        else
            .normal,
        .verbosity = if (args.named.quiet) .quiet else .normal,
    };
}

fn parseOperation(args: *const templates.Args(my_template)) Operation {
    if (args.named.assemble) {
        return .{ .assemble = .{
            .input = args.positional.input,
            .output = args.named.output,
            .output_mode = if (args.named.export_symbols)
                .symbols
            else if (args.named.export_listing)
                .listing
            else
                .assembly,
        } };
    }

    if (args.named.emulate) {
        return .{ .emulate = .{
            .input = args.positional.input,
            .debug = if (args.named.debug) .{
                .commands = args.named.commands,
                .history_file = args.named.history_file,
                .import_symbols = args.named.import_symbols,
            } else null,
        } };
    }

    if (args.named.format) {
        return .{ .format = .{
            .input = args.positional.input,
            .output = args.named.output,
        } };
    }

    if (args.named.clean) {
        return .{ .clean = .{
            .input = args.positional.input,
        } };
    }

    return .{ .assemble_emulate = .{
        .input = args.positional.input,
        .debug = if (args.named.debug) .{
            .commands = args.named.commands,
            .history_file = args.named.history_file,
            .import_symbols = args.named.import_symbols,
        } else null,
    } };
}

const templates = struct {
    const Path = union(enum) {
        stdio,
        regular: []const u8,
    };

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

    fn parse(comptime template: anytype, iter: *ArgIterator) !Args(template) {
        // TODO: Validate cli template types

        var args: Args(template) = .{};
        var positional_count: usize = 0;

        _ = iter.next();
        while (iter.next()) |string| {
            if (try Flag.parse(string)) |flag| {
                try addNamedArg(template.named, &args.named, flag, iter);
            } else {
                try addPositionalArg(&args.positional, &positional_count, string);
            }
        }

        if (positional_count < @typeInfo(@TypeOf(args.positional)).@"struct".fields.len)
            return error.ExpectedPositionalArg;

        try checkDependencies(template.named, &args.named);

        return args;
    }

    fn addPositionalArg(args: anytype, positional_count: *usize, string: []const u8) !void {
        inline for (@typeInfo(@TypeOf(args.*)).@"struct".fields, 0..) |field, i| {
            if (i == positional_count.*) {
                const value = try parseValue(field.type, string);
                @field(args, field.name) = value;
                positional_count.* += 1;
                return;
            }
        }
        return error.UnexpectedPositionalArg;
    }

    fn addNamedArg(
        comptime template: anytype,
        args: *NamedArgs(template),
        flag: Flag,
        iter: *ArgIterator,
    ) !void {
        inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
            const listing: NamedListing = @field(template, field.name);

            if (flag.matchesListing(listing)) {
                if (isValueSet(@field(args, field.name)))
                    return error.DuplicateFlag;

                const value = try parseFlagValue(listing.value, iter);
                @field(args, field.name) = value;
                return;
            }
        }
        return error.InvalidFlag;
    }

    fn isValueSet(value: anytype) bool {
        return switch (@typeInfo(@TypeOf(value))) {
            .bool => value,
            .optional => value != null,
            else => unreachable,
        };
    }

    fn checkDependencies(comptime template: anytype, args: *const NamedArgs(template)) !void {
        inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
            const listing: NamedListing = @field(template, field.name);

            if (isValueSet(@field(args, field.name))) {
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
        args: *const NamedArgs(template),
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
        args: *const NamedArgs(template),
    ) bool {
        inline for (@typeInfo(@TypeOf(template)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, @tagName(dependency)))
                return isValueSet(@field(args, field.name));
        }
        unreachable; // conflict entry is not a valid field name
    }

    fn parseFlagValue(comptime T: type, iter: *ArgIterator) !(if (T == void) bool else T) {
        if (T == void)
            return true;
        const string = iter.next() orelse
            return error.ExpectedFlagValue;
        return try parseValue(T, string);
    }

    fn parseValue(comptime T: type, string: []const u8) !T {
        const is_flag = std.mem.startsWith(u8, string, "-");

        switch (T) {
            else => @compileError("unsupported flag value"),
            void => comptime unreachable,

            []const u8 => {
                if (is_flag) return error.UnexpectedFlag;
                return string;
            },

            Path => {
                if (std.mem.eql(u8, string, "-"))
                    return .stdio;
                if (is_flag) return error.UnexpectedFlag;
                return .{ .regular = string };
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
                if (short.len == 0)
                    return null;
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
