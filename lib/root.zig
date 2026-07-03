pub const Air = @import("compile/Air.zig");
pub const Source = @import("compile/Source.zig");
pub const Parser = @import("compile/parse/Parser.zig");
pub const Runtime = @import("emulate/Runtime.zig");
pub const Debugger = @import("emulate/debugger/Debugger.zig");
pub const Traps = @import("Traps.zig");
pub const Provider = @import("provider.zig").Provider;
pub const Policies = @import("policies.zig").Policies;
pub const reporting = @import("reporting/reporting.zig");

// TODO: Move to another file
pub const Assembler = struct {
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

        const file = try Io.Dir.cwd().openFile(assembler.io, assembler.source.path orelse
            unreachable, .{});
        var reader = file.reader(assembler.io, &.{});
        assembler.source.text = try reader.interface.allocRemaining(assembler.gpa, .unlimited);
        file.close(assembler.io);

        assembler.reporter.source = assembler.source;

        try assemble(
            assembler.gpa,
            &assembler.air,
            assembler.source,
            // TODO:
            // operation.patch_symbols,
            null,
            assembler.traps,
            assembler.reporter,
        );
    }

    fn assemble(
        gpa: Allocator,
        air: *Air,
        source: elk.Source,
        patch_symbols_opt: ?[]const struct { []const u8, u16 },
        traps: *const elk.Traps,
        reporter: *elk.reporting.Primary,
    ) !void {
        reporter.clear();

        air.* = .init();
        errdefer air.deinit(gpa);

        var parser = try elk.Parser.new(traps, source, reporter);

        try parser.parseAir(gpa, air);
        if (reporter.getLevel() == .err) {
            reporter.summarize();
            return error.AssembleFailed;
        }

        parser.resolveLabelReferences(air);
        if (reporter.getLevel() == .err) {
            reporter.summarize();
            return error.AssembleFailed;
        }

        reporter.summarize();

        if (patch_symbols_opt) |patch_symbols| {
            for (patch_symbols) |item| {
                const symbol, const word = item;
                try air.patchLabelValue(symbol, word, source);
            }
        }
    }
};

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("reporting/Sink.zig"));
    refAllDecls(@import("reporting/reporting.zig"));
    refAllDecls(@import("reporting/Ctx.zig"));
    refAllDecls(@import("reporting/FancySink.zig"));
    refAllDecls(@import("reporting/diagnostic.zig"));
    refAllDecls(@import("root.zig"));
    refAllDecls(@import("compile/Operand.zig"));
    refAllDecls(@import("compile/Span.zig"));
    refAllDecls(@import("compile/Source.zig"));
    refAllDecls(@import("compile/instruction.zig"));
    refAllDecls(@import("compile/Air.zig"));
    refAllDecls(@import("compile/parse/parsing.zig"));
    refAllDecls(@import("compile/parse/case.zig"));
    refAllDecls(@import("compile/parse/Lexer.zig"));
    refAllDecls(@import("compile/parse/Parser.zig"));
    refAllDecls(@import("compile/parse/integers.zig"));
    refAllDecls(@import("compile/parse/Token.zig"));
    refAllDecls(@import("compile/parse/Tokenizer.zig"));
    refAllDecls(@import("callback.zig"));
    refAllDecls(@import("policies.zig"));
    refAllDecls(@import("Traps.zig"));
    refAllDecls(@import("emulate/decode.zig"));
    refAllDecls(@import("emulate/Tty.zig"));
    refAllDecls(@import("emulate/builtin_traps.zig"));
    refAllDecls(@import("emulate/Bitmask.zig"));
    refAllDecls(@import("emulate/debugger/Command.zig"));
    refAllDecls(@import("emulate/debugger/Breakpoints.zig"));
    refAllDecls(@import("emulate/debugger/editor/Editor.zig"));
    refAllDecls(@import("emulate/debugger/editor/History.zig"));
    refAllDecls(@import("emulate/debugger/editor/Live.zig"));
    refAllDecls(@import("emulate/debugger/tags.zig"));
    refAllDecls(@import("emulate/debugger/Input.zig"));
    refAllDecls(@import("emulate/debugger/Debugger.zig"));
    refAllDecls(@import("emulate/debugger/parse.zig"));
    refAllDecls(@import("emulate/Runtime.zig"));
}
