const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const LineIterator = Tokenizer.LineIterator;
const Token = @import("Token.zig");
const Span = @import("Span.zig");
const Reporter = @import("Reporter.zig");

pub fn main(init: std.process.Init) !void {
    const io, const gpa = .{ init.io, init.gpa };

    var reporter = Reporter.new(io);
    try reporter.init();

    const path = "hw.asm";

    const source = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(source);

    reporter.setSource(source);

    var air: Air = .{
        .lines = .empty,
        .allocator = gpa,
        .source = source,
    };

    defer {
        air.lines.deinit(air.allocator);
    }

    var lines: LineIterator = .new(source);
    while (lines.next()) |line| {
        try air.parseLine(line, &reporter);
    }
}

const ArrayList = std.ArrayList;

const Air = struct {
    lines: ArrayList(Line),
    allocator: Allocator,
    source: []const u8,

    pub const Line = struct {
        statement: Statement,
        span: Span,

        pub const Statement = union(enum) {
            add: struct {
                dest: Register,
                src_a: Register,
                src_b: RegisterOrImmediate,
            },

            lea: struct {
                dest: Register,
                src: Label,
            },

            trap: struct {
                vect: u8,
            },

            pub const Register = u3;

            pub const RegisterOrImmediate = union(enum) {
                register: Register,
                immediate: u5,
            };

            // TODO:
            const Label = []const u8;
        };
    };

    pub fn parseLine(air: *Air, line: Span, reporter: *Reporter) !void {
        const line_str = line.resolve(air.source);

        std.debug.print("-" ** 20 ++ "\n", .{});
        std.debug.print("[{s}]\n", .{line_str});

        var tokens = Tokenizer.new(line_str);

        const first = tokens.next() orelse
            unreachable;

        std.debug.print("{s}\n", .{first.resolve(line_str)});

        _ = reporter;
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
