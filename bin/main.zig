const std = @import("std");
const Io = std.Io;

const lcz = @import("lcz");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter_buffer: [1024]u8 = undefined;
    var reporter_writer = Io.File.stderr().writer(io, &reporter_buffer);
    var reporter_impl = lcz.Reporter.Stderr.new(&reporter_writer.interface);
    var reporter = reporter_impl.interface();

    const asm_path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, asm_path, gpa, .unlimited);
    defer gpa.free(source);

    reporter_impl.setSource(source);

    // reporter.options.strictness = .normal;
    // reporter_impl.verbosity = .normal;

    const policies: lcz.Policies = .config_lace;
    reporter.options.policies = &policies;

    var air: lcz.Air = .init();
    defer air.deinit(gpa);

    const traps: lcz.Traps = comptime .initBuiltins(&.{
        lcz.Traps.Standard,
        lcz.Traps.Debug,
    });

    var parser = lcz.Parser.new(&traps, source, &reporter) orelse
        return 1;

    try parser.parse(gpa, &air);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return 1;
    }

    parser.resolveLabels(&air);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return 1;
    }

    reporter.showSummary();

    {
        const bin_path = "hw.obj";

        var file = try Io.Dir.cwd().createFile(io, bin_path, .{});
        defer file.close(io);

        var buffer: [512]u8 = undefined;
        var writer = file.writer(io, &buffer);

        try air.emitWriter(&writer.interface);
        try writer.flush();
    }

    {
        var reader = Io.File.stdin().reader(io, &.{});
        var write_buffer: [64]u8 = undefined;
        var writer = Io.File.stdout().writer(io, &write_buffer);

        // var instr_count: InstrCount = .initFill(0);

        const hooks: lcz.Runtime.Hooks = .{
            // .pre_decode = .withoutData(preDecodeHook),
            // .pre_execute = .withDataInit(*InstrCount, preExecuteHook, &instr_count),
        };

        var runtime = try lcz.Runtime.init(
            io,
            gpa,
            &reader.interface,
            &writer.interface,
            &traps,
            hooks,
            &policies,
            true,
        );
        defer runtime.deinit(gpa);

        const obj_path = "hw.obj";
        const obj_file = try Io.Dir.cwd().openFile(io, obj_path, .{});
        var read_buffer: [1024]u8 = undefined;

        try runtime.readFromFile(io, obj_file, &read_buffer);
        // try air.emitRuntime(&runtime);

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

        // for (runtime.registers, 0..) |register, i| {
        //     std.debug.print("r{}: 0x{x:04}\n", .{ i, register });
        // }
        //
        // for (std.meta.tags(std.meta.Tag(lcz.Runtime.Instruction))) |field| {
        //     const count = instr_count.get(field);
        //     std.debug.print("{t:20}: {}\n", .{ field, count });
        // }
    }

    return 0;
}

const InstrCount = std.EnumArray(std.meta.Tag(lcz.Runtime.Instruction), u32);

fn preDecodeHook(
    runtime: *lcz.Runtime,
    word: u16,
) lcz.Runtime.IoError!void {
    try runtime.writer.ensureNewline();
    try runtime.writer.interface.print("\x1b[33mpre-decode {x:04}\x1b[0m\n", .{word});
}

fn preExecuteHook(
    runtime: *lcz.Runtime,
    instr: lcz.Runtime.Instruction,
    instr_count: *InstrCount,
) lcz.Runtime.IoError!void {
    instr_count.getPtr(instr).* += 1;

    try runtime.writer.ensureNewline();
    try runtime.writer.interface.print("\x1b[33mpre-execute {t}\x1b[0m\n", .{instr});
}
