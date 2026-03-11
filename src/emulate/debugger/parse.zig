const std = @import("std");
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Span = @import("../../compile/Span.zig");
const Lexer = @import("../../compile/parse/Lexer.zig");
const parsing = @import("../../compile/parse/parsing.zig");
const integers = @import("../../compile/parse/integers.zig");
const Command = @import("command.zig").Command;
const CommandSpanned = @import("command.zig").CommandSpanned;
const tags = @import("tags.zig");

pub fn Spanned(comptime K: type) type {
    return struct { span: Span, value: K };
}

pub fn parseCommand(
    string: []const u8,
    reporter: *Reporter,
) error{Reported}!?CommandSpanned {
    var lexer = Lexer.new(string, false);

    var parser: Parser = .{
        .lexer = &lexer,
        .source = string,
        .reporter = reporter,
    };

    const tag = try parser.parseCommandTag() orelse
        return null;

    const value = try parser.parseCommandArguments(tag);

    return .{
        // This is redundant for now, but will be useful when a line can contain multiple commands
        .line = .fromBounds(0, string.len),

        .tag = tag.span,
        .value = value,
    };
}

const Parser = struct {
    lexer: *Lexer,
    source: []const u8,
    reporter: *Reporter,

    fn parseCommandArguments(parser: *Parser, tag: Spanned(Command.Tag)) !Command {
        const value: Command = switch (tag.value) {
            // TODO: Parse all commands
            else => {
                try parser.reporter.report(.debugger_any_err, .{
                    .code = error.UnimplementedCommand,
                    .span = tag.span,
                }).abort();
            },

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
        };

        if (parser.next()) |span| {
            try parser.reporter.report(.debugger_any_err, .{
                .code = error.UnexpectedArgument,
                .span = span,
            }).abort();
        } else |err| switch (err) {
            error.Eof => {}, // Good
        }

        return value;
    }

    fn next(parser: *Parser) error{Eof}!Span {
        while (true) {
            const token = parser.lexer.next() orelse
                return error.Eof;
            if (!std.mem.eql(u8, token.view(parser.source), ","))
                return token;
        }
    }

    fn nextInteger(parser: *Parser) error{Reported}!u16 {
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => try parser.reporter.report(.debugger_any_err, .{
                .code = error.ExpectedArgument,
                .span = .emptyAt(parser.source.len),
            }).abort(),
        };

        const integer = try parser.parseInteger(argument);
        return integer.underlying;
    }

    fn nextOptionalPositiveInt(parser: *Parser) error{Reported}!u16 {
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => return 1,
        };

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
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => try parser.reporter.report(.debugger_any_err, .{
                .code = error.ExpectedArgument,
                .span = .emptyAt(parser.source.len),
            }).abort(),
        };

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
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => try parser.reporter.report(.debugger_any_err, .{
                .code = error.ExpectedArgument,
                .span = .emptyAt(parser.source.len),
            }).abort(),
        };

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

    fn parseCommandTag(parser: *Parser) error{Reported}!?Spanned(Command.Tag) {
        const first = parser.next() catch |err| switch (err) {
            error.Eof => return null,
        };

        for (tags.double) |double| {
            if (try parser.findDoubleTagMatch(double, first)) |tag|
                return tag;
        }

        if (parser.findSingleTagMatch(.exact, &tags.single, first)) |tag|
            return tag;

        const result = parser.reporter.report(.debugger_any_err, .{
            .code = error.InvalidCommand,
            .span = first,
        }).abort();

        if (parser.findSingleTagMatch(.nearest, &tags.single, first)) |tag| {
            _ = tag;
            parser.reporter.report(.debugger_any_warn, .{
                .code = error.CommandSuggestion,
                .span = first,
            }).proceed();
        }

        try result;
    }

    fn findDoubleTagMatch(
        parser: *Parser,
        double: tags.DoubleEntry,
        first: Span,
    ) error{Reported}!?Spanned(Command.Tag) {
        if (!anyCandidateMatches(double.first, first.view(parser.source)))
            return null;

        const second = parser.next() catch |err| switch (err) {
            error.Eof => {
                const tag = double.default orelse {
                    try parser.reporter.report(.debugger_any_err, .{
                        .code = error.MissingSubcommand,
                        .span = .emptyAt(parser.source.len),
                    }).abort();
                };
                return .{ .span = first, .value = tag };
            },
        };

        if (parser.findSingleTagMatch(.exact, &double.second, second)) |tag|
            return .{ .span = first.join(second), .value = tag.value };

        const result = parser.reporter.report(.debugger_any_err, .{
            .code = error.InvalidSubcommand,
            .span = second,
        }).abort();

        if (parser.findSingleTagMatch(.nearest, &double.second, second)) |tag| {
            _ = tag;
            parser.reporter.report(.debugger_any_warn, .{
                .code = error.CommandSuggestion,
                .span = second,
            }).proceed();
        }

        try result;
    }

    fn findSingleTagMatch(
        parser: *const Parser,
        comptime mode: enum { exact, nearest },
        singles: *const tags.SingleMap,
        span: Span,
    ) ?Spanned(Command.Tag) {
        const string = span.view(parser.source);

        switch (mode) {
            .exact => {
                for (std.meta.tags(Command.Tag)) |tag| {
                    if (anyCandidateMatches(singles.get(tag).aliases, string))
                        return .{ .span = span, .value = tag };
                }
            },

            .nearest => {
                assert(parser.findSingleTagMatch(.exact, singles, span) == null);
                for (std.meta.tags(Command.Tag)) |tag| {
                    if (anyCandidateMatches(singles.get(tag).suggestions, string))
                        return .{ .span = span, .value = tag };
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
};
