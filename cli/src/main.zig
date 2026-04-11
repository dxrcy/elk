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
    var reporter_impl = elk.Reporter.Stderr.new(&reporter_writer.interface);
    var reporter = reporter_impl.interface();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    const cli = Cli.parse(&args) catch |err| switch (err) {
        error.DisplayMetadata => return 0,
        else => return err,
    };

    reporter.options.strictness = cli.strictness;
    reporter_impl.verbosity = cli.verbosity;
    reporter.options.policies = cli.policies;

    var traps: elk.Traps = comptime .registerSets(&.{
        elk.Traps.Standard,
        elk.Traps.Debug,
    });

    inline for (@typeInfo(MczTraps).@"enum".fields) |field| {
        traps.register(field.value, .{
            .alias = field.name,
            .callback = .withDataDeferInit(
                *LazyConnection,
                @field(mcz_traps, field.name),
            ),
        });
    }

    const hooks: elk.Runtime.Hooks = .{};

    switch (cli.operation) {
        .assemble => |operation| {
            const source = try Io.Dir.cwd().readFileAlloc(io, operation.input.regular, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            var air = try assemble(gpa, source, &traps, &reporter);
            defer air.deinit(gpa);

            const out_extension = switch (operation.output_mode) {
                .assembly => "obj",
                .symbols => "sym",
                .listing => "lst",
            };

            var out_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const out_path = if (operation.output) |output|
                output.regular
            else
                replacePathExtension(&out_path_buffer, operation.input.regular, out_extension);

            var file = try Io.Dir.cwd().createFile(io, out_path, .{});
            defer file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = file.writer(io, &buffer);

            switch (operation.output_mode) {
                .assembly => try air.writeAssembly(&writer.interface),
                .symbols => try air.writeSymbols(&writer.interface, source),
                .listing => try air.writeListing(&writer.interface, source),
            }

            try writer.flush();
        },

        .emulate => |operation| {
            const file = try Io.Dir.cwd().openFile(io, operation.input.regular, .{});
            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .object = file },
                operation.debug,
                &traps,
                hooks,
                cli.policies,
                &reporter,
            );
        },

        .assemble_emulate => |operation| {
            const source = try Io.Dir.cwd().readFileAlloc(io, operation.input.regular, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            var air = try assemble(gpa, source, &traps, &reporter);
            defer air.deinit(gpa);

            try emulate(
                io,
                gpa,
                init.environ_map,
                .{ .assembly = .{ .air = &air, .source = source } },
                operation.debug,
                &traps,
                hooks,
                cli.policies,
                &reporter,
            );
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
    reporter: *elk.Reporter,
) !elk.Air {
    var air: elk.Air = .init();
    errdefer air.deinit(gpa);

    var parser = elk.Parser.new(traps, source, reporter) catch
        return error.ProgramError;

    try parser.parseAir(gpa, &air);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return error.ProgramError;
    }

    parser.resolveLabelReferences(&air);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return error.ProgramError;
    }

    reporter.showSummary();

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
    traps: *elk.Traps,
    hooks: elk.Runtime.Hooks,
    policies: elk.Policies,
    reporter: *elk.Reporter,
) !void {
    var conn_write_buffer: [1024]u8 = undefined;
    var conn_read_buffer: [1024]u8 = undefined;
    var conn: LazyConnection = .{ .uninit = .{
        .read_buffer = &conn_read_buffer,
        .write_buffer = &conn_write_buffer,
        .io = io,
    } };

    inline for (@typeInfo(MczTraps).@"enum".fields) |field| {
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
        });
    } else null;
    defer if (debugger_opt) |*debugger| debugger.deinit(gpa);

    var runtime = try elk.Runtime.init(.{
        .gpa = gpa,
        .reader = &reader.interface,
        .writer = &writer.interface,
        .traps = traps,
        .hooks = hooks,
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

const MczTraps = enum(u8) {
    chat = 0x28,
    getp = 0x29,
    setp = 0x2a,
    getb = 0x2b,
    setb = 0x2c,
    geth = 0x2d,
};

const mcz_traps = struct {
    fn chat(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const memory_str: MemoryStr = .{
            .runtime = runtime,
            .start = runtime.state.registers[0],
        };
        const conn = lazy.ensureInit() catch
            return error.TrapFailed;
        conn.postToChatFmt("{f}", .{memory_str}) catch
            return error.TrapFailed;
    }

    fn getp(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch
            return error.TrapFailed;
        const player = conn.getPlayerPosition() catch
            return error.TrapFailed;

        runtime.state.registers[0] = toWord(player.x);
        runtime.state.registers[1] = toWord(player.y);
        runtime.state.registers[2] = toWord(player.z);
    }

    fn setp(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch
            return error.TrapFailed;
        const player: mcz.Coordinate = .{
            .x = fromWord(runtime.state.registers[0]),
            .y = fromWord(runtime.state.registers[1]),
            .z = fromWord(runtime.state.registers[2]),
        };

        conn.setPlayerPosition(player) catch
            return error.TrapFailed;
    }

    fn getb(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch
            return error.TrapFailed;
        const coordinate: mcz.Coordinate = .{
            .x = fromWord(runtime.state.registers[0]),
            .y = fromWord(runtime.state.registers[1]),
            .z = fromWord(runtime.state.registers[2]),
        };

        const block = conn.getBlock(coordinate) catch
            return error.TrapFailed;

        runtime.state.registers[3] = @truncate(block.id);
    }

    fn setb(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch
            return error.TrapFailed;
        const coordinate: mcz.Coordinate = .{
            .x = fromWord(runtime.state.registers[0]),
            .y = fromWord(runtime.state.registers[1]),
            .z = fromWord(runtime.state.registers[2]),
        };

        const block: mcz.Block = .{
            .id = runtime.state.registers[3],
            .mod = 0,
        };

        conn.setBlock(coordinate, block) catch
            return error.TrapFailed;
    }

    fn geth(runtime: *elk.Runtime, lazy: *LazyConnection) elk.Traps.Result {
        const conn = lazy.ensureInit() catch
            return error.TrapFailed;
        const coordinate: mcz.Coordinate2D = .{
            .x = fromWord(runtime.state.registers[0]),
            .z = fromWord(runtime.state.registers[2]),
        };

        const height = conn.getHeight(coordinate) catch
            return error.TrapFailed;

        runtime.state.registers[1] = toWord(height);
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
