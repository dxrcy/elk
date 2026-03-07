pub const Policies = @import("Policies.zig");
pub const Traps = @import("Traps.zig");
pub const Reporter = @import("report/Reporter.zig");
pub const Air = @import("compile/Air.zig");
pub const Parser = @import("compile/parse/Parser.zig");
pub const Runtime = @import("emulate/Runtime.zig");

test {
    const refAllDecls = @import("std").testing.refAllDecls;
    refAllDecls(@import("Policies.zig"));
    refAllDecls(@import("compile/Operand.zig"));
    refAllDecls(@import("compile/Span.zig"));
    refAllDecls(@import("compile/instruction.zig"));
    refAllDecls(@import("compile/Air.zig"));
    refAllDecls(@import("compile/parse/case.zig"));
    refAllDecls(@import("compile/parse/TokenIter.zig"));
    refAllDecls(@import("compile/parse/Lexer.zig"));
    refAllDecls(@import("compile/parse/Parser.zig"));
    refAllDecls(@import("compile/parse/integers.zig"));
    refAllDecls(@import("compile/parse/Token.zig"));
    refAllDecls(@import("callback.zig"));
    refAllDecls(@import("report/Reporter.zig"));
    refAllDecls(@import("report/Discarding.zig"));
    refAllDecls(@import("report/Ctx.zig"));
    refAllDecls(@import("report/Stderr.zig"));
    refAllDecls(@import("report/diagnostic.zig"));
    refAllDecls(@import("Traps.zig"));
    refAllDecls(@import("emulate/decode.zig"));
    refAllDecls(@import("emulate/Tty.zig"));
    refAllDecls(@import("emulate/builtin_traps.zig"));
    refAllDecls(@import("emulate/NewlineTracker.zig"));
    refAllDecls(@import("emulate/Bitmask.zig"));
    refAllDecls(@import("emulate/Runtime.zig"));
}
