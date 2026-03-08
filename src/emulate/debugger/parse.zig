const std = @import("std");

const Reporter = @import("../../report/Reporter.zig");
const Span = @import("../../compile/Span.zig");
const Lexer = @import("../../compile/parse/Lexer.zig");
const integers = @import("../../compile/parse/integers.zig");
const Command = @import("command.zig").Command;
const tags = @import("tags.zig");

pub fn parseCommand(
    string: []const u8,
    reporter: *Reporter,
) error{ Reported, Unimplemented }!?Command {
    var lexer = Lexer.new(string, false);

    const tag = try parseCommandTag(&lexer, string, reporter) orelse
        return null;

    std.debug.print("{t}\n", .{tag});

    var parser: Parser = .{
        .lexer = &lexer,
        .source = string,
        .reporter = reporter,
    };

    const command: Command = command: switch (tag) {
        // Allow trailing arguments
        .help => return .help,

        inline .@"continue",
        .registers,
        .reset,
        .quit,
        .exit,
        .step_over,
        .step_out,
        .break_list,
        => |void_tag| @unionInit(Command, @tagName(void_tag), {}),

        .step_into => {
            const count = @max(1, try parser.nextOptionalUint() orelse 0);
            break :command .{ .step_into = .{ .count = count } };
        },

        // TODO:

        else => {
            return error.Unimplemented;
        },
    };

    if (lexer.next()) |span| {
        try reporter.report(.debugger_any_err, .{
            .code = error.UnexpectedArgument,
            .span = span,
        }).abort();
    }

    return command;
}

const Parser = struct {
    lexer: *Lexer,
    source: []const u8,
    reporter: *Reporter,

    fn next(parser: *Parser) error{Reported}!Span {
        return parser.lexer.next() orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.ExpectedArgument,
                .span = .emptyAt(parser.source.len),
            }).abort();
        };
    }

    fn nextOptionalUint(parser: *Parser) error{Reported}!?u16 {
        const argument = parser.lexer.next() orelse
            return null;

        const integer = integers.tryInteger(argument.view(parser.source)) catch |err| {
            try parser.reporter.report(.debugger_any_err, .{
                .code = err,
                .span = argument,
            }).abort();
        } orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.InvalidArgumentKind,
                .span = argument,
            }).abort();
        };

        return integer.castToUnsigned() orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.IntegerToolarge,
                .span = argument,
            }).abort();
        };
    }
};

fn parseCommandTag(
    lexer: *Lexer,
    source: []const u8,
    reporter: *Reporter,
) error{Reported}!?Command.Tag {
    const first = lexer.next() orelse
        return null;

    for (tags.double) |double| {
        if (try findDoubleTagMatch(double, first, lexer, source, reporter)) |tag|
            return tag;
    }

    return findSingleTagMatch(&tags.single, first, source, reporter) orelse {
        try reporter.report(.debugger_any_err, .{
            .code = error.InvalidCommand,
            .span = first,
        }).abort();
    };
}

fn findDoubleTagMatch(
    double: tags.DoubleEntry,
    first: Span,
    lexer: *Lexer,
    source: []const u8,
    reporter: *Reporter,
) error{Reported}!?Command.Tag {
    if (!anyCandidateMatches(double.first, first.view(source)))
        return null;

    const second = lexer.next() orelse
        return double.default orelse {
            try reporter.report(.debugger_any_err, .{
                .code = error.MissingSubcommand,
                .span = .emptyAt(source.len),
            }).abort();
        };

    return findSingleTagMatch(&double.second, second, source, reporter) orelse {
        try reporter.report(.debugger_any_err, .{
            .code = error.InvalidSubcommand,
            .span = second,
        }).abort();
    };
}

fn findSingleTagMatch(
    singles: *const tags.SingleMap,
    span: Span,
    source: []const u8,
    reporter: *Reporter,
) ?Command.Tag {
    const string = span.view(source);

    for (std.meta.tags(Command.Tag)) |tag| {
        if (anyCandidateMatches(singles.get(tag).aliases, string))
            return tag;
    }

    for (std.meta.tags(Command.Tag)) |tag| {
        if (anyCandidateMatches(singles.get(tag).suggestions, string)) {
            reporter.report(.debugger_any_warn, .{
                .code = error.CommandSuggestion,
                .span = span,
            }).proceed();
            return null;
        }
    }
    return null;
}

fn anyCandidateMatches(candidates: []const []const u8, string: []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(string, candidate))
            return true;
    }
    return false;
}
