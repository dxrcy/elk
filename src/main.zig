const std = @import("std");
const Io = std.Io;

const Air = @import("Air.zig");
const Parser = @import("Parser.zig");
const Runtime = @import("Runtime.zig");
const Reporter = @import("Reporter.zig");

pub fn main(init: std.process.Init) !u8 {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const asm_path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, asm_path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);
    reporter.options.strictness = .normal;
    reporter.options.verbosity = .normal;

    var air: Air = .init();
    defer air.deinit(gpa);

    var parser: Parser = .new(&air, source, &reporter, gpa);

    try parser.parse();

    parser.resolveLabels();

    {
        if (reporter.endSection() == .err) {
            std.log.info("stop", .{});
            return 1;
        }
    }

    {
        const runtime = try Runtime.init(gpa);
        defer runtime.deinit(gpa);

        try air.emitMemory(runtime.memory);

        for (runtime.memory[air.origin..][0..20]) |raw| {
            std.debug.print("0x{x:04}\n", .{raw});
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

    return 0;
}

comptime {
    std.testing.refAllDecls(@This());
}
