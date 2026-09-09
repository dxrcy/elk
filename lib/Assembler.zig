const Assembler = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const elk = @import("root.zig");

air: elk.Air,
source: elk.Source,
traps: *const elk.Traps,
patch_symbols: ?[]const struct { []const u8, u16 },
reporter: *elk.reporting.Primary,
gpa: Allocator,
io: Io,

/// Idempotent.
pub fn deinit(assembler: *Assembler) void {
    if (assembler.source.text.len > 0) {
        assembler.gpa.free(assembler.source.text);
        assembler.source.text.len = 0;
    }
    assembler.air.deinit(assembler.gpa);
}

pub fn assembleFromFile(assembler: *Assembler) !void {
    assembler.deinit();

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
            return error.Reported;
        }

        parser.resolveLabelReferences(&assembler.air);
        if (assembler.reporter.getLevel() == .err) {
            assembler.reporter.summarize();
            return error.Reported;
        }
    }
    assembler.reporter.summarize();

    if (assembler.patch_symbols) |patch_symbols| {
        for (patch_symbols) |item| {
            const symbol, const word = item;
            try assembler.air.patchLabelValue(symbol, word, assembler.source);
        }
    }
}
