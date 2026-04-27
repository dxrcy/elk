const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const elk = @import("elk");
const mcz = @import("mcz");

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

    var default_traps: elk.Traps = comptime .registerSets(&.{
        elk.Traps.Standard,
        elk.Traps.Debug,
    });

    inline for (@typeInfo(McTrap).@"enum".fields) |field| {
        default_traps.register(field.value, .{
            .alias = field.name,
            .callback = .withDataDeferInit(
                *LazyConnection,
                @field(mc_traps, field.name),
            ),
        });
    }

    switch (cli.operation) {
        .assemble => |operation| {
            var input_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try Io.Dir.cwd().realPathFile(
                io,
                operation.input.asRegular() catch unreachable,
                &input_path_buffer,
            );
            const input_path = input_path_buffer[0..length];

            const text = try Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .unlimited);
            defer gpa.free(text);

            const source: elk.Source = .{
                .text = text,
                .path = input_path,
            };

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

            var symbols: std.ArrayList(elk.Runtime.SymbolEntry) = .empty;
            defer symbols.deinit(gpa);

            var symbol_names = std.heap.ArenaAllocator.init(gpa);
            defer symbol_names.deinit();

            if (operation.import_symbols) |sym_path| {
                try readSymbolTable(io, gpa, symbol_names.allocator(), sym_path, &symbols);
            }

            const file = try Io.Dir.cwd().openFile(io, input_path, .{});
            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .object = .{
                    .file = file,
                    .symbols = if (operation.import_symbols != null) symbols.items else null,
                } },
                operation.debug,
                &default_traps,
                cli.policies,
                &reporter,
            );
        },

        .assemble_emulate => |operation| {
            var input_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try Io.Dir.cwd().realPathFile(
                io,
                operation.input.asRegular() catch unreachable,
                &input_path_buffer,
            );
            const input_path = input_path_buffer[0..length];

            const text = try Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .unlimited);
            defer gpa.free(text);

            const source: elk.Source = .{
                .text = text,
                .path = input_path,
            };

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

fn readSymbolTable(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    filepath: []const u8,
    symbols: *std.ArrayList(elk.Runtime.SymbolEntry),
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

fn assemble(
    gpa: Allocator,
    source: elk.Source,
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
        object: struct {
            file: Io.File,
            symbols: ?[]const elk.Runtime.SymbolEntry,
        },
        assembly: elk.Debugger.Assembly,
    },
    debug_opt: ?Cli.Debug,
    traps: *elk.Traps,
    policies: elk.Policies,
    reporter: *elk.reporting.Primary,
) !void {
    var conn_write_buffer: [1024]u8 = undefined;
    var conn_read_buffer: [1024]u8 = undefined;
    var conn: LazyConnection = .{ .uninit = .{
        .read_buffer = &conn_read_buffer,
        .write_buffer = &conn_write_buffer,
        .io = io,
    } };

    inline for (@typeInfo(McTrap).@"enum".fields) |field| {
        traps.initData(field.value, *LazyConnection, &conn);
    }

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

        const provider: elk.Debugger.Provider = switch (runtime_source) {
            .object => |object| if (object.symbols) |symbols| .{ .symbols = symbols } else .none,
            .assembly => |assembly| .{ .assembly = assembly },
        };

        break :debugger try .init(.{
            .io = io,
            .gpa = gpa,
            .reader = &reader.interface,
            .writer = &writer.interface,
            .traps = traps,
            .reporter = reporter,
            .command_buffer = &debugger_buffer,
            .provider = provider,
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
        .object => |object| {
            var read_buffer: [1024]u8 = undefined;
            try runtime.readFromFile(io, object.file, &read_buffer);
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

const LazyConnection = union(enum) {
    init: mcz.Connection,
    uninit: struct {
        read_buffer: []u8,
        write_buffer: []u8,
        io: Io,
    },

    pub fn ensureInit(lazy: *LazyConnection) !*mcz.Connection {
        switch (lazy.*) {
            .init => {},
            .uninit => |setup| {
                lazy.* = .{
                    .init = try .new(
                        setup.write_buffer,
                        setup.read_buffer,
                        setup.io,
                    ),
                };
            },
        }
        return &lazy.init;
    }
};

const McTrap = enum(u8) {
    chat = 0x28,
    getp = 0x29,
    setp = 0x2a,
    getb = 0x2b,
    setb = 0x2c,
    geth = 0x2d,
};

const mc_traps = struct {
    fn chat(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const memory_str: MemoryStr = .{
            .runtime = runtime,
            .start = runtime.state.registers[0],
        };
        const conn = lazy.ensureInit() catch |err|
            return handleConnectionError(.chat, "connect", err);
        conn.postToChatFmt("{f}", .{memory_str}) catch |err|
            return handleConnectionError(.chat, "post to chat", err);
    }

    fn getp(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch |err|
            return handleConnectionError(.getp, "connect", err);
        const player = conn.getPlayerPosition() catch |err|
            return handleConnectionError(.getp, "get player position", err);

        runtime.state.registers[0] = toWord(player.x);
        runtime.state.registers[1] = toWord(player.y);
        runtime.state.registers[2] = toWord(player.z);
    }

    fn setp(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch |err|
            return handleConnectionError(.setp, "connect", err);
        const player: mcz.Coordinate = .{
            .x = fromWord(runtime.state.registers[0]),
            .y = fromWord(runtime.state.registers[1]),
            .z = fromWord(runtime.state.registers[2]),
        };

        conn.setPlayerPosition(player) catch |err|
            return handleConnectionError(.setp, "set player position", err);
    }

    fn getb(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch |err|
            return handleConnectionError(.getb, "connect", err);
        const coordinate: mcz.Coordinate = .{
            .x = fromWord(runtime.state.registers[0]),
            .y = fromWord(runtime.state.registers[1]),
            .z = fromWord(runtime.state.registers[2]),
        };

        const block = conn.getBlock(coordinate) catch |err|
            return handleConnectionError(.getb, "get block", err);

        runtime.state.registers[3] = @truncate(block.id);
    }

    fn setb(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch |err|
            return handleConnectionError(.setb, "connect", err);

        const coordinate: mcz.Coordinate = .{
            .x = fromWord(runtime.state.registers[0]),
            .y = fromWord(runtime.state.registers[1]),
            .z = fromWord(runtime.state.registers[2]),
        };

        const block: mcz.Block = .{
            .id = runtime.state.registers[3],
            .mod = 0,
        };

        conn.setBlock(coordinate, block) catch |err|
            return handleConnectionError(.setb, "set block", err);
    }

    fn geth(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch |err|
            return handleConnectionError(.geth, "connect", err);

        const coordinate: mcz.Coordinate2D = .{
            .x = fromWord(runtime.state.registers[0]),
            .z = fromWord(runtime.state.registers[2]),
        };

        const height = conn.getHeight(coordinate) catch |err|
            return handleConnectionError(.geth, "get height", err);

        runtime.state.registers[1] = toWord(height);
    }

    fn handleConnectionError(
        comptime trap: McTrap,
        comptime operation: []const u8,
        err: anyerror,
    ) error{TrapFailed} {
        std.log.err(
            "ELCI trap \"{t}\" failed to {s}: {t}",
            .{ trap, operation, err },
        );
        std.log.info("check that the ELCI server is live and accessible", .{});
        return error.TrapFailed;
    }

    fn toWord(value: i32) u16 {
        return @bitCast(@as(i16, @truncate(value)));
    }
    fn fromWord(value: u16) i32 {
        return @as(i16, @bitCast(value));
    }

    const MemoryStr = struct {
        runtime: *const elk.Runtime,
        start: u16,

        pub fn format(memory_str: *const MemoryStr, writer: *Io.Writer) Io.Writer.Error!void {
            for (memory_str.runtime.state.memory[memory_str.start..]) |word| {
                if (word == 0x0000)
                    break;
                const byte: u8 = @truncate(word);
                const char = switch (byte) {
                    '\n' | '\t' => ' ',
                    '\x20'...'\x7e' => byte,
                    else => continue,
                };
                try writer.print("{c}", .{char});
            }
        }
    };
};
