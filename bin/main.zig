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

    const MczTraps = enum(u8) {
        chat = 0x28,
        getp = 0x29,
        setp = 0x2a,
        getb = 0x2b,
        setb = 0x2c,
        geth = 0x2d,
    };

    var traps: lcz.Traps = comptime .initBuiltins(&.{
        lcz.Traps.Standard,
        lcz.Traps.Debug,
    });

    inline for (@typeInfo(MczTraps).@"enum".fields) |field| {
        traps.register(field.value, .{
            .alias = field.name,
            .procedure = lcz.Traps.castedDataParam(
                *mcz.Connection,
                @field(mcz_traps, field.name),
            ),
            .data = null,
        });
    }

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
        var conn_write_buffer: [1024]u8 = undefined;
        var conn_read_buffer: [1024]u8 = undefined;

        var conn: mcz.Connection = try .new(&conn_write_buffer, &conn_read_buffer, io);

        inline for (@typeInfo(MczTraps).@"enum".fields) |field| {
            traps.setData(field.value, &conn);
        }

        var runtime_write_buffer: [64]u8 = undefined;
        var runtime_writer = Io.File.stdout().writer(io, &runtime_write_buffer);
        var runtime_reader = Io.File.stdin().reader(io, &.{});

        var runtime = try lcz.Runtime.init(
            &traps,
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
    fn chat(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        _ = .{ runtime, conn };
        return error.TrapFailed;
    }

    fn getp(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        const player = conn.getPlayerPosition() catch
            return error.TrapFailed;

        runtime.registers[0] = toWord(player.x);
        runtime.registers[1] = toWord(player.y);
        runtime.registers[2] = toWord(player.z);
    }

    fn setp(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        const player: mcz.Coordinate = .{
            .x = fromWord(runtime.registers[0]),
            .y = fromWord(runtime.registers[1]),
            .z = fromWord(runtime.registers[2]),
        };

        conn.setPlayerPosition(player) catch
            return error.TrapFailed;
    }

    fn getb(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        const coordinate: mcz.Coordinate = .{
            .x = fromWord(runtime.registers[0]),
            .y = fromWord(runtime.registers[1]),
            .z = fromWord(runtime.registers[2]),
        };

        const block = conn.getBlock(coordinate) catch
            return error.TrapFailed;

        runtime.registers[3] = @truncate(block.id);
    }

    fn setb(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        const coordinate: mcz.Coordinate = .{
            .x = fromWord(runtime.registers[0]),
            .y = fromWord(runtime.registers[1]),
            .z = fromWord(runtime.registers[2]),
        };

        const block: mcz.Block = .{
            .id = runtime.registers[3],
            .mod = 0,
        };

        conn.setBlock(coordinate, block) catch
            return error.TrapFailed;
    }

    fn geth(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        const coordinate: mcz.Coordinate2D = .{
            .x = fromWord(runtime.registers[0]),
            .z = fromWord(runtime.registers[2]),
        };

        const height = conn.getHeight(coordinate) catch
            return error.TrapFailed;

        runtime.registers[1] = toWord(height);
    }

    fn toWord(value: i32) u16 {
        return @bitCast(@as(i16, @truncate(value)));
    }
    fn fromWord(value: u16) i32 {
        return @as(i16, @bitCast(value));
    }
};
