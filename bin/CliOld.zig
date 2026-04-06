const Cli = @This();

const std = @import("std");
const elk = @import("elk");

const Cli2 = struct {
    operation: Cli2.Command,
    strictness: ?elk.Reporter.Options.Strictness,
    verbosity: ?elk.Reporter.Stderr.Verbosity,
    policies: ?[]const u8,

    const Command = union(enum) {
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
};

filepath: []const u8,
command: Command,
debug: bool,

pub const Command = enum {
    assemble_emulate,
    assemble,
    emulate,

    const default: Command = .assemble_emulate;
};

pub fn parse(args: *std.process.Args.Iterator) anyerror!Cli {
    var partial: struct {
        filepath: ?[]const u8 = null,
        command: ?Command = null,
        debug: bool = false,
    } = .{};

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))
                return error.DisplayHelp;
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version"))
                return error.DisplayVersion;

            if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--assemble")) {
                if (partial.command != null)
                    return error.ConflictingOptionalArgument;
                partial.command = .assemble;
                continue;
            }
            if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--emulate")) {
                if (partial.command != null)
                    return error.ConflictingOptionalArgument;
                partial.command = .emulate;
                continue;
            }

            if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
                if (partial.debug)
                    return error.DuplicateOptionalArgument;
                partial.debug = true;
                continue;
            }

            return error.UnknownOptionalArgument;
        }

        if (partial.filepath != null)
            return error.UnexpectedPositionalArgument;
        partial.filepath = arg;
    }

    return .{
        .filepath = partial.filepath orelse
            return error.UnexpectedPositionalArgument,
        .command = partial.command orelse .default,
        .debug = partial.debug,
    };
}
