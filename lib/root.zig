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
