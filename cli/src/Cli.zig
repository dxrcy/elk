const Cli = @This();

const std = @import("std");
const assert = std.debug.assert;
const ArgIterator = std.process.Args.Iterator;

const elk = @import("elk");

const cli_template = @import("cli_template.zig");

operation: Operation,
policies: elk.Policies,
strictness: elk.Reporter.Options.Strictness,
verbosity: elk.Reporter.Stderr.Verbosity,

const info = struct {
    const zon = @import("build_zon");

    const program = @tagName(zon.name);
    const version = zon.version;

    const help =
        program ++ " " ++ version ++ " by " ++ zon.author ++ ".\n" ++
        zon.description ++ " " ++ zon.homepage ++ "\n" ++
        \\
        \\USAGE:
        ++ "\n    " ++ program ++ " INPUT [OPERATION] [...OPTIONS]\n" ++
        \\
        \\INPUT:
        \\    Input filename: *.asm, or *.obj when used with --emulate
        \\
        \\OPERATION:
        \\    (default)
        \\            Assemble and emulate an .asm file. Supports --debug.
        \\    -a, --assemble
        \\            Assemble an .asm file and write output.
        \\    -e, --emulate
        \\            Emulate an assembled .obj file. Supports --debug.
        \\
        \\OPTIONS:
        \\    -o, --output [FILE]
        \\            Specify filename of object, symbol table, or listing output.
        \\
        \\    -d, --debug
        \\            Run debugger while emulating. Requires --emulate or (default) operation.
        \\        --history-file [FILE]
        \\            Specify path for debugger history file. Requires --debug.
        \\
        \\        --export-symbols [FILE]
        \\            Write .sym symbol table file instead of compiling .obj. Requires --assemble.
        \\        --export-listing [FILE]
        \\            Write .lst listing file instead of compiling .obj. Requires --assemble.
        \\
        \\        --strict
        \\            Treat all warnings as errors.
        \\        --relaxed
        \\            Ignore all warnings.
        \\    -q, --quiet
        \\            Show less output when assembling.
        \\    -p, --permit
        \\            Specify permitted policies or predefined policy sets.
        \\            Eg. --permit +laser,extension.stack_instructions
        \\
        \\ EXAMPLES:
        \\     elk hello.asm
        \\     elk hello.asm --debug
        \\     elk hello.asm --assemble --output hello.obj --strict --quiet
        \\     elk hello.asm --assemble --export-listing
        \\     elk hello.obj --emulate --permit +laser,extension.stack_instructions
        ;
};

const Operation = union(enum) {
    assemble_emulate: struct {
        input: cli_template.Path,
        debug: ?Debug,
    },
    assemble: struct {
        input: cli_template.Path,
        output: ?cli_template.Path,
        output_mode: enum { assembly, symbols, listing },
    },
    emulate: struct {
        input: cli_template.Path,
        debug: ?Debug,
    },
    format: struct {
        input: cli_template.Path,
        output: ?cli_template.Path,
    },
    clean: struct {
        input: cli_template.Path,
    },
};

pub const Debug = struct {
    commands: ?[]const u8,
    history_file: ?[]const u8,
    import_symbols: ?[]const u8,
};

const template = .{
    .positional = .{
        .input = cli_template.PositionalListing{
            .value = cli_template.Path,
        },
    },

    .named = .{
        .assemble = cli_template.NamedListing{
            .short = 'a',
            .long = "assemble",
            .conflicts = &.{ .emulate, .format, .clean },
        },
        .emulate = cli_template.NamedListing{
            .short = 'e',
            .long = "emulate",
            .conflicts = &.{ .assemble, .format, .clean },
        },
        .format = cli_template.NamedListing{
            .long = "format",
            .conflicts = &.{ .assemble, .emulate, .clean },
        },
        .clean = cli_template.NamedListing{
            .long = "clean",
            .conflicts = &.{ .assemble, .emulate, .format },
        },

        .output = cli_template.NamedListing{
            .short = 'o',
            .long = "output",
            .value = cli_template.Path,
            .requires = &.{ .assemble, .format },
        },

        .export_symbols = cli_template.NamedListing{
            .long = "export-symbols",
            .requires = &.{.assemble},
            .conflicts = &.{.export_listing},
        },
        .export_listing = cli_template.NamedListing{
            .long = "export-listing",
            .requires = &.{.assemble},
            .conflicts = &.{.export_symbols},
        },

        .debug = cli_template.NamedListing{
            .short = 'd',
            .long = "debug",
            .conflicts = &.{ .assemble, .format, .clean },
        },

        .commands = cli_template.NamedListing{
            .short = 'c',
            .long = "commands",
            .value = []const u8,
            .requires = &.{.debug},
        },
        .history_file = cli_template.NamedListing{
            .long = "history-file",
            .value = []const u8,
            .requires = &.{.debug},
        },
        .import_symbols = cli_template.NamedListing{
            .long = "import-symbols",
            .value = []const u8,
            .requires = &.{.debug},
        },

        .strict = cli_template.NamedListing{
            .long = "strict",
            .conflicts = &.{.relaxed},
        },
        .relaxed = cli_template.NamedListing{
            .long = "relaxed",
            .conflicts = &.{.strict},
        },
        .quiet = cli_template.NamedListing{
            .short = 'q',
            .long = "quiet",
        },
        .permit = cli_template.NamedListing{
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

pub fn parse(iter: *ArgIterator) !Cli {
    const args = cli_template.parse(template, iter) catch |err| switch (err) {
        error.ExpectedPositionalArg,
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
        "clean",
        "import_symbols",
        "commands",
    };
    for (unimplemented_args) |name| {
        inline for (@typeInfo(@TypeOf(args.named)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name) and
                cli_template.isValueSet(@field(args.named, field.name)))
            {
                std.log.err("unimplemented feature: {s}\n", .{field.name});
                return error.UnimplementedFeature;
            }
        }
    }

    if (args.positional.input == .stdio) {
        std.log.err("unimplemented feature: stdin input path\n", .{});
        return error.UnimplementedFeature;
    }
    if (args.named.output != null and args.named.output.? == .stdio) {
        std.log.err("unimplemented feature: stdout output path\n", .{});
        return error.UnimplementedFeature;
    }

    return .{
        .operation = parseOperation(&args),
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

fn parseOperation(args: *const cli_template.Args(template)) Operation {
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
