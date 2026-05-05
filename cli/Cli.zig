const Cli = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const ArgIterator = std.process.Args.Iterator;

const elk = @import("elk");
const templating = @import("templating.zig");

const log = std.log.scoped(.cli);

operation: Operation,
policies: elk.Policies,
strictness: elk.reporting.Options.Strictness,
verbosity: elk.reporting.Options.Verbosity,

const info = struct {
    const zon = @import("build_zon");

    const program = @tagName(zon.name);
    const version = zon.version;

    const help =
        program ++ " " ++ version ++ " by " ++ zon.author ++ ".\n" ++
        zon.description ++ " " ++ zon.homepage ++
        "\n\n" ++ "USAGE:" ++
        "\n    " ++ program ++ " INPUT [OPERATION] [...OPTIONS]" ++
        "\n\n" ++ @embedFile("help.txt"); // Includes trailing newline
};

const Operation = union(enum) {
    assemble_emulate: struct {
        input: templating.Path,
        debug: ?Debug,
    },
    assemble: struct {
        input: templating.Path,
        output: ?templating.Path,
        output_mode: enum { none, assembly, symbols, listing },
        trap_aliases: ?elk.Traps,
    },
    emulate: struct {
        input: templating.Path,
        debug: ?Debug,
        import_symbols: ?[]const u8,
    },
    clean: struct {
        input: []const u8,
    },
    format: struct {
        input: templating.Path,
        output: ?templating.Path,
        trap_aliases: ?elk.Traps,
    },
    lsp: struct {},
};

pub const Debug = struct {
    commands: ?[]const u8,
    history_file: ?[]const u8,
};

const Args = templating.Args(template);

const template = .{
    .positional = .{
        .input = templating.PositionalListing{
            .value = templating.Path,
        },
    },

    .named = .{
        .assemble = templating.NamedListing{
            .short = 'a',
            .long = "assemble",
        },
        .emulate = templating.NamedListing{
            .short = 'e',
            .long = "emulate",
        },
        .check = templating.NamedListing{
            .short = 'c',
            .long = "check",
        },
        .clean = templating.NamedListing{
            .long = "clean",
        },
        .format = templating.NamedListing{
            .long = "format",
        },
        .lsp = templating.NamedListing{
            .long = "lsp",
        },

        .output = templating.NamedListing{
            .short = 'o',
            .long = "output",
            .value = templating.Path,
        },

        .export_symbols = templating.NamedListing{
            .long = "export-symbols",
        },
        .export_listing = templating.NamedListing{
            .long = "export-listing",
        },
        .trap_aliases = templating.NamedListing{
            .long = "trap-aliases",
            .value = elk.Traps,
            .value_parser = parseTrapAliases,
        },

        .debug = templating.NamedListing{
            .short = 'd',
            .long = "debug",
        },

        .commands = templating.NamedListing{
            .short = 'C',
            .long = "commands",
            .value = []const u8,
        },
        .history_file = templating.NamedListing{
            .long = "history-file",
            .value = []const u8,
        },
        .import_symbols = templating.NamedListing{
            .long = "import-symbols",
            .value = []const u8,
        },

        .strict = templating.NamedListing{
            .long = "strict",
        },
        .relaxed = templating.NamedListing{
            .long = "relaxed",
        },
        .quiet = templating.NamedListing{
            .short = 'q',
            .long = "quiet",
        },
        .permit = templating.NamedListing{
            .short = 'p',
            .long = "permit",
            .value = elk.Policies,
            .value_parser = parsePolicies,
        },
    },
};

fn parsePolicies(string: []const u8, value: *anyopaque) error{InvalidArgumentValue}!void {
    const policies: *elk.Policies = @ptrCast(@alignCast(value));

    policies.* = elk.Policies.parseList(string) catch
        return error.InvalidArgumentValue;
}

fn parseTrapAliases(string: []const u8, value: *anyopaque) error{InvalidArgumentValue}!void {
    const traps: *elk.Traps = @ptrCast(@alignCast(value));
    traps.* = .{ .entries = @splat(.unset) };

    var items = std.mem.tokenizeScalar(u8, string, ',');
    while (items.next()) |item| {
        const alias, const vect_string = std.mem.cut(u8, item, "=x") orelse
            return error.InvalidArgumentValue;
        const vect = std.fmt.parseInt(u8, vect_string, 16) catch
            return error.InvalidArgumentValue;

        const entry: elk.Traps.Entry = .{ .alias = alias, .callback = null };
        if (!traps.canRegister(vect, entry))
            return error.InvalidArgumentValue;
        traps.register(vect, entry);
    }
}

pub fn parse(iter: *ArgIterator) error{ ParseFailed, DisplayMetadata, UnimplementedFeature }!Cli {
    const args = templating.parse(template, iter) catch |err| switch (err) {
        error.Empty,
        error.Help,
        => {
            std.debug.print(info.help ++ "\n", .{});
            return error.DisplayMetadata;
        },
        error.Version => {
            std.debug.print("{s}: {s}\n", .{ info.program, info.version });
            return error.DisplayMetadata;
        },
        else => |err2| return err2,
    };

    const unimplemented_args = [_][]const u8{
        "format",
        "lsp",
    };
    for (unimplemented_args) |name| {
        inline for (@typeInfo(@TypeOf(args.named)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name) and
                templating.isValueSet(@field(args.named, field.name)))
            {
                log.err("unimplemented feature: {s}", .{field.name});
                return error.UnimplementedFeature;
            }
        }
    }

    if (args.positional.input == .stdio and args.named.clean) {
        log.err("unsupported stdin input path for operation", .{});
        return error.ParseFailed;
    }

    if (args.positional.input == .stdio) {
        log.err("unimplemented feature: stdin input path", .{});
        return error.UnimplementedFeature;
    }
    if (args.named.output != null and args.named.output.? == .stdio) {
        log.err("unimplemented feature: stdout output path", .{});
        return error.UnimplementedFeature;
    }

    const operation = try parseOperation(&args);

    return .{
        .operation = operation,
        .policies = args.named.permit orelse .none,
        .strictness = if (args.named.strict)
            .strict
        else if (args.named.relaxed)
            .relaxed
        else
            .normal,
        .verbosity = if (args.named.quiet) .quiet else .normal,
    };
}

fn parseOperation(args: *const Args) error{ParseFailed}!Operation {
    try checkGroup(.operation, enum { assemble, emulate, check, clean, format, lsp }, args);

    if (args.named.debug)
        try checkConflicts(.debug, &.{}, &.{ .assemble, .check, .clean, .format, .lsp }, args);

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
            .trap_aliases = args.named.trap_aliases,
        } };
    }

    if (args.named.emulate) {
        return .{ .emulate = .{
            .input = args.positional.input,
            .debug = if (args.named.debug) .{
                .commands = args.named.commands,
                .history_file = args.named.history_file,
            } else null,
            .import_symbols = args.named.import_symbols,
        } };
    }

    if (args.named.check) {
        return .{ .assemble = .{
            .input = args.positional.input,
            .output = null,
            .output_mode = .none,
            .trap_aliases = args.named.trap_aliases,
        } };
    }

    if (args.named.clean) {
        return .{ .clean = .{
            .input = args.positional.input.asRegular() catch unreachable,
        } };
    }

    if (args.named.format) {
        return .{ .format = .{
            .input = args.positional.input,
            .output = args.named.output,
            .trap_aliases = args.named.trap_aliases,
        } };
    }

    return .{ .assemble_emulate = .{
        .input = args.positional.input,
        .debug = if (args.named.debug) .{
            .commands = args.named.commands,
            .history_file = args.named.history_file,
        } else null,
    } };
}

fn checkGroup(
    comptime name: @EnumLiteral(),
    comptime Group: type,
    args: *const Args,
) error{ParseFailed}!void {
    const GroupFmt = struct {
        pub fn format(_: @This(), writer: *Io.Writer) Io.Writer.Error!void {
            for (std.meta.tags(Group), 0..) |tag, i| {
                if (i > 0)
                    try writer.print(", ", .{});
                try writer.print("{t}", .{tag});
            }
        }
    };

    var existing = false;
    inline for (comptime std.meta.tags(Group)) |flag| {
        if (templating.isValueSet(@field(args.named, @tagName(flag)))) {
            if (existing) {
                log.err(
                    "multiple flags given for `{t}`: must be one of [{f}]",
                    .{ name, GroupFmt{} },
                );
                return error.ParseFailed;
            } else {
                existing = true;
            }
        }
    }
}

fn checkConflicts(
    comptime name: @EnumLiteral(),
    comptime requires: []const @EnumLiteral(),
    comptime conflicts: []const @EnumLiteral(),
    args: *const Args,
) error{ParseFailed}!void {
    inline for (requires) |require| {
        if (templating.isValueSet(@field(args.named, @tagName(require)))) {
            log.err("flag `{t}` cannot be used without required flag `{t}`", .{ name, require });
            return error.ParseFailed;
        }
    }
    inline for (conflicts) |conflict| {
        if (templating.isValueSet(@field(args.named, @tagName(conflict)))) {
            log.err("flag `{t}` cannot be used with conflicting flag `{t}`", .{ name, conflict });
            return error.ParseFailed;
        }
    }
}
