const std = @import("std");
const Io = std.Io;

const lcz = @import("lcz");
const mcz = @import("mcz");

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

    var parser: lcz.Parser = .new(&air, .new(source, &reporter));

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
        var conn_write_buffer: [1024]u8 = undefined;
        var conn_read_buffer: [1024]u8 = undefined;

        var conn: mcz.Connection = try .new(&conn_write_buffer, &conn_read_buffer, io);

        var trap_table: lcz.Runtime.traps.Table = .default;
        trap_table.register(@enumFromInt(0x28), mcz_traps.chat, &conn);
        trap_table.register(@enumFromInt(0x29), mcz_traps.getp, &conn);

        var runtime_write_buffer: [64]u8 = undefined;
        var runtime_writer = Io.File.stdout().writer(io, &runtime_write_buffer);
        var runtime_reader = Io.File.stdin().reader(io, &.{});

        var runtime = try lcz.Runtime.init(
            &trap_table,
            &policies,
            &runtime_writer.interface,
            &runtime_reader.interface,
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
    }

    return 0;
}

const mcz_traps = struct {
    fn chat(runtime: *lcz.Runtime, data: *const anyopaque) lcz.Runtime.traps.Result {
        _ = .{ runtime, data };
        return error.TrapFailed;
    }

    fn getp(runtime: *lcz.Runtime, data: *const anyopaque) lcz.Runtime.traps.Result {
        const conn: *mcz.Connection = @ptrCast(@alignCast(@constCast(data)));

        const player = conn.getPlayerPosition() catch
            return error.TrapFailed;

        runtime.registers[0] = cast(player.x);
        runtime.registers[1] = cast(player.y);
        runtime.registers[2] = cast(player.z);
    }

    fn cast(value: i32) u16 {
        return @bitCast(@as(i16, @truncate(value)));
    }
};
