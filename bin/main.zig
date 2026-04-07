const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const elk = @import("elk");

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
        error.DisplayHelp => {
            std.debug.print("todo: help info\n", .{});
            return 0;
        },
        error.DisplayVersion => {
            std.debug.print("todo: version info\n", .{});
            return 0;
        },
        else => return err,
    };

    reporter.options.strictness = cli.strictness;
    reporter_impl.verbosity = cli.verbosity;
    reporter.options.policies = cli.policies;

    const traps: elk.Traps = comptime .registerSets(&.{
        elk.Traps.Standard,
        elk.Traps.Debug,
    });
    const hooks: elk.Runtime.Hooks = .{};

    switch (cli.operation) {
        .assemble => |operation| {
            const source = try Io.Dir.cwd().readFileAlloc(io, operation.input.regular, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            var air = try assemble(gpa, source, &traps, &reporter);
            defer air.deinit(gpa);

            var obj_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const obj_path = if (operation.output) |output|
                output.regular
            else
                replacePathExtension(&obj_path_buffer, operation.input.regular, "obj");

            var file = try Io.Dir.cwd().createFile(io, obj_path, .{});
            defer file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = file.writer(io, &buffer);

            try air.emitWriter(&writer.interface);
            try writer.flush();
        },

        .emulate => |operation| {
            const file = try Io.Dir.cwd().openFile(io, operation.input.regular, .{});
            try emulate(
                io,
                gpa,
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
    runtime_source: union(enum) {
        object: Io.File,
        assembly: elk.Debugger.Assembly,
    },
    debug_opt: ?Cli.Debug,
    traps: *const elk.Traps,
    hooks: elk.Runtime.Hooks,
    policies: elk.Policies,
    reporter: *elk.Reporter,
) !void {
    var write_buffer: [64]u8 = undefined;
    var debugger_buffer: [256]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &write_buffer);
    var reader = Io.File.stdin().reader(io, &.{});

    var debugger_opt: ?elk.Debugger = if (debug_opt) |debug| debugger: {
        const history_path = if (debug.history_file) |path| path else getHistoryPath();
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
            try assembly.air.emitRuntime(&runtime);
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

fn getHistoryPath() []const u8 {
    // FIXME: Get path programatically
    return "/home/darcy/.cache/elk-history";
}

fn openHistoryFile(io: Io, path: []const u8) !Io.File {
    const flags: Io.File.CreateFlags = .{
        .read = true,
        .truncate = false,
    };
    const file = try Io.Dir.createFileAbsolute(io, path, flags);

    return file;
}
