const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Policies = @import("../policies.zig").Policies;
const Span = @import("../compile/Span.zig");
const Source = @import("../compile/Source.zig");
const Token = @import("../compile/parse/Token.zig");

pub const Sink = @import("Sink.zig");

// TODO: Move or remove
pub const Primary = Reporter(@import("diagnostic.zig").Diagnostic);

pub const Level = enum(u2) {
    info = 1,
    warn = 2,
    err = 3,

    pub fn order(lhs: Level, rhs: Level) std.math.Order {
        return std.math.order(@intFromEnum(lhs), @intFromEnum(rhs));
    }
};

pub const Options = struct {
    policies: Policies = .none,
    strictness: Strictness = .default,
    verbosity: Verbosity = .default,

    pub const Strictness = enum {
        strict,
        normal,
        relaxed,
        pub const default: Strictness = .normal;
    };

    pub const Verbosity = enum {
        normal,
        quiet,
        pub const default: Verbosity = .normal;
    };
};

pub const Response = enum {
    /// Must be handled immediately.
    fatal,
    /// Must be handled in this pass.
    major,

    minor,
    info,
    pass,

    pub fn abort(response: Response) error{Reported}!noreturn {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .info, .pass => unreachable,
        };
    }
    pub fn collect(response: Response, result: *error{Reported}!void) void {
        return switch (response) {
            .fatal, .major => {
                result.* = error.Reported;
            },
            .minor, .info, .pass => {},
        };
    }
    pub fn handle(response: Response) error{Reported}!void {
        return switch (response) {
            .fatal, .major => error.Reported,
            .minor, .info, .pass => {},
        };
    }
    /// Callsites should document why `proceed` is used rather than `handle`.
    pub fn proceed(response: Response) void {
        switch (response) {
            .fatal => unreachable,
            .major, .minor, .info, .pass => {},
        }
    }
};

pub fn Reporter(comptime Diag: type) type {
    assert(@typeInfo(Diag).@"union".tag_type != null);

    return struct {
        const Self = @This();
        pub const Diagnostic = Diag;

        sink: Sink,
        count: std.EnumArray(Level, usize),
        options: Options,
        source: ?Source,

        pub fn new(sink: Sink) Self {
            return .{
                .sink = sink,
                .count = .initFill(0),
                .options = .{},
                .source = null,
            };
        }

        fn writeFailed() noreturn {
            std.debug.panic("failed to write to reporter", .{});
        }

        pub fn report(
            reporter: *Self,
            comptime tag: std.meta.Tag(Diag),
            info: @FieldType(Diag, @tagName(tag)),
        ) Response {
            return reporter.reportInner(@unionInit(Diag, @tagName(tag), info)) catch
                writeFailed();
        }

        fn reportInner(reporter: *Self, diag: Diag) error{WriteFailed}!Response {
            const response: Response = diag.getResponse(reporter.options);

            const level: Level = switch (response) {
                .fatal, .major => .err,
                .minor => .warn,
                .info => .info,
                .pass => return .pass,
            };

            reporter.count.getPtr(level).* += 1;

            try reporter.sink.sendDiagnostic(
                diag,
                level,
                reporter.options.verbosity,
                reporter.source orelse unreachable,
            );

            assert(response != .pass);
            return response;
        }

        pub fn summarize(reporter: *Self) void {
            reporter.sink.sendSummary(
                &reporter.count,
                reporter.options.verbosity,
            ) catch
                writeFailed();
        }

        pub fn getLevel(reporter: *const Self) ?Level {
            if (reporter.count.get(.err) > 0)
                return .err;
            if (reporter.count.get(.warn) > 0)
                return .warn;
            return null;
        }

        pub fn isLevelAtMost(reporter: *const Self, max: Level) bool {
            const level = reporter.getLevel() orelse
                return true;
            return level.order(max).compare(.lte);
        }
    };
}
