const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
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
    };

    var parser: Parser = .{
        .air = &air,
        .tokens = Tokenizer.new(source),
        .source = source,
        .reporter = &reporter,
    };

    defer {
        air.lines.deinit(air.allocator);
    }

    try parser.parse();

    std.debug.print("\n", .{});
    for (air.lines.items) |line| {
        std.debug.print("{f}", .{line.statement});
        std.debug.print("[{s}]\n", .{line.span.resolve(source)});
        std.debug.print("\n", .{});
    }
}

const ArrayList = std.ArrayList;

const Air = struct {
    lines: ArrayList(Line),
    allocator: Allocator,

    pub const Line = struct {
        statement: Statement,
        span: Span,

        pub const Statement = union(enum) {
            raw_word: u16,

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
                vect: TrapVect,
            },

            pub const Register = u3;

            // TODO: Rename
            pub const RegisterOrImmediate = union(enum) {
                register: Register,
                immediate: u5,
            };

            // TODO:
            const Label = []const u8;

            const TrapVect = u8;

            pub fn format(statement: Statement, writer: *Io.Writer) !void {
                inline for (@typeInfo(Statement).@"union".fields) |tag| {
                    if (std.mem.eql(u8, @tagName(statement), tag.name)) {
                        switch (@typeInfo(tag.type)) {
                            .@"struct" => |info| {
                                for (tag.name) |char| {
                                    std.debug.print("{c}", .{std.ascii.toUpper(char)});
                                }
                                std.debug.print(":\n", .{});

                                inline for (info.fields) |field| {
                                    std.debug.print("{s:8} = ", .{field.name});
                                    const value = @field(@field(statement, tag.name), field.name);
                                    switch (field.type) {
                                        Register => try writer.print("Register: r{}", .{value}),
                                        Label => try writer.print("Label: [{s}]", .{value}),
                                        RegisterOrImmediate => {
                                            try writer.print("Register/Immediate: ", .{});
                                            switch (value) {
                                                .register => |register| try writer.print("r{}", .{register}),
                                                .immediate => |immediate| try writer.print("0x{x:02}", .{immediate}),
                                            }
                                        },
                                        TrapVect => try writer.print("VECT", .{}),
                                        else => comptime unreachable,
                                    }
                                    std.debug.print("\n", .{});
                                }
                            },

                            else => {
                                // TODO:
                            },
                        }
                    }
                }
            }
        };
    };
};

const assert = std.debug.assert;

const Parser = struct {
    air: *Air,
    tokens: Tokenizer,
    source: []const u8,
    reporter: *Reporter,

    const Statement = Air.Line.Statement;

    pub fn parse(parser: *Parser) !void {
        while (true) {
            const token = try convertReported(parser.nextToken()) orelse {
                parser.discardTokensInLine();
                continue;
            } orelse
                break;

            switch (token.kind) {
                .newline, .comma => continue,
                else => {},
            }

            std.debug.print("{t:12} {s}\n", .{
                token.kind,
                if (token.kind == .newline)
                    ""
                else
                    token.span.resolve(parser.source),
            });

            switch (token.kind) {
                .instruction => |instruction| {
                    const statement = try parser.parseInstruction(instruction) orelse
                        continue;

                    const span: Span = .fromBounds(
                        token.span.offset,
                        parser.tokens.index,
                    );

                    try parser.air.lines.append(parser.air.allocator, .{
                        .statement = statement,
                        .span = span,
                    });
                },

                // TODO:
                else => {},
            }
        }
    }

    // TODO: Don't return `null` once all instructions implemented
    fn parseInstruction(
        parser: *Parser,
        instruction: Token.Kind.Instruction,
    ) !?Statement {
        const RegularInstruction = enum {
            add,
            lea,
        };

        inline for (@typeInfo(RegularInstruction).@"enum".fields) |regular| {
            if (std.mem.eql(u8, @tagName(instruction), regular.name)) {
                const Payload = @FieldType(Statement, regular.name);
                var payload: Payload = undefined;

                inline for (@typeInfo(Payload).@"struct".fields) |field| {
                    const kind = switch (field.type) {
                        Statement.Register => .register,
                        Statement.Label => .label,
                        Statement.RegisterOrImmediate => .register_or_immediate,
                        else => comptime unreachable,
                    };

                    const value = try parser.expectTokenKind(kind);
                    @field(payload, field.name) = value;
                }

                return @unionInit(Statement, regular.name, payload);
            }
        }

        // TODO:
        return null;
    }

    fn nextToken(parser: *Parser) error{Reported}!?Token {
        while (true) {
            const span = parser.tokens.next() orelse
                return null;
            const token = Token.from(span, parser.source) catch |err| {
                parser.reporter.err(err, span);
                return error.Reported;
            };
            switch (token.kind) {
                .comma => continue,
                else => return token,
            }
        }
    }

    fn expectToken(parser: *Parser) !Token {
        const token = try parser.nextToken() orelse {
            parser.reporter.err(error.UnexpectedEof, .dummy);
            return error.Reported;
        };
        switch (token.kind) {
            .newline => {
                parser.reporter.err(error.UnexpectedEol, .dummy);
                return error.Reported;
            },
            .comma => unreachable,
            else => return token,
        }
    }

    fn expectTokenKind(
        parser: *Parser,
        comptime kind: @EnumLiteral(),
    ) !ExpectTokenKind(kind) {
        const token = try parser.expectToken();
        assert(token.kind != .comma);
        const value: ?ExpectTokenKind(kind) = switch (kind) {
            .register => switch (token.kind) {
                .register => |register| register,
                else => null,
            },
            .label => switch (token.kind) {
                .label => |label| label,
                else => null,
            },
            .register_or_immediate => switch (token.kind) {
                .register => |register| .{ .register = register },
                // FIXME: Handle u16->u5 conversion fail
                // Token.integer needs to remember ORIGINAL SOURCE sign to
                // handle/avoid sign extension triggering conversion failure
                .integer => |integer| .{ .immediate = @intCast(integer) },
                else => null,
            },
            else => comptime unreachable,
        };
        return value orelse {
            parser.reporter.err(error.UnexpectedTokenKind, .dummy);
            return error.Reported;
        };
    }

    fn ExpectTokenKind(comptime kind: @EnumLiteral()) type {
        return switch (kind) {
            .register => Statement.Register,
            .label => Statement.Label,
            .register_or_immediate => Statement.RegisterOrImmediate,
            else => comptime unreachable,
        };
    }

    // TODO: Rename
    fn discardTokensInLine(parser: *Parser) void {
        while (true) {
            const token = try convertReported(parser.nextToken()) orelse {
                continue; // Ignore
            } orelse
                break;
            if (token.kind == .newline)
                break;
        }
    }
};

// TODO: Rename
fn convertReported(result: anytype) !?@typeInfo(@TypeOf(result)).error_union.payload {
    const error_union = @typeInfo(@TypeOf(result)).error_union;
    const error_set = @typeInfo(error_union.error_set).error_set.?;

    if (error_set.len < 2) {
        return result catch |err| switch (err) {
            error.Reported => return null,
        };
    } else {
        return result catch |err| switch (err) {
            error.Reported => return,
            else => return null,
        };
    }
}

comptime {
    std.testing.refAllDecls(@This());
}
