const Cli = @This();

const std = @import("std");
const assert = std.debug.assert;
const ArgIterator = std.process.Args.Iterator;

const elk = @import("elk");
const cli_template = @import("cli_template.zig");

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
        \\    -c, --check
        \\            Check an assembly file for errors without assembling.
        \\        --clean
        \\            Delete all output files (.obj, .sym, .lst) for an .asm file.
        \\
        \\OPTIONS:
        \\    -o, --output <FILE>
        \\            Specify filename of object, symbol table, or listing output.
        \\
        \\    -d, --debug
        \\            Run debugger while emulating. Requires --emulate or (default) operation.
        \\        --history-file <FILE>
        \\            Specify path for debugger history file. Requires --debug.
        \\    -C, --commands <COMMANDS>
        \\            Specify initial commands, separated with semicolons, that debugger shall run.
        \\                Requires --debug.
        \\
        \\        --export-symbols <FILE>
        \\            Write .sym symbol table file instead of compiling .obj. Requires --assemble.
        \\        --export-listing <FILE>
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
        output_mode: enum { none, assembly, symbols, listing },
    },
    emulate: struct {
        input: cli_template.Path,
        debug: ?Debug,
    },
    clean: struct {
        input: []const u8,
    },
    format: struct {
        input: cli_template.Path,
        output: ?cli_template.Path,
    },
    lsp: struct {},
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
            .conflicts = &.{ .emulate, .check, .clean, .format, .lsp },
        },
        .emulate = cli_template.NamedListing{
            .short = 'e',
            .long = "emulate",
            .conflicts = &.{ .assemble, .check, .clean, .format, .lsp },
        },
        .check = cli_template.NamedListing{
            .short = 'c',
            .long = "check",
            .conflicts = &.{ .assemble, .emulate, .clean, .format, .lsp },
        },
        .clean = cli_template.NamedListing{
            .long = "clean",
            .conflicts = &.{ .assemble, .emulate, .check, .format, .lsp },
        },
        .format = cli_template.NamedListing{
            .long = "format",
            .conflicts = &.{ .assemble, .emulate, .check, .clean, .lsp },
        },
        .lsp = cli_template.NamedListing{
            .long = "lsp",
            .conflicts = &.{ .assemble, .emulate, .check, .clean, .format },
        },

        .output = cli_template.NamedListing{
            .short = 'o',
            .long = "output",
            .value = cli_template.Path,
            .requires = &.{ &.{.assemble}, &.{.format} },
        },

        .export_symbols = cli_template.NamedListing{
            .long = "export-symbols",
            .requires = &.{&.{.assemble}},
            .conflicts = &.{.export_listing},
        },
        .export_listing = cli_template.NamedListing{
            .long = "export-listing",
            .requires = &.{&.{.assemble}},
            .conflicts = &.{.export_symbols},
        },

        .debug = cli_template.NamedListing{
            .short = 'd',
            .long = "debug",
            .conflicts = &.{ .assemble, .check, .clean, .format, .lsp },
        },

        .commands = cli_template.NamedListing{
            .short = 'C',
            .long = "commands",
            .value = []const u8,
            .requires = &.{&.{.debug}},
        },
        .history_file = cli_template.NamedListing{
            .long = "history-file",
            .value = []const u8,
            .requires = &.{&.{.debug}},
        },
        .import_symbols = cli_template.NamedListing{
            .long = "import-symbols",
            .value = []const u8,
            .requires = &.{&.{ .debug, .emulate }},
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

pub fn parse(iter: *ArgIterator) error{ ParseFailed, DisplayMetadata, UnimplementedFeature }!Cli {
    const args = cli_template.parse(template, iter) catch |err| switch (err) {
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
        "import_symbols",
    };
    for (unimplemented_args) |name| {
        inline for (@typeInfo(@TypeOf(args.named)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name) and
                cli_template.isValueSet(@field(args.named, field.name)))
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

    if (args.named.check) {
        return .{ .assemble = .{
            .input = args.positional.input,
            .output = null,
            .output_mode = .none,
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
            .input = args.positional.input.asRegular() catch unreachable,
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
