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
            .callback = .withDataDeferInit(
                *mcz.Connection,
                @field(mcz_traps, field.name),
            ),
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
            traps.initData(field.value, *mcz.Connection, &conn);
        }

        var runtime_write_buffer: [64]u8 = undefined;
        var runtime_writer = Io.File.stdout().writer(io, &runtime_write_buffer);
        var runtime_reader = Io.File.stdin().reader(io, &.{});

        var instr_count: InstrCount = .initFill(0);

        const hooks: lcz.Runtime.Hooks = .{
            .pre_decode = .withoutData(preDecodeHook),
            .pre_execute = .withDataInit(*InstrCount, preExecuteHook, &instr_count),
        };

        var runtime = try lcz.Runtime.init(
            &traps,
            hooks,
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

        for (runtime.registers, 0..) |register, i| {
            std.debug.print("r{}: 0x{x:04}\n", .{ i, register });
        }

        for (std.meta.tags(std.meta.Tag(lcz.Runtime.Instruction))) |field| {
            const count = instr_count.get(field);
            std.debug.print("{t:20}: {}\n", .{ field, count });
        }
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

const mcz_traps = struct {
    fn chat(runtime: *lcz.Runtime, conn: *mcz.Connection) lcz.Traps.Result {
        const memory_str: MemoryStr = .{
            .runtime = runtime,
            .start = runtime.registers[0],
        };
        conn.postToChatFmt("{f}", .{memory_str}) catch
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

    const MemoryStr = struct {
        runtime: *const lcz.Runtime,
        start: u16,

        pub fn format(memory_str: *const MemoryStr, writer: *Io.Writer) Io.Writer.Error!void {
            for (memory_str.runtime.memory[memory_str.start..]) |word| {
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
