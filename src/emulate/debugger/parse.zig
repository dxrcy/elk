const std = @import("std");
const assert = std.debug.assert;

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

    const command: Command = switch (tag) {
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

        .print => .{ .print = .{
            .location = try parser.nextLocation(),
        } },

        .move => .{ .move = .{
            .location = try parser.nextLocation(),
            .value = try parser.nextInteger(),
        } },

        .goto => .{ .goto = .{
            .location = try parser.nextMemoryLocation(),
        } },

        .step_into => .{ .step_into = .{
            .count = try parser.nextOptionalPositiveInt(),
        } },

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

    // TODO: Ignore commas
    fn next(parser: *Parser) error{Reported}!Span {
        return parser.lexer.next() orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.ExpectedArgument,
                .span = .emptyAt(parser.source.len),
            }).abort();
        };
    }

    fn nextInteger(parser: *Parser) error{Reported}!u16 {
        const argument = try parser.next();
        const integer = try parser.parseInteger(argument);
        return integer.underlying;
    }

    fn nextOptionalPositiveInt(parser: *Parser) error{Reported}!u16 {
        const argument = parser.lexer.next() orelse
            return 1;

        const integer = try parser.parseInteger(argument);

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

        if (parsing.tryRegister(argument.view(parser.source))) |register|
            return .{ .register = register };

        if (try parser.parseMemoryLocation(argument)) |memory|
            return .{ .memory = memory };

        try parser.reporter.report(.debugger_any_err, .{
            .code = error.InvalidArgumentKind,
            .span = argument,
        }).abort();
    }

    fn nextMemoryLocation(parser: *Parser) error{Reported}!Command.Location.Memory {
        const argument = try parser.next();

        if (try parser.parseMemoryLocation(argument)) |memory|
            return memory;

        try parser.reporter.report(.debugger_any_err, .{
            .code = error.InvalidArgumentKind,
            .span = argument,
        }).abort();
    }

    fn parseInteger(parser: *Parser, argument: Span) error{Reported}!integers.SourceInt(16) {
        return try parser.tryParseInteger(argument) orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.InvalidArgumentKind,
                .span = argument,
            }).abort();
        };
    }

    fn tryParseInteger(parser: *Parser, argument: Span) error{Reported}!?integers.SourceInt(16) {
        return integers.tryInteger(argument.view(parser.source)) catch |err| {
            try parser.reporter.report(.debugger_any_err, .{
                .code = err,
                .span = argument,
            }).abort();
        };
    }

    fn parseMemoryLocation(
        parser: *Parser,
        argument: Span,
    ) error{Reported}!?Command.Location.Memory {
        if (try parser.parsePcOffset(argument)) |pc_offset|
            return .{ .pc_offset = pc_offset };
        if (try parser.parseAddress(argument)) |address|
            return .{ .address = address };
        if (try parser.parseLabel(argument)) |label|
            return .{ .label = label };
        return null;
    }

    fn parsePcOffset(parser: *Parser, argument: Span) error{Reported}!?i16 {
        assert(argument.len > 0);

        if (argument.view(parser.source)[0] != '^')
            return null;

        const integer_span: Span = .{ .offset = argument.offset + 1, .len = argument.len - 1 };

        const integer = try parser.tryParseInteger(integer_span) orelse
            return 0;

        return integer.castToSmaller(i16) catch {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.IntegerToolarge,
                .span = argument,
            }).abort();
        };
    }

    fn parseAddress(parser: *Parser, argument: Span) error{Reported}!?u16 {
        const integer = try parser.tryParseInteger(argument) orelse
            return null;

        return integer.castToUnsigned() orelse {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.IntegerToolarge,
                .span = argument,
            }).abort();
        };
    }

    fn parseLabel(parser: *Parser, argument: Span) error{Reported}!?Command.Label {
        const string = argument.view(parser.source);

        const label_string, const offset_string_opt =
            if (std.mem.findAny(u8, string, "+-")) |sign_index| .{
                string[0..sign_index],
                string[sign_index..], // Include sign character
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

        const offset_string = offset_string_opt orelse
            return .{ .name = label, .offset = 0 };

        const offset_span: Span = .{ // Include sign character
            .offset = argument.offset + label_string.len,
            .len = offset_string.len + 1,
        };

        const integer = try parser.parseInteger(offset_span);

        assert(integer.form.sign.?.position == .pre_radix);

        const offset = integer.castToSmaller(i16) catch {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.IntegerToolarge,
                .span = argument,
            }).abort();
        };

        return .{ .name = label, .offset = offset };
    }
};

// TODO: Move below to `Parser` ?

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

    if (findSingleTagMatch(.exact, &tags.single, first, source)) |tag|
        return tag;

    const result = reporter.report(.debugger_any_err, .{
        .code = error.InvalidCommand,
        .span = first,
    }).abort();

    if (findSingleTagMatch(.nearest, &tags.single, first, source)) |tag| {
        _ = tag;
        reporter.report(.debugger_any_warn, .{
            .code = error.CommandSuggestion,
            .span = first,
        }).proceed();
    }

    try result;
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

    if (findSingleTagMatch(.exact, &double.second, second, source)) |tag|
        return tag;

    const result = reporter.report(.debugger_any_err, .{
        .code = error.InvalidSubcommand,
        .span = second,
    }).abort();

    if (findSingleTagMatch(.nearest, &double.second, second, source)) |tag| {
        _ = tag;
        reporter.report(.debugger_any_warn, .{
            .code = error.CommandSuggestion,
            .span = second,
        }).proceed();
    }

    try result;
}

fn findSingleTagMatch(
    comptime mode: enum { exact, nearest },
    singles: *const tags.SingleMap,
    span: Span,
    source: []const u8,
) ?Command.Tag {
    const string = span.view(source);

    switch (mode) {
        .exact => {
            for (std.meta.tags(Command.Tag)) |tag| {
                if (anyCandidateMatches(singles.get(tag).aliases, string))
                    return tag;
            }
        },

        .nearest => {
            assert(findSingleTagMatch(.exact, singles, span, source) == null);
            for (std.meta.tags(Command.Tag)) |tag| {
                if (anyCandidateMatches(singles.get(tag).suggestions, string))
                    return tag;
            }
            // TODO: Find suggestion with low edit distance
        },
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
