const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const lcz = @import("lcz");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter_buffer: [1024]u8 = undefined;
    var reporter_writer = Io.File.stderr().writer(io, &reporter_buffer);
    var reporter_impl = lcz.Reporter.Stderr.new(&reporter_writer.interface);
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

    const policies: lcz.Policies = .config_lace;
    reporter.options.policies = &policies;

    const traps: lcz.Traps = comptime .initBuiltins(&.{
        lcz.Traps.Standard,
        lcz.Traps.Debug,
    });
    const hooks: lcz.Runtime.Hooks = .{};

    switch (cli.command) {
        .assemble => {
            const source = try Io.Dir.cwd().readFileAlloc(io, cli.filepath, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            var air = try assemble(gpa, source, &traps, &reporter);
            defer air.deinit(gpa);

            var obj_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const obj_path = replacePathExtension(&obj_path_buffer, cli.filepath, "obj");

            var file = try Io.Dir.cwd().createFile(io, obj_path, .{});
            defer file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = file.writer(io, &buffer);

            try air.emitWriter(&writer.interface);
            try writer.flush();
        },

        .emulate => {
            const file = try Io.Dir.cwd().openFile(io, cli.filepath, .{});
            try emulate(
                io,
                gpa,
                .{ .object = file },
                cli.debug,
                &traps,
                hooks,
                &policies,
                &reporter,
            );
        },

        .assemble_emulate => {
            const source = try Io.Dir.cwd().readFileAlloc(io, cli.filepath, gpa, .unlimited);
            defer gpa.free(source);

            reporter.source = source;

            var air = try assemble(gpa, source, &traps, &reporter);
            defer air.deinit(gpa);

            try emulate(
                io,
                gpa,
                .{ .assembly = .{ .air = &air, .source = source } },
                cli.debug,
                &traps,
                hooks,
                &policies,
                &reporter,
            );
        },
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
    traps: *const lcz.Traps,
    reporter: *lcz.Reporter,
) !lcz.Air {
    var air: lcz.Air = .init();
    errdefer air.deinit(gpa);

    var parser = lcz.Parser.new(traps, source, reporter) orelse
        return error.ProgramError;

    try parser.parse(gpa, &air);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return error.ProgramError;
    }

    parser.resolveLabels(&air);
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
        assembly: lcz.Runtime.Debugger.Assembly,
    },
    debug: bool,
    traps: *const lcz.Traps,
    hooks: lcz.Runtime.Hooks,
    policies: *const lcz.Policies,
    reporter: *lcz.Reporter,
) !void {
    var write_buffer: [64]u8 = undefined;
    var debugger_buffer: [64]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &write_buffer);
    var reader = Io.File.stdin().reader(io, &.{});

    var debugger_opt: ?lcz.Runtime.Debugger = if (debug) .init(
        gpa,
        &reader.interface,
        &writer.interface,
        reporter,
        &debugger_buffer,
        switch (runtime_source) {
            .object => null,
            .assembly => |assembly| assembly,
        },
    ) else null;
    defer if (debugger_opt) |*debugger| debugger.deinit(gpa);

    var runtime = try lcz.Runtime.init(
        gpa,
        &reader.interface,
        &writer.interface,
        traps,
        hooks,
        policies,
        if (debugger_opt) |*debugger| debugger else null,
    );
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
