const Cli = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const elk = @import("elk");
pub const zilc = @import("zilc");
pub const Path = zilc.types.Path;

const log = std.log.scoped(.cli);

const info = struct {
    const zon = @import("build_zon");

    const program = @tagName(zon.name);

    const version =
        program ++ " " ++ zon.version ++ " by " ++ zon.author ++ ".\n" ++
        zon.description ++ " " ++ zon.homepage ++ "\n" ++
        "Copyright (C) 2025 " ++ zon.author ++ "\n" ++
        "License: GPL-3.0-only" ++ "\n\n";

    const help =
        version ++
        "USAGE:" ++ "\n" ++
        "    " ++ program ++ " INPUT [OPERATION] [...OPTIONS]" ++ "\n\n" ++
        @embedFile("help.txt") // File includes trailing newline
        ++ "\n";
};

operation: Operation,
policies: elk.Policies,
strictness: elk.reporting.Options.Strictness,
verbosity: elk.reporting.Options.Verbosity,
tty_color: bool,

pub const Operation = union(enum) {
    assemble_emulate: struct {
        input: Path,
        debug: ?Debug,
        patch_symbols: ?[]const struct { []const u8, u16 },
    },
    assemble: struct {
        paths: IoPaths,
        options: Assemble,
    },
    emulate: struct {
        input: Path,
        debug: ?Debug,
        import_symbols: ?[]const u8,
        patch_symbols: ?[]const struct { []const u8, u16 },
    },
    debug_empty: Debug,
    clean: struct {
        input: []const u8,
    },
    format: struct {
        input: Path,
        output: ?Path,
        trap_aliases: ?elk.Traps,
    },
    lsp: struct {},

    pub const IoPaths = union(enum) {
        single: struct {
            input: Path,
            output: ?Path,
        },
        many: struct {
            inputs: []const []const u8,
        },
    };

    pub const Assemble = struct {
        output_mode: OutputMode,
        trap_aliases: ?elk.Traps,
        patch_symbols: ?[]const struct { []const u8, u16 },
    };

    pub const OutputMode = enum {
        none,
        assembly,
        symbols,
        listing,

        pub const extensions = [_][]const u8{ "obj", "sym", "lst" };

        pub fn extension(output_mode: OutputMode) ?[]const u8 {
            return switch (output_mode) {
                .none => null,
                .assembly => "obj",
                .symbols => "sym",
                .listing => "lst",
            };
        }
    };

    pub const Debug = struct {
        input: Input,
        history_file: ?[]const u8,

        pub const Input = union(enum) {
            none,
            partial: []const u8,
            full: []const u8,
        };
    };
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

    .input_partial = zilc.Flag{
        .short = 'i',
        .long = "input",
        .value = zilc.types.string,
    },
    .input_full = zilc.Flag{
        .short = 'I',
        .long = "input-full",
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
    .color_mode = zilc.Flag{
        .long = "color",
        .value = .{ .type = ColorMode, .parser = parseColorMode },
    },
};

const ColorMode = enum { auto, always, never };

fn parseColorMode(dest: *anyopaque, src: []const u8, _: Allocator) !void {
    const color_mode: *?ColorMode = @ptrCast(@alignCast(dest));
    if (std.mem.eql(u8, src, "auto")) {
        color_mode.* = .auto;
        return;
    }
    if (std.mem.eql(u8, src, "always")) {
        color_mode.* = .always;
        return;
    }
    if (std.mem.eql(u8, src, "never")) {
        color_mode.* = .never;
        return;
    }
    return error.InvalidValue;
}

fn parsePolicies(dest: *anyopaque, src: []const u8, _: Allocator) !void {
    const policies: *?elk.Policies = @ptrCast(@alignCast(dest));
    policies.* = elk.Policies.parseList(src) catch
        return error.InvalidValue;
}

fn parseTrapAliases(dest: *anyopaque, src: []const u8, _: Allocator) !void {
    const traps_opt: *?elk.Traps = @ptrCast(@alignCast(dest));
    traps_opt.* = .{ .entries = @splat(.unset) };
    const traps: *elk.Traps = &traps_opt.*.?;

    var items = std.mem.tokenizeScalar(u8, src, ',');
    while (items.next()) |item| {
        const alias, const vect = parseStringIntPair(u8, item) orelse
            return error.InvalidValue;
        const entry: elk.Traps.Entry = .{ .alias = alias, .callback = null };
        if (!traps.canRegister(vect, entry))
            return error.InvalidValue;
        traps.register(vect, entry);
    }
}

fn parsePatches(dest: *anyopaque, src: []const u8, gpa: Allocator) !void {
    const patches_opt: *?[]const struct { []const u8, u16 } = @ptrCast(@alignCast(dest));
    var patches: std.ArrayList(struct { []const u8, u16 }) = .empty;

    var items = std.mem.tokenizeScalar(u8, src, ',');
    while (items.next()) |item| {
        const symbol, const word = parseStringIntPair(u16, item) orelse
            return error.InvalidValue;
        for (patches.items) |patch| {
            if (std.mem.eql(u8, patch[0], symbol))
                return error.InvalidValue;
        }
        try patches.append(gpa, .{ symbol, word });
    }

    patches_opt.* = patches.items;
}

fn parseStringIntPair(comptime Int: type, item: []const u8) ?struct { []const u8, Int } {
    const parts = std.mem.cutScalar(u8, item, '=') orelse
        return null;

    const alias = std.mem.trim(u8, parts[0], &std.ascii.whitespace);
    const vect_string = std.mem.trim(u8, parts[1], &std.ascii.whitespace);

    const vect_integer = (elk.Parser.parseInteger(vect_string) catch
        return null) orelse return null;
    const vect = vect_integer.castToSmaller(Int) catch
        return null;

    return .{ alias, vect };
}

pub fn parse(
    gpa: Allocator,
    arena: Allocator,
    writer: *std.Io.Writer,
    args: []const []const u8,
    is_tty: bool,
) !Cli {
    if (zilc.getMetaArg(args, .help)) |meta| {
        switch (meta) {
            .help => {
                try writer.writeAll(info.help);
                try writer.flush();
                return error.DisplayMetadata;
            },
            .version => {
                try writer.writeAll(info.version);
                try writer.flush();
                return error.DisplayMetadata;
            },
        }
    }

    var options: zilc.Options(template) = try .parse(gpa, arena, args, .{});
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
        if (input == .stdio) {
            if (options.flags.clean) {
                log.err("unsupported stdin input path for operation", .{});
                return error.ParseFailed;
            }
            if (options.flags.output == null and
                options.flags.assemble)
            {
                log.err("--output is required for stdin input", .{});
                return error.ParseFailed;
            }
        }
    }

    try checkDependencies(&options);
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
        .tty_color = switch (options.flags.color_mode orelse .auto) {
            .auto => is_tty,
            .always => true,
            .never => false,
        },
    };
}

fn checkDependencies(options: *const zilc.Options(template)) !void {
    try zilc.checkGroup(.operation, enum { assemble, emulate, check, clean, format, lsp }, &options.flags);
    try zilc.checkGroup(.export_mode, enum { export_symbols, export_listing }, &options.flags);
    try zilc.checkGroup(.verbosity, enum { strict, relaxed }, &options.flags);

    try zilc.checkDependencies(.output, enum { assemble, format }, enum {}, &options.flags);
    try zilc.checkDependencies(.export_symbols, enum { assemble }, enum {}, &options.flags);
    try zilc.checkDependencies(.export_listing, enum { assemble }, enum {}, &options.flags);
    try zilc.checkDependencies(.trap_aliases, enum { assemble, check, format }, enum {}, &options.flags);
    try zilc.checkDependencies(.debug, enum {}, enum { assemble, check, clean, format, lsp }, &options.flags);
    try zilc.checkDependencies(.input_partial, enum { debug }, enum { input_full }, &options.flags);
    try zilc.checkDependencies(.input_full, enum { debug }, enum { input_partial }, &options.flags);
    try zilc.checkDependencies(.history_file, enum { debug }, enum {}, &options.flags);
    try zilc.checkDependencies(.import_symbols, enum { emulate }, enum {}, &options.flags);

    if (options.flags.emulate) {
        try zilc.checkDependencies(.patch_symbols, enum { import_symbols }, enum {}, &options.flags);
    } else if (options.flags.assemble) {
        //
    } else {
        try zilc.checkDependencies(.patch_symbols, enum {}, enum { check, clean, format, lsp }, &options.flags);
    }
}

fn parseOperation(gpa: Allocator, options: *const zilc.Options(template)) !Operation {
    const debug_input: Operation.Debug.Input =
        if (options.flags.input_full) |input|
            .{ .full = input }
        else if (options.flags.input_partial) |input|
            .{ .partial = input }
        else
            .none;

    if (options.flags.debug and
        options.pos.items.len == 0) // TODO: There should be a better way to do this this check
    {
        return .{ .debug_empty = .{
            .input = debug_input,
            .history_file = options.flags.history_file,
        } };
    }

    if (options.pos.items.len > 1) {
        const output_mode: Operation.OutputMode =
            if (options.flags.check)
                .none
            else if (options.flags.assemble)
                if (options.flags.export_symbols)
                    .symbols
                else if (options.flags.export_listing)
                    .listing
                else
                    .assembly
            else {
                log.err("multiple input arguments require --assemble or --check", .{});
                return error.ParseFailed;
            };
        if (options.flags.output) |_| {
            log.err("--output cannot be used with multiple input arguments", .{});
            return error.ParseFailed;
        }
        const inputs = try gpa.dupe([]const u8, options.pos.items);
        for (options.pos.items) |input| {
            if (Path.new(input) != .regular) {
                log.err("stdin input is not supported with multiple inputs", .{});
                return error.ParseFailed;
            }
        }
        return .{
            .assemble = .{
                .paths = .{ .many = .{
                    .inputs = inputs,
                } },
                .options = .{
                    .output_mode = output_mode,
                    .trap_aliases = options.flags.trap_aliases,
                    .patch_symbols = options.flags.patch_symbols,
                },
            },
        };
    }

    const input = try options.getPos(gpa, zilc.types.path, .input, 0);

    if (options.flags.assemble) {
        return .{
            .assemble = .{
                .paths = .{ .single = .{
                    .input = input,
                    .output = options.flags.output,
                } },
                .options = .{
                    .output_mode = if (options.flags.export_symbols)
                        .symbols
                    else if (options.flags.export_listing)
                        .listing
                    else
                        .assembly,
                    .trap_aliases = options.flags.trap_aliases,
                    .patch_symbols = options.flags.patch_symbols,
                },
            },
        };
    }

    if (options.flags.emulate) {
        return .{ .emulate = .{
            .input = input,
            .debug = if (options.flags.debug) .{
                .input = debug_input,
                .history_file = options.flags.history_file,
            } else null,
            .import_symbols = options.flags.import_symbols,
            .patch_symbols = options.flags.patch_symbols,
        } };
    }

    if (options.flags.check) {
        return .{ .assemble = .{
            .paths = .{ .single = .{
                .input = input,
                .output = null,
            } },
            .options = .{
                .output_mode = .none,
                .trap_aliases = options.flags.trap_aliases,
                .patch_symbols = options.flags.patch_symbols,
            },
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
                .input = debug_input,
                .history_file = options.flags.history_file,
            } else null,
            .patch_symbols = options.flags.patch_symbols,
        },
    };
}
