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

const Operation = union(enum) {
    assemble_emulate: struct {
        input: zilc.types.Path,
        debug: ?Debug,
    },
    assemble: struct {
        input: zilc.types.Path,
        output: ?zilc.types.Path,
        output_mode: enum { none, assembly, symbols, listing },
        trap_aliases: ?elk.Traps,
    },
    emulate: struct {
        input: zilc.types.Path,
        debug: ?Debug,
        import_symbols: ?[]const u8,
        patch_symbols: ?[]const struct { []const u8, u16 },
    },
    debug_empty: Debug,
    clean: struct {
        input: []const u8,
    },
    format: struct {
        input: zilc.types.Path,
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
        .value = .{ .type = elk.Traps, .parser = parseTrapAliases },
    },

    .debug = zilc.Flag{
        .short = 'd',
        .long = "debug",
    },
    .patch_symbols = zilc.Flag{
        .long = "patch",
        .value = .{ .type = []const struct { []const u8, u16 }, .parser = parsePatches },
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
        .value = .{ .type = elk.Policies, .parser = parsePolicies },
    },
};

fn parsePolicies(dest: *anyopaque, src: []const u8, _: Allocator) error{ParseFailed}!void {
    const policies: *?elk.Policies = @ptrCast(@alignCast(dest));
    policies.* = elk.Policies.parseList(src) catch
        return error.ParseFailed;
}

fn parseTrapAliases(dest: *anyopaque, src: []const u8, _: Allocator) error{ParseFailed}!void {
    const traps_opt: *?elk.Traps = @ptrCast(@alignCast(dest));
    traps_opt.* = .{ .entries = @splat(.unset) };
    const traps: *elk.Traps = &traps_opt.*.?;

    var items = std.mem.tokenizeScalar(u8, src, ',');
    while (items.next()) |item| {
        const alias, const vect = parseStringWordPair(item) orelse
            return error.ParseFailed;
        const entry: elk.Traps.Entry = .{ .alias = alias, .callback = null };
        if (!traps.canRegister(vect, entry))
            return error.ParseFailed;
        traps.register(vect, entry);
    }
}

fn parsePatches(dest: *anyopaque, src: []const u8, gpa: Allocator) error{ParseFailed}!void {
    const patches_opt: *?[]const struct { []const u8, u16 } = @ptrCast(@alignCast(dest));

    var patches: std.ArrayList(struct { []const u8, u16 }) = .empty;

    var items = std.mem.tokenizeScalar(u8, src, ',');
    while (items.next()) |item| {
        const symbol, const word = parseStringWordPair(item) orelse
            return error.ParseFailed;
        // TODO: Check if already patched
        patches.append(gpa, .{ symbol, word }) catch
            // TODO: Return OOM
            return error.ParseFailed;
    }

    patches_opt.* = patches.items;
}

fn parseStringWordPair(item: []const u8) ?struct { []const u8, u8 } {
    const parts = std.mem.cutScalar(u8, item, '=') orelse
        return null;

    const alias = std.mem.trim(u8, parts[0], &std.ascii.whitespace);
    const vect_string = std.mem.trim(u8, parts[1], &std.ascii.whitespace);

    const vect_integer = (elk.Parser.parseInteger(vect_string) catch
        return null) orelse return null;
    const vect = vect_integer.castToSmaller(u8) catch
        return null;

    return .{ alias, vect };
}

fn getMetaArg(args: []const []const u8) ?zilc.MetaArg {
    if (args.len == 0)
        return .help;
    return zilc.getMetaArg(args);
}

pub fn parse(gpa: Allocator, arena: Allocator, args: []const []const u8) !Cli {
    if (getMetaArg(args)) |meta| {
        switch (meta) {
            .help => {
                std.debug.print(info.help ++ "\n", .{});
                return error.DisplayMetadata;
            },
            .version => {
                std.debug.print("{s}: {s}\n", .{ info.program, info.version });
                return error.DisplayMetadata;
            },
        }
    }

    var options: zilc.Options(template) = try .parse(gpa, arena, args);
    defer options.deinit(arena);

    const unimplemented_args = [_][]const u8{
        "format",
        "lsp",
    };
    for (unimplemented_args) |name| {
        inline for (@typeInfo(@TypeOf(options.flags)).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name) and
                zilc.isFlagSet(@field(options.flags, field.name)))
            {
                log.err("unimplemented feature: {s}", .{field.name});
                return error.UnimplementedFeature;
            }
        }
    }

    if (options.getPosOptional(gpa, zilc.types.path, .input, 0)) |input| {
        if (options.flags.clean) {
            log.err("unsupported stdin input path for operation", .{});
            return error.ParseFailed;
        }
        if (input == .stdio and
            options.flags.output == null and
            options.flags.assemble)
        {
            log.err("--output is required for stdin input", .{});
            return error.ParseFailed;
        }
    }

    const operation = try parseOperation(gpa, &options);
    return .{
        .operation = operation,
        .policies = if (options.flags.permit) |policies| policies else .none,
        .strictness = if (options.flags.strict)
            .strict
        else if (options.flags.relaxed)
            .relaxed
        else
            .normal,
        .verbosity = if (options.flags.quiet) .quiet else .normal,
    };
}

fn parseOperation(gpa: Allocator, options: *const zilc.Options(template)) !Operation {
    try zilc.checkGroup(.operation, enum { assemble, emulate, check, clean, format, lsp }, &options.flags);
    try zilc.checkGroup(.export_mode, enum { export_symbols, export_listing }, &options.flags);
    try zilc.checkGroup(.verbosity, enum { strict, relaxed }, &options.flags);

    try zilc.checkDependencies(.output, enum { assemble, format }, enum {}, &options.flags);
    try zilc.checkDependencies(.export_symbols, enum { assemble }, enum {}, &options.flags);
    try zilc.checkDependencies(.export_listing, enum { assemble }, enum {}, &options.flags);
    try zilc.checkDependencies(.trap_aliases, enum { assemble, check, format }, enum {}, &options.flags);
    try zilc.checkDependencies(.debug, enum {}, enum { assemble, check, clean, format, lsp }, &options.flags);
    try zilc.checkDependencies(.patch_symbols, enum { emulate, import_symbols }, enum {}, &options.flags);
    try zilc.checkDependencies(.commands, enum { debug }, enum {}, &options.flags);
    try zilc.checkDependencies(.history_file, enum { debug }, enum {}, &options.flags);
    try zilc.checkDependencies(.import_symbols, enum { emulate }, enum {}, &options.flags);

    if (options.flags.debug and
        options.pos.items.len == 0) // TODO: There should be a better way to do this this check
    {
        return .{ .debug_empty = .{
            .commands = options.flags.commands,
            .history_file = options.flags.history_file,
        } };
    }

    const input = try options.getPos(gpa, zilc.types.path, .input, 0);
    if (options.pos.items.len > 1) {
        log.err("unexpected positional argument '{s}'", .{options.pos.items[1]});
        return error.ParseFailed;
    }

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
                .trap_aliases = options.flags.trap_aliases,
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
            .patch_symbols = options.flags.patch_symbols,
        } };
    }

    if (options.flags.check) {
        return .{ .assemble = .{
            .input = input,
            .output = null,
            .output_mode = .none,
            .trap_aliases = options.flags.trap_aliases,
        } };
    }

    if (options.flags.clean) {
        return .{ .clean = .{
            .input = switch (input) {
                .regular => |regular| regular,
                .stdio => unreachable,
            },
        } };
    }

    if (options.flags.format) {
        return .{ .format = .{
            .input = input,
            .output = options.flags.output,
            .trap_aliases = options.flags.trap_aliases,
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
