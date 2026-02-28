pub const Policies = @import("Policies.zig");
pub const Reporter = @import("report/Reporter.zig");
pub const Air = @import("compile/Air.zig");
pub const Parser = @import("compile/parse/Parser.zig");
pub const Runtime = @import("emulate/Runtime.zig");

comptime {
    _ = &@import("Policies.zig");
    _ = &@import("compile/statement.zig");
    _ = &@import("compile/Span.zig");
    _ = &@import("compile/Air.zig");
    _ = &@import("compile/parse/TokenIter.zig");
    _ = &@import("compile/parse/Lexer.zig");
    _ = &@import("compile/parse/Parser.zig");
    _ = &@import("compile/parse/integers.zig");
    _ = &@import("compile/parse/Token.zig");
    _ = &@import("report/Reporter.zig");
    _ = &@import("report/Ctx.zig");
    _ = &@import("report/diagnostic.zig");
    _ = &@import("emulate/traps.zig");
    _ = &@import("emulate/Tty.zig");
    _ = &@import("emulate/NewlineTracker.zig");
    _ = &@import("emulate/Mask.zig");
    _ = &@import("emulate/Runtime.zig");
}
