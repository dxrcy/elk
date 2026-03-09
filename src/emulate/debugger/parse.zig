const std = @import("std");

const Reporter = @import("../../report/Reporter.zig");
const Span = @import("../../compile/Span.zig");
const Lexer = @import("../../compile/parse/Lexer.zig");
const parsing = @import("../../compile/parse/parsing.zig");
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

        .print => {
            const location = try parser.nextLocation();
            break :command .{ .print = .{ .location = location } };
        },

        .step_into => {
            const count = try parser.nextOptionalPositiveInt();
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

    fn nextOptionalPositiveInt(parser: *Parser) error{Reported}!u16 {
        const argument = parser.lexer.next() orelse
            return 1;

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

        if (integer.underlying == 0) {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.ArgumentTooSmall,
                .span = argument,
            }).abort();
        }

        return integer.castToUnsigned() orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.IntegerToolarge,
                .span = argument,
            }).abort();
        };
    }

    fn nextLocation(parser: *Parser) error{Reported}!Command.Location {
        const argument = try parser.next();
        const string = argument.view(parser.source);

        if (parsing.tryRegister(string)) |register|
            return .{ .register = register };

        if (try parser.parseMemoryLocation(argument)) |memory|
            return .{ .memory = memory };

        try parser.reporter.report(.debugger_any_err, .{
            .code = error.invalidargumentkind,
            .span = argument,
        }).abort();
    }

    fn parseMemoryLocation(
        parser: *Parser,
        argument: Span,
    ) error{Reported}!?Command.Location.Memory {
        // TODO: Implement pc offsets
        // TODO: Implement absolute address

        if (try parser.parseLabel(argument)) |label|
            return .{ .label = label };
        return null;
    }

    fn parseLabel(parser: *Parser, argument: Span) error{Reported}!?Command.Label {
        const string = argument.view(parser.source);

        const label_string, const offset_string_opt =
            if (std.mem.findAny(u8, string, "+-")) |sign_index| .{
                string[0..sign_index],
                string[sign_index + 1 ..],
            } else .{
                string, null,
            };

        const label: Span = .{ .offset = argument.offset, .len = label_string.len };

        const is_label = parsing.isLabel(label_string) catch |err| switch (err) {
            error.InvalidLabel => {
                try parser.reporter.report(.debugger_any_err, .{
                    .code = error.InvalidLabel,
                    .span = argument,
                }).abort();
            },
        };

        if (!is_label) {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.InvalidArgumentKind,
                .span = argument,
            }).abort();
        }

        // TODO: Implement label offsets
        if (offset_string_opt) |offset_string| {
            const offset: Span = .{ // Include sign character
                .offset = argument.offset + label_string.len,
                .len = offset_string.len + 1,
            };
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.UnimplementedLabelOffset,
                .span = offset,
            }).abort();
        }

        return .{
            .name = label,
            .offset = 0,
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
