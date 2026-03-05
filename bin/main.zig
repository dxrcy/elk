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
    // reporter.options.verbosity = .normal;

    const policies: lcz.Policies = .config_lace;
    reporter.options.policies = &policies;

    var fir: lcz.Fir = .init();
    defer fir.deinit(gpa);

    const traps: lcz.Traps = comptime .initBuiltins(&.{
        lcz.Traps.Standard,
        lcz.Traps.Debug,
    });

    var parser = lcz.Parser.new(&traps, source, &reporter) orelse
        return 1;

    try parser.parseFir(&fir, gpa);
    if (reporter.getLevel() == .err) {
        reporter.showSummary();
        return 1;
    }

    reporter.showSummary();

    for (fir.lines.items) |line| {
        std.debug.print("{}\n", .{line});
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
