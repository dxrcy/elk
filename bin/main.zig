const std = @import("std");
const Io = std.Io;

const lcz = @import("lcz");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = lcz.Reporter.new(io);
    try reporter.init();

    const asm_path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, asm_path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    // reporter.options.strictness = .normal;
    // reporter.options.verbosity = .normal;

    const policies: lcz.Policies = .config_lace;
    reporter.options.policies = &policies;

    var air: lcz.Air = .init();
    defer air.deinit(gpa);

    const traps: lcz.Traps = comptime .initBuiltins(&.{
        lcz.Traps.Standard,
        lcz.Traps.Debug,
    });

    var parser: lcz.Parser = .new(&air, &traps, source, &reporter);

    try parser.parse(gpa);
    parser.resolveLabels();

    {
        if (reporter.endSection() == .err) {
            std.log.info("stop", .{});
            return 1;
        }
    }

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
        var write_buffer: [64]u8 = undefined;
        var writer = Io.File.stdout().writer(io, &write_buffer);
        var reader = Io.File.stdin().reader(io, &.{});

        var instr_count: InstrCount = .initFill(0);

        const hooks: lcz.Runtime.Hooks = .{
            .pre_execute = .{
                .func = preExecuteHook,
                .data = &instr_count,
            },
        };

        var runtime = try lcz.Runtime.init(
            &traps,
            hooks,
            &policies,
            &writer.interface,
            &reader.interface,
            io,
            gpa,
        );
        defer runtime.deinit(gpa);

        try air.emitRuntime(&runtime);

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

        for (std.meta.tags(std.meta.Tag(lcz.Runtime.Instruction))) |field| {
            const count = instr_count.get(field);
            std.debug.print("{t:20}: {}\n", .{ field, count });
        }
    }

    return 0;
}

const InstrCount = std.EnumArray(std.meta.Tag(lcz.Runtime.Instruction), u32);

fn preExecuteHook(
    runtime: *lcz.Runtime,
    instr: lcz.Runtime.Instruction,
    data: ?*const anyopaque,
) lcz.Runtime.IoError!void {
    const instr_count: *InstrCount = @ptrCast(@alignCast(@constCast(data.?)));

    instr_count.getPtr(instr).* += 1;

    try runtime.writer.ensureNewline();
    try runtime.writer.interface.print("\x1b[33mpre-execute {t}\x1b[0m\n", .{instr});
}
