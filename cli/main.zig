const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const elk = @import("elk");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter_buffer: [1024]u8 = undefined;
    var reporter_writer = Io.File.stderr().writer(io, &reporter_buffer);
    var sink = elk.reporting.Sink.Fancy.new(&reporter_writer.interface);
    var reporter = elk.reporting.Primary.new(sink.interface());

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    const cli = Cli.parse(&args) catch |err| switch (err) {
        error.DisplayMetadata => return 0,
        error.ParseFailed, error.UnimplementedFeature => return 1,
    };

    reporter.options.strictness = cli.strictness;
    reporter.options.verbosity = cli.verbosity;
    reporter.options.policies = cli.policies;

    const default_traps: elk.Traps = comptime .registerSets(&.{
        elk.Traps.Standard,
        elk.Traps.Debug,
    });

    switch (cli.operation) {
        .assemble => |operation| {
            const input_path = operation.input.asRegular() catch unreachable;

            const source = try Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            const traps = operation.trap_aliases orelse default_traps;

            var air = assemble(gpa, source, &traps, &reporter) catch |err| switch (err) {
                error.ProgramError => return 1,
                else => |err2| return err2,
            };
            defer air.deinit(gpa);

            const out_extension = switch (operation.output_mode) {
                .none => return 0,
                .assembly => "obj",
                .symbols => "sym",
                .listing => "lst",
            };

            var out_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const out_path = if (operation.output) |output|
                output.asRegular() catch unreachable
            else
                replacePathExtension(&out_path_buffer, input_path, out_extension);

            var file = try Io.Dir.cwd().createFile(io, out_path, .{});
            defer file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = file.writer(io, &buffer);

            switch (operation.output_mode) {
                .none => unreachable,
                .assembly => try air.writeAssembly(&writer.interface),
                .symbols => try air.writeSymbols(&writer.interface, source),
                .listing => try air.writeListing(&writer.interface, source),
            }

            try writer.flush();
        },

        .emulate => |operation| {
            const input_path = operation.input.asRegular() catch unreachable;

            const file = try Io.Dir.cwd().openFile(io, input_path, .{});
            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .object = file },
                operation.debug,
                &default_traps,
                cli.policies,
                &reporter,
            );
        },

        .assemble_emulate => |operation| {
            const input_path = operation.input.asRegular() catch unreachable;

            const source = try Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            var air = assemble(gpa, source, &default_traps, &reporter) catch |err| switch (err) {
                error.ProgramError => return 1,
                else => |err2| return err2,
            };
            defer air.deinit(gpa);

            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .assembly = .{ .air = &air, .source = source } },
                operation.debug,
                &default_traps,
                cli.policies,
                &reporter,
            );
        },

        .clean => |operation| {
            if (!std.mem.endsWith(u8, operation.input, ".asm")) {
                std.log.err("--clean requires filename to end with .asm", .{});
                return error.BadFilename;
            }

            _ = Io.Dir.cwd().statFile(io, operation.input, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err("--clean requires existing .asm file", .{});
                    return error.BadFilename;
                },
                else => |err2| return err2,
            };

            const extensions = [_][]const u8{ "obj", "sym", "lst" };
            for (extensions) |extension| {
                var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const path = replacePathExtension(&path_buffer, operation.input, extension);

                Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => |err2| return err2,
                };
            }
        },

        else => unreachable,
    }

    return 0;
}

fn replacePathExtension(buffer: []u8, path: []const u8, extension: []const u8) []u8 {
    // FIXME: Assert can fit in buffer
    const index = std.mem.findScalarLast(u8, path, '.') orelse 0;
    @memcpy(buffer[0..index], path[0..index]);
    buffer[index] = '.';
    @memcpy(buffer[index + 1 ..][0..extension.len], extension);
    return buffer[0 .. index + 1 + extension.len];
}

fn assemble(
    gpa: Allocator,
    source: []const u8,
    traps: *const elk.Traps,
    reporter: *elk.reporting.Primary,
) !elk.Air {
    var air: elk.Air = .init();
    errdefer air.deinit(gpa);

    var parser = elk.Parser.new(traps, source, reporter) catch
        return error.ProgramError;

    try parser.parseAir(gpa, &air);
    if (reporter.getLevel() == .err) {
        reporter.summarize();
        return error.ProgramError;
    }

    parser.resolveLabelReferences(&air);
    if (reporter.getLevel() == .err) {
        reporter.summarize();
        return error.ProgramError;
    }

    reporter.summarize();

    return air;
}

fn emulate(
    io: Io,
    gpa: Allocator,
    environ_map: *const EnvironMap,
    runtime_source: union(enum) {
        object: Io.File,
        assembly: elk.Debugger.Assembly,
    },
    debug_opt: ?Cli.Debug,
    traps: *const elk.Traps,
    policies: elk.Policies,
    reporter: *elk.reporting.Primary,
) !void {
    var write_buffer: [64]u8 = undefined;
    var debugger_buffer: [256]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &write_buffer);
    var reader = Io.File.stdin().reader(io, &.{});

    var debugger_opt: ?elk.Debugger = if (debug_opt) |debug| debugger: {
        var history_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const history_path = if (debug.history_file) |path|
            path
        else
            try getHistoryPath(environ_map, &history_path_buffer);
        const history_file = openHistoryFile(io, history_path) catch |err| file: {
            std.log.err("failed to open/create history file: {t}", .{err});
            break :file null;
        };

        const assembly = switch (runtime_source) {
            .object => null,
            .assembly => |assembly| assembly,
        };

        break :debugger try .init(.{
            .io = io,
            .gpa = gpa,
            .reader = &reader.interface,
            .writer = &writer.interface,
            .traps = traps,
            .reporter = reporter,
            .command_buffer = &debugger_buffer,
            .assembly = assembly,
            .history_file = history_file,
            .initial_command_line = debug.commands orelse "",
        });
    } else null;
    defer if (debugger_opt) |*debugger| debugger.deinit(gpa);

    var runtime = try elk.Runtime.init(.{
        .gpa = gpa,
        .reader = &reader.interface,
        .writer = &writer.interface,
        .traps = traps,
        .policies = policies,
        .debugger = if (debugger_opt) |*debugger| debugger else null,
    });
    defer runtime.deinit(gpa);

    switch (runtime_source) {
        .object => |file| {
            var read_buffer: [1024]u8 = undefined;
            try runtime.readFromFile(io, file, &read_buffer);
        },
        .assembly => |assembly| {
            try assembly.air.copyToRuntime(&runtime);
        },
    }

    if (debugger_opt) |*debugger|
        try debugger.initState(gpa, &runtime);

    runtime.run() catch |err| switch (err) {
        error.WriteFailed,
        error.ReadFailed,
        error.TermiosFailed,
        => |err2| return err2,
        else => |err2| {
            std.log.err("runtime threw exception: {t}", .{err2});
        },
    };

    try runtime.ensureWriterNewline();
    try runtime.writer.flush();
}

fn getHistoryPath(environ_map: *const EnvironMap, buffer: []u8) ![]const u8 {
    const name = "elk-history";

    if (environ_map.get("XDG_CACHE_HOME")) |cache|
        return try std.fmt.bufPrint(buffer, "{s}/{s}", .{ cache, name });
    if (environ_map.get("HOME")) |home|
        return try std.fmt.bufPrint(buffer, "{s}/.cache/{s}", .{ home, name });
    if (environ_map.get("USER")) |user|
        return try std.fmt.bufPrint(buffer, "/home/{s}/.cache/{s}", .{ user, name });

    return error.CantFindPath;
}

fn openHistoryFile(io: Io, path: []const u8) !Io.File {
    const flags: Io.File.CreateFlags = .{
        .read = true,
        .truncate = false,
    };
    const file = try Io.Dir.createFileAbsolute(io, path, flags);

    return file;
}
