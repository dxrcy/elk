const Assembler = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const elk = @import("root.zig");

air: elk.Air,
source: elk.Source,
traps: *const elk.Traps,
reporter: *elk.reporting.Primary,
gpa: Allocator,
io: Io,

pub fn deinit(assembler: *Assembler) void {
    assembler.gpa.free(assembler.source.text);
    assembler.air.deinit(assembler.gpa);
}

pub fn assembleFromFile(assembler: *Assembler) !void {
    assembler.gpa.free(assembler.source.text);
    assembler.air.deinit(assembler.gpa);

    {
        const file = if (assembler.source.path) |path|
            try Io.Dir.cwd().openFile(assembler.io, path, .{})
        else
            Io.File.stdin();
        defer if (assembler.source.path) |_|
            file.close(assembler.io);

        var reader = file.reader(assembler.io, &.{});
        assembler.source.text = try reader.interface.allocRemaining(assembler.gpa, .unlimited);
    }

    assembler.air = .init();
    errdefer assembler.air.deinit(assembler.gpa);

    assembler.reporter.source = assembler.source;
    assembler.reporter.clear();
    {
        var parser = try elk.Parser.new(assembler.traps, assembler.source, assembler.reporter);

        try parser.parseAir(assembler.gpa, &assembler.air);
        if (assembler.reporter.getLevel() == .err) {
            assembler.reporter.summarize();
            return error.AssembleFailed;
        }

        parser.resolveLabelReferences(&assembler.air);
        if (assembler.reporter.getLevel() == .err) {
            assembler.reporter.summarize();
            return error.AssembleFailed;
        }
    }
    assembler.reporter.summarize();

    // if (patch_symbols_opt) |patch_symbols| {
    //     for (patch_symbols) |item| {
    //         const symbol, const word = item;
    //         try air.patchLabelValue(symbol, word, source);
    //     }
    // }
}
