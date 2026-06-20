const Cli = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const elk = @import("elk");
const zilc = @import("zilc.zig");

const log = std.log.scoped(.cli);

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

operation: Operation,
policies: elk.Policies,
strictness: elk.reporting.Options.Strictness,
verbosity: elk.reporting.Options.Verbosity,

// TODO: Use `zilc.types.Path`
const Path = []const u8;

const Operation = union(enum) {
    assemble_emulate: struct {
        input: Path,
        debug: ?Debug,
    },
    assemble: struct {
        input: Path,
        output: ?zilc.types.Path,
        output_mode: enum { none, assembly, symbols, listing },
        trap_aliases: ?elk.Traps,
    },
    emulate: struct {
        input: Path,
        debug: ?Debug,
        import_symbols: ?[]const u8,
    },
    clean: struct {
        input: []const u8,
    },
    format: struct {
        input: Path,
        output: ?zilc.types.Path,
        trap_aliases: ?elk.Traps,
    },
    lsp: struct {},
};

pub const Debug = struct {
    commands: ?[]const u8,
    history_file: ?[]const u8,
};

const template = .{
    .assemble = zilc.Flag{
        .short = 'a',
        .long = "assemble",
    },
    .emulate = zilc.Flag{
        .short = 'e',
        .long = "emulate",
    },
    .check = zilc.Flag{
        .short = 'c',
        .long = "check",
    },
    .clean = zilc.Flag{
        .long = "clean",
    },
    .format = zilc.Flag{
        .long = "format",
    },
    .lsp = zilc.Flag{
        .long = "lsp",
    },

    .output = zilc.Flag{
        .short = 'o',
        .long = "output",
        .value = zilc.types.path,
    },

    .export_symbols = zilc.Flag{
        .long = "export-symbols",
    },
    .export_listing = zilc.Flag{
        .long = "export-listing",
    },
    .trap_aliases = zilc.Flag{
        .long = "trap-aliases",
        // TODO:
        .value = zilc.types.string,
        // .value = elk.Traps,
        // .value_parser = parseTrapAliases,
    },

    .debug = zilc.Flag{
        .short = 'd',
        .long = "debug",
    },

    .commands = zilc.Flag{
        .short = 'C',
        .long = "commands",
        .value = zilc.types.string,
    },
    .history_file = zilc.Flag{
        .long = "history-file",
        .value = zilc.types.string,
    },
    .import_symbols = zilc.Flag{
        .long = "import-symbols",
        .value = zilc.types.string,
    },

    .strict = zilc.Flag{
        .long = "strict",
    },
    .relaxed = zilc.Flag{
        .long = "relaxed",
    },
    .quiet = zilc.Flag{
        .short = 'q',
        .long = "quiet",
    },
    .permit = zilc.Flag{
        .short = 'p',
        .long = "permit",
        // TODO:
        .value = zilc.types.string,
        // .value = elk.Policies,
        // .value_parser = parsePolicies,
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

pub fn parse_old(iter: *std.process.Args.Iterator) error{ ParseFailed, DisplayMetadata, UnimplementedFeature }!Cli {
    const args = zilc.parse(template, iter) catch |err| switch (err) {
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
                zilc.isValueSet(@field(args.named, field.name)))
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

pub fn parse(gpa: Allocator, args: []const []const u8) !Cli {
    var temp_arena = std.heap.ArenaAllocator.init(gpa);
    defer temp_arena.deinit();

    if (zilc.getMetaArg(args)) |meta| {
        switch (meta) {
            .help => {
                std.debug.print("(help message)\n", .{});
                return error.DisplayMetadata;
            },
            .version => {
                std.debug.print("(version message)\n", .{});
                return error.DisplayMetadata;
            },
        }
    }

    var options: zilc.Options(template) = try .parse(temp_arena.allocator(), args);
    defer options.deinit(temp_arena.allocator());

    const operation = try parseOperation(&options);
    return .{
        .operation = operation,
        // TODO:
        .policies = .none,
        .strictness = if (options.flags.strict)
            .strict
        else if (options.flags.relaxed)
            .relaxed
        else
            .normal,
        .verbosity = if (options.flags.quiet) .quiet else .normal,
    };
}

fn parseOperation(options: *const zilc.Options(template)) !Operation {
    try zilc.checkGroup(.operation, enum { assemble, emulate, check, clean, format, lsp }, &options.flags);

    if (options.flags.debug)
        try zilc.checkConflicts(.debug, &.{}, &.{ .assemble, .check, .clean, .format, .lsp }, &options.flags);

    const input = try options.getPos(0, .input);

    if (options.flags.assemble) {
        return .{
            .assemble = .{
                .input = input,
                .output = options.flags.output,
                .output_mode = if (options.flags.export_symbols)
                    .symbols
                else if (options.flags.export_listing)
                    .listing
                else
                    .assembly,
                .trap_aliases = .{ .entries = @splat(.unset) },
                // .trap_aliases = options.flags.trap_aliases,
            },
        };
    }

    if (options.flags.emulate) {
        return .{ .emulate = .{
            .input = input,
            .debug = if (options.flags.debug) .{
                .commands = options.flags.commands,
                .history_file = options.flags.history_file,
            } else null,
            .import_symbols = options.flags.import_symbols,
        } };
    }

    if (options.flags.check) {
        return .{ .assemble = .{
            .input = input,
            .output = null,
            .output_mode = .none,
            .trap_aliases = .{ .entries = @splat(.unset) },
        } };
    }

    if (options.flags.clean) {
        return .{ .clean = .{
            .input = input,
        } };
    }

    if (options.flags.format) {
        return .{ .format = .{
            .input = input,
            .output = options.flags.output,
            .trap_aliases = .{ .entries = @splat(.unset) },
        } };
    }

    return .{
        .assemble_emulate = .{
            .input = input,
            .debug = if (options.flags.debug) .{
                .commands = options.flags.commands,
                .history_file = options.flags.history_file,
            } else null,
        },
    };
}
