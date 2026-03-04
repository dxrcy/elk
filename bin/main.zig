const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const lcz = @import("lcz");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = lcz.Reporter.new(io);
    try reporter.init();

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
            const air = try assemble(cli.filepath, &traps, &reporter, io, gpa);

            // TODO: Derive from `cli.filepath`
            const obj_path = "hw.obj";

            var file = try Io.Dir.cwd().createFile(io, obj_path, .{});
            defer file.close(io);

            var buffer: [512]u8 = undefined;
            var writer = file.writer(io, &buffer);

            try air.emitWriter(&writer.interface);
            try writer.flush();
        },

        .emulate => {
            const file = try Io.Dir.cwd().openFile(io, cli.filepath, .{});
            try emulate(.{ .file = file }, &traps, hooks, &policies, io, gpa);
        },

        .assemble_emulate => {
            const air = try assemble(cli.filepath, &traps, &reporter, io, gpa);
            try emulate(.{ .air = &air }, &traps, hooks, &policies, io, gpa);
        },
    }

    return 0;
}

fn assemble(
    filepath: []const u8,
    traps: *const lcz.Traps,
    reporter: *lcz.Reporter,
    io: Io,
    gpa: Allocator,
) !lcz.Air {
    const source = try Io.Dir.cwd().readFileAlloc(io, filepath, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    var air: lcz.Air = .init();
    defer air.deinit(gpa);

    var parser: lcz.Parser = .new(&air, traps, source, reporter);

    try parser.parse(gpa);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return error.ProgramError;
    }

    parser.resolveLabels();
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return error.ProgramError;
    }

    reporter.showSummary();

    return air;
}

fn emulate(
    runtime_source: union(enum) {
        file: Io.File,
        air: *const lcz.Air,
    },
    traps: *const lcz.Traps,
    hooks: lcz.Runtime.Hooks,
    policies: *const lcz.Policies,
    io: Io,
    gpa: Allocator,
) !void {
    var write_buffer: [64]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &write_buffer);
    var reader = Io.File.stdin().reader(io, &.{});

    var runtime = try lcz.Runtime.init(
        traps,
        hooks,
        policies,
        &writer.interface,
        &reader.interface,
        io,
        gpa,
    );
    defer runtime.deinit(gpa);

    switch (runtime_source) {
        .file => |file| {
            var read_buffer: [1024]u8 = undefined;
            try runtime.readFromFile(file, &read_buffer, io);
        },
        .air => |air| {
            try air.emitRuntime(&runtime);
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

    try runtime.writer.ensureNewline();
    try runtime.writer.interface.flush();
}
