const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;
const assert = std.debug.assert;

const elk = @import("elk");

const Cli = @import("Cli.zig");

// TODO: Move buffer size definitions somewhere

pub fn main(init: std.process.Init) !u8 {
    return mainInner(init) catch |err| switch (err) {
        else => |e| e,
        error.Reported => 1,
    };
}

pub fn mainInner(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    const is_tty = try Io.File.stdout().isTty(io);

    const reporter_buffer_size = 1024;
    var reporter_buffer: [reporter_buffer_size]u8 = undefined;
    var reporter_writer = Io.File.stderr().writer(io, &reporter_buffer);
    var sink = elk.reporting.Sink.Fancy.new(&reporter_writer.interface, is_tty);

    var sink_collect = elk.reporting.Sink.Collect.init(gpa, sink.interface());
    defer sink_collect.deinit();
    var reporter = elk.reporting.Primary.new(sink_collect.interface());
    defer reporter.flush(); // Should already be flushed by now, but just in case

    const args_allocator = init.arena.allocator();
    var args = try Cli.zilc.collectArgs(args_allocator, init.minimal.args);
    defer args.deinit(init.arena.allocator());

    const cli = blk: {
        var temp_arena = std.heap.ArenaAllocator.init(gpa);
        defer temp_arena.deinit();
        break :blk Cli.parse(
            args_allocator,
            temp_arena.allocator(),
            &reporter_writer.interface,
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
                cli.random_init,
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
                cli.random_init,
            );
        },

        .assemble_emulate => |operation| {
            var assembler: elk.Assembler = .{
                .air = .init(),
                .source = .empty,
                .traps = &default_traps,
                .patch_symbols = operation.patch_symbols,
                .reporter = &reporter,
                .gpa = gpa,
                .io = io,
            };
            defer assembler.deinit();

            var input_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const input_path = try resolveInputPath(io, &input_path_buffer, operation.input);

            assembler.source = .{ .text = "", .path = input_path };
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
                cli.random_init,
            );
        },

        .assemble => |operation| {
            const traps = operation.options.trap_aliases orelse default_traps;
            var assembler: elk.Assembler = .{
                .air = .init(),
                .source = .empty,
                .traps = &traps,
                .patch_symbols = operation.options.patch_symbols,
                .reporter = &reporter,
                .gpa = gpa,
                .io = io,
            };
            defer assembler.deinit();

            switch (operation.paths) {
                .single => |single| {
                    try assembleFile(io, &assembler, single.input, single.output, operation.options);
                },
                .many => |many| {
                    var error_count: usize = 0;
                    for (many.inputs) |input| {
                        assembleFile(
                            io,
                            &assembler,
                            .{ .regular = input },
                            null,
                            operation.options,
                        ) catch |err| {
                            switch (err) {
                                error.Reported => {
                                    std.log.err("failed to assemble: {s}", .{input});
                                },
                                else => std.log.err("{t}: {s}", .{ err, input }),
                            }
                            error_count += 1;
                        };
                    }
                    if (error_count > 0) {
                        std.log.err("{} files failed to assemble", .{error_count});
                        return 1;
                    }
                },
            }
        },

        .clean => |operation| {
            var removed_count: usize = 0;
            switch (operation.paths) {
                .single => |single| {
                    assert(single.input == .regular);
                    assert(single.output == null);
                    removed_count += try cleanFile(io, single.input.regular);
                },
                .many => |many| {
                    var error_count: usize = 0;
                    for (many.inputs) |input| {
                        removed_count += cleanFile(io, input) catch |err| {
                            switch (err) {
                                error.Reported => {},
                                else => std.log.err("{t}: {s}", .{ err, input }),
                            }
                            error_count += 1;
                            continue;
                        };
                    }
                    if (error_count > 0) {
                        return 1;
                    }
                },
            }
            const input_count = operation.paths.count();
            std.log.info("removed {} output file{s} for {} input file{s}", .{
                removed_count,
                if (removed_count == 1) "" else "s",
                input_count,
                if (input_count == 1) "" else "s",
            });
        },

        .format => |operation| {
            std.log.err("unimplemented feature: format", .{});
            switch (operation.paths) {
                .single => |single| {
                    std.log.info("format input file: {s}", .{switch (single.input) {
                        .regular => |regular| regular,
                        .stdio => "(stdin)",
                    }});
                },
                .many => |many| {
                    for (many.inputs) |input| {
                        std.log.info("format input file: {s}", .{input});
                    }
                },
            }
            return 1;
        },

        .lsp => {
            std.log.err("unimplemented feature: lsp", .{});
            return 1;
        },
    }

    return 0;
}

fn assembleFile(
    io: Io,
    assembler: *elk.Assembler,
    input: Cli.Path,
    output: ?Cli.Path,
    options: Cli.Operation.Assemble,
) !void {
    var input_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const input_path = try resolveInputPath(io, &input_path_buffer, input);

    assembler.deinit();
    assembler.source = .{ .text = "", .path = input_path };
    try assembler.assembleFromFile();

    const out_file = try openOutputFile(io, output, options.output_mode, input_path) orelse
        return;
    defer out_file.close(io);

    const write_buffer_size = 512;
    var buffer: [write_buffer_size]u8 = undefined;
    var writer = out_file.writer(io, &buffer);

    switch (options.output_mode) {
        .none => unreachable,
        .assembly => try assembler.air.writeAssembly(&writer.interface),
        .symbols => try assembler.air.writeSymbols(&writer.interface, assembler.source),
        .listing => try assembler.air.writeListing(&writer.interface, assembler.source),
    }
    try writer.flush();
}

fn openOutputFile(
    io: Io,
    output: ?Cli.Path,
    output_mode: Cli.Operation.OutputMode,
    input_path: ?[]const u8,
) !?Io.File {
    const out_extension = output_mode.extension() orelse
        return null;

    const output_kind: union(enum) { stdio, regular: []const u8, auto } =
        if (output) |o| switch (o) {
            .stdio => .stdio,
            .regular => |regular| .{ .regular = regular },
        } else .auto;

    switch (output_kind) {
        .stdio => {
            return Io.File.stdout();
        },
        .regular => |regular| {
            return try Io.Dir.cwd().createFile(io, regular, .{});
        },
        .auto => {
            var out_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const out_path = replacePathExtension(
                &out_path_buffer,
                input_path orelse
                    unreachable, // Cli parsing should prevent this
                out_extension,
            );
            return try Io.Dir.cwd().createFile(io, out_path, .{});
        },
    }
}

fn resolveInputPath(io: Io, buffer: *[std.fs.max_path_bytes]u8, input: Cli.Path) !?[]const u8 {
    switch (input) {
        .stdio => return null,
        .regular => |regular| {
            const length = try Io.Dir.cwd().realPathFile(io, regular, buffer);
            return buffer[0..length];
        },
    }
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

    const read_buffer_size = 512;
    var buffer: [read_buffer_size]u8 = undefined;
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

const RuntimeSource = union(enum) {
    object: struct {
        file: Io.File,
        symbols: ?elk.Provider.Symbols,
    },
    assembly: elk.Provider.Assembly,
};

fn emulate(
    io: Io,
    // NOTE: Currently must be same allocated used by `Assembler`
    gpa: Allocator,
    environ_map: *const EnvironMap,
    runtime_source: RuntimeSource,
    patch_symbols_opt: ?[]const struct { []const u8, u16 },
    debug_opt: ?Cli.Operation.Debug,
    traps: *const elk.Traps,
    policies: elk.Policies,
    reporter: *elk.reporting.Primary,
    use_color: bool,
    assembler: ?*elk.Assembler,
    random_init: ?u64,
) !void {
    const write_buffer_size = 64;
    const debugger_buffer_size = 256;

    var write_buffer: [write_buffer_size]u8 = undefined;
    var debugger_buffer: [debugger_buffer_size]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &write_buffer);
    var reader = Io.File.stdin().reader(io, &.{});

    var debugger_opt: ?elk.Debugger = if (debug_opt) |debug| try createDebugger(
        io,
        gpa,
        environ_map,
        runtime_source,
        debug,
        traps,
        reporter,
        use_color,
        assembler,
        &reader.interface,
        &writer.interface,
        &debugger_buffer,
    ) else null;
    defer if (debugger_opt) |*debugger| debugger.deinit(gpa);

    var prng_storage: ?std.Random.DefaultPrng = null;
    if (random_init) |seed| {
        prng_storage = std.Random.DefaultPrng.init(seed);
    }

    var runtime = try elk.Runtime.init(.{
        .gpa = gpa,
        .reader = &reader.interface,
        .writer = &writer.interface,
        .traps = traps,
        .policies = policies,
        .debugger = if (debugger_opt) |*debugger| debugger else null,
        .random = if (prng_storage) |*prng| prng.random() else null,
    });
    defer runtime.deinit(gpa);

    try loadRuntime(io, &runtime, runtime_source);

    if (patch_symbols_opt) |patch_symbols|
        try patchSymbols(&runtime, runtime_source, patch_symbols);

    if (debugger_opt) |*debugger|
        try debugger.initState(gpa, &runtime);

    runtime.run() catch |err| switch (err) {
        error.OutOfMemory,
        error.WriteFailed,
        error.ReadFailed,
        error.EndOfStream,
        error.TermiosFailed,
        => |e| return e,

        else => |exception| {
            reporter.report(.emulate_exception, .{
                .code = exception,
            }).abort() catch
                {};
        },
    };

    try runtime.ensureWriterNewline();
    try runtime.writer.flush();
    reporter.flush();
}

fn createDebugger(
    // TODO: Use struct for all these params
    io: Io,
    gpa: Allocator,
    environ_map: *const EnvironMap,
    runtime_source: RuntimeSource,
    debug: Cli.Operation.Debug,
    traps: *const elk.Traps,
    reporter: *elk.reporting.Primary,
    use_color: bool,
    assembler: ?*elk.Assembler,
    reader: *Io.Reader,
    writer: *Io.Writer,
    debugger_buffer: []u8,
) !elk.Debugger {
    const empty_reader = &struct {
        var empty_reader: Io.Reader = .fixed(&.{});
    }.empty_reader;

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
        .none, .partial => reader,
        .full => empty_reader,
    };

    return try .init(.{
        .io = io,
        .gpa = gpa,
        .reader = debug_reader,
        .writer = writer,
        .traps = traps,
        .reporter = reporter,
        .command_buffer = debugger_buffer,
        .provider = provider,
        .assembler = assembler,
        .history_file = history_file,
        .initial_command_line = debug_input,
        .use_color = use_color,
    });
}

fn loadRuntime(io: Io, runtime: *elk.Runtime, runtime_source: RuntimeSource) !void {
    const read_buffer_size = 1024;

    switch (runtime_source) {
        .object => |object| {
            var read_buffer: [read_buffer_size]u8 = undefined;
            return runtime.readFromFile(io, object.file, &read_buffer);
        },
        .assembly => |assembly| {
            return assembly.air.copyToRuntime(runtime);
        },
    }
}

fn patchSymbols(
    runtime: *elk.Runtime,
    runtime_source: RuntimeSource,
    patch_symbols: []const struct { []const u8, u16 },
) !void {
    // TODO: Extract to function
    const symbols = switch (runtime_source) {
        .object => |object| object.symbols orelse unreachable,
        .assembly => unreachable,
    };
    for (patch_symbols) |item| {
        const symbol, const word = item;
        try runtime.patchLabelValue(symbol, word, symbols);
    }
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

/// Returns number of files removed.
fn cleanFile(io: Io, input: []const u8) !usize {
    if (!std.mem.endsWith(u8, input, ".asm")) {
        std.log.err("--clean requires filename to end with .asm", .{});
        return error.Reported;
    }

    const stat = Io.Dir.cwd().statFile(io, input, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("--clean requires existing .asm file", .{});
            return error.Reported;
        },
        else => |err2| return err2,
    };

    if (stat.kind != .file) {
        std.log.err("--clean requires regular .asm file", .{});
        return error.Reported;
    }

    var count: usize = 0;
    for (Cli.Operation.OutputMode.extensions) |extension| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = replacePathExtension(&path_buffer, input, extension);

        Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |err2| return err2,
        };
        count += 1;
    }
    return count;
}
