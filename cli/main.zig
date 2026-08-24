const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const elk = @import("elk");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    const is_tty = try Io.File.stdout().isTty(io);

    var reporter_buffer: [1024]u8 = undefined;
    var reporter_writer = Io.File.stderr().writer(io, &reporter_buffer);
    var sink = elk.reporting.Sink.Fancy.new(&reporter_writer.interface, is_tty);
    var reporter = elk.reporting.Primary.new(sink.interface());

    const args_allocator = init.arena.allocator();
    var args = try Cli.zilc.collectArgs(args_allocator, init.minimal.args);
    defer args.deinit(init.arena.allocator());

    const cli = blk: {
        var temp_arena = std.heap.ArenaAllocator.init(gpa);
        defer temp_arena.deinit();
        break :blk Cli.parse(
            args_allocator,
            temp_arena.allocator(),
            args.items,
            is_tty,
        ) catch |err| switch (err) {
            else => return err,
            error.DisplayMetadata => return 0,
        };
    };

    reporter.options.strictness = cli.strictness;
    reporter.options.verbosity = cli.verbosity;
    reporter.options.policies = cli.policies;
    sink.use_color = cli.tty_color;

    const default_traps: elk.Traps = comptime .registerSets(&.{
        elk.Traps.Standard,
        elk.Traps.Debug,
    });

    switch (cli.operation) {
        .assemble => |operation| {
            var input_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const input_path = blk: switch (operation.input) {
                .stdio => null,
                .regular => |regular| {
                    const length = try Io.Dir.cwd().realPathFile(io, regular, &input_path_buffer);
                    break :blk input_path_buffer[0..length];
                },
            };

            const traps = operation.trap_aliases orelse default_traps;

            var assembler: elk.Assembler = .{
                .air = .init(),
                .source = .{
                    .text = "",
                    .path = input_path,
                },
                .traps = &traps,
                .patch_symbols = operation.patch_symbols,
                .reporter = &reporter,
                .gpa = gpa,
                .io = io,
            };
            defer assembler.deinit();

            try assembler.assembleFromFile();

            const out_extension = switch (operation.output_mode) {
                .none => return 0,
                .assembly => "obj",
                .symbols => "sym",
                .listing => "lst",
            };

            const output: union(enum) { stdio, regular: []const u8, auto } =
                if (operation.output) |output| switch (output) {
                    .stdio => .stdio,
                    .regular => |regular| .{ .regular = regular },
                } else .auto;

            var out_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var out_file = file: switch (output) {
                .stdio => {
                    break :file Io.File.stdout();
                },
                .regular => |regular| {
                    break :file try Io.Dir.cwd().createFile(io, regular, .{});
                },
                .auto => {
                    const out_path = replacePathExtension(
                        &out_path_buffer,
                        input_path orelse unreachable,
                        out_extension,
                    );
                    break :file try Io.Dir.cwd().createFile(io, out_path, .{});
                },
            };
            defer out_file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = out_file.writer(io, &buffer);

            switch (operation.output_mode) {
                .none => unreachable,
                .assembly => try assembler.air.writeAssembly(&writer.interface),
                .symbols => try assembler.air.writeSymbols(&writer.interface, assembler.source),
                .listing => try assembler.air.writeListing(&writer.interface, assembler.source),
            }

            try writer.flush();
        },

        .emulate => |operation| {
            const in_file = file: switch (operation.input) {
                .stdio => {
                    break :file Io.File.stdin();
                },
                .regular => |regular| {
                    break :file try Io.Dir.cwd().openFile(io, regular, .{});
                },
            };

            var symbols: std.ArrayList(elk.Provider.Symbols.Entry) = .empty;
            defer symbols.deinit(gpa);

            var symbol_names = std.heap.ArenaAllocator.init(gpa);
            defer symbol_names.deinit();

            if (operation.import_symbols) |sym_path| {
                try readSymbolTable(io, gpa, symbol_names.allocator(), sym_path, &symbols);
            }

            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .object = .{
                    .file = in_file,
                    .symbols = if (operation.import_symbols != null)
                        .{ .items = symbols.items }
                    else
                        null,
                } },
                operation.patch_symbols,
                operation.debug,
                &default_traps,
                cli.policies,
                &reporter,
                cli.tty_color,
                null,
            );
        },

        .debug_empty => |debug| {
            var air: elk.Air = .init();
            defer air.deinit(gpa);

            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .assembly = .{ .air = &air, .source = .empty } },
                null,
                debug,
                &default_traps,
                cli.policies,
                &reporter,
                cli.tty_color,
                null,
            );
        },

        .assemble_emulate => |operation| {
            var input_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const input_path = blk: switch (operation.input) {
                .stdio => null,
                .regular => |regular| {
                    const length = try Io.Dir.cwd().realPathFile(io, regular, &input_path_buffer);
                    break :blk input_path_buffer[0..length];
                },
            };

            var assembler: elk.Assembler = .{
                .air = .init(),
                .source = .{
                    .text = "",
                    .path = input_path,
                },
                .traps = &default_traps,
                .patch_symbols = operation.patch_symbols,
                .reporter = &reporter,
                .gpa = gpa,
                .io = io,
            };
            defer assembler.deinit();

            try assembler.assembleFromFile();

            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .assembly = .{ .air = &assembler.air, .source = assembler.source } },
                null,
                operation.debug,
                &default_traps,
                cli.policies,
                &reporter,
                cli.tty_color,
                &assembler,
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

fn readSymbolTable(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    filepath: []const u8,
    symbols: *std.ArrayList(elk.Provider.Symbols.Entry),
) !void {
    var file = try Io.Dir.cwd().openFile(io, filepath, .{});
    defer file.close(io);

    var buffer: [512]u8 = undefined;
    var reader = file.reader(io, &buffer);

    while (try reader.interface.takeDelimiter('\n')) |line| {
        var columns = std.mem.tokenizeScalar(u8, line, ' ');

        const name_temp = columns.next() orelse
            return error.MalformedSymbolTable;
        const address_string = columns.next() orelse
            return error.MalformedSymbolTable;

        if (address_string.len != 5 or address_string[0] != 'x')
            return error.MalformedSymbolTable;
        const address = std.fmt.parseInt(u16, address_string[1..], 16) catch
            return error.MalformedSymbolTable;

        const name = try arena.dupe(u8, name_temp);

        try symbols.append(gpa, .{ .address = address, .name = name });
    }
}

fn replacePathExtension(buffer: []u8, path: []const u8, extension: []const u8) []u8 {
    const index = std.mem.findScalarLast(u8, path, '.') orelse 0;
    @memcpy(buffer[0..index], path[0..index]);
    buffer[index] = '.';
    @memcpy(buffer[index + 1 ..][0..extension.len], extension);
    return buffer[0 .. index + 1 + extension.len];
}

fn emulate(
    io: Io,
    // NOTE: Currently must be same allocated used by `Assembler`
    gpa: Allocator,
    environ_map: *const EnvironMap,
    runtime_source: union(enum) {
        object: struct {
            file: Io.File,
            symbols: ?elk.Provider.Symbols,
        },
        assembly: elk.Provider.Assembly,
    },
    patch_symbols_opt: ?[]const struct { []const u8, u16 },
    debug_opt: ?Cli.Debug,
    traps: *const elk.Traps,
    policies: elk.Policies,
    reporter: *elk.reporting.Primary,
    use_color: bool,
    assembler: ?*elk.Assembler,
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

        const provider: elk.Provider = switch (runtime_source) {
            .object => |object| if (object.symbols) |symbols| .{ .symbols = symbols } else .none,
            .assembly => |assembly| .{ .assembly = assembly },
        };

        const debug_input = switch (debug.input) {
            .none => "",
            .partial, .full => |input| input,
        };
        const debug_reader = switch (debug.input) {
            .none, .partial => &reader.interface,
            .full => Io.Reader.ending,
        };

        break :debugger try .init(.{
            .io = io,
            .gpa = gpa,
            .reader = debug_reader,
            .writer = &writer.interface,
            .traps = traps,
            .reporter = reporter,
            .command_buffer = &debugger_buffer,
            .provider = provider,
            .assembler = assembler,
            .history_file = history_file,
            .initial_command_line = debug_input,
            .use_color = use_color,
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
        .object => |object| {
            var read_buffer: [1024]u8 = undefined;
            try runtime.readFromFile(io, object.file, &read_buffer);
        },
        .assembly => |assembly| {
            try assembly.air.copyToRuntime(&runtime);
        },
    }

    if (patch_symbols_opt) |patch_symbols| {
        const symbols = switch (runtime_source) {
            .object => |object| object.symbols orelse unreachable,
            .assembly => unreachable,
        };
        for (patch_symbols) |item| {
            const symbol, const word = item;
            try runtime.patchLabelValue(symbol, word, symbols);
        }
    }

    if (debugger_opt) |*debugger|
        try debugger.initState(gpa, &runtime);

    runtime.run() catch |err| switch (err) {
        error.OutOfMemory,
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        error.TermiosFailed,
        => |err2| return err2,

        else => |exception| {
            reporter.report(.emulate_exception, .{
                .code = exception,
            }).abort() catch
                {};
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
