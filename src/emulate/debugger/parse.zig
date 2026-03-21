const std = @import("std");
const assert = std.debug.assert;

const Reporter = @import("../../report/Reporter.zig");
const Span = @import("../../compile/Span.zig");
const Lexer = @import("../../compile/parse/Lexer.zig");
const parsing = @import("../../compile/parse/parsing.zig");
const integers = @import("../../compile/parse/integers.zig");
const Command = @import("Command.zig");
const tags = @import("tags.zig");
const Spanned = Command.Spanned;

pub fn splitCommandLine(line: []const u8) struct { []const u8, []const u8 } {
    var lexer: Lexer = .new(line, false);
    const token_len = while (lexer.next()) |token| {
        if (std.mem.eql(u8, token.view(line), ";"))
            break token.len;
    } else 0;

    return .{
        line[0 .. lexer.index - token_len],
        line[lexer.index..],
    };
}

pub fn parseCommand(
    string: []const u8,
    reporter: *Reporter,
) error{Reported}!?Command {
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
        .line = .fromBounds(0, parser.lexer.index),
        .tag = tag.span,
        .value = value,
    };
}

const Parser = struct {
    lexer: *Lexer,
    source: []const u8,
    reporter: *Reporter,

    fn parseCommandArguments(
        parser: *Parser,
        tag: Spanned(Command.Tag),
    ) error{Reported}!Command.Value {
        const value: Command.Value = switch (tag.value) {
            // Allow trailing arguments
            .help => return .help,

            inline .quit,
            .exit,
            .clear,
            .reset,
            .registers,
            .@"continue",
            .step_over,
            .step_out,
            .break_list,
            => |void_tag| @unionInit(Command.Value, @tagName(void_tag), {}),

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
            .assembly => .{ .assembly = .{
                .location = try parser.nextOptionalMemoryLocation(),
            } },
            .step_into => .{ .step_into = .{
                .count = try parser.nextOptionalPositiveInt(),
            } },
            .break_add => .{ .break_add = .{
                .location = try parser.nextMemoryLocation(),
            } },
            .break_remove => .{ .break_remove = .{
                .location = try parser.nextMemoryLocation(),
            } },

            .eval => .{ .eval = .{
                .instruction = try parser.remainingString(),
            } },
            .echo => .{ .echo = .{
                .string = try parser.remainingString(),
            } },
        };

        assert(value == tag.value);

        if (parser.next()) |span| {
            try parser.reporter.report(.debugger_expected_eol, .{
                .found = span,
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
            if (std.mem.eql(u8, token.view(parser.source), ";"))
                unreachable;
            if (std.mem.eql(u8, token.view(parser.source), ","))
                continue;
            return token;
        }
    }

    fn remainingString(parser: *Parser) error{Reported}!Span {
        var first = parser.lexer.next() orelse {
            try parser.reporter.report(.debugger_unexpected_eol, .{
                .eol = .emptyAt(parser.source.len),
            }).abort();
        };

        const start = first.offset;
        var end = first.end();
        while (parser.lexer.next()) |token| {
            end = token.end();
        }
        return .fromBounds(start, end);
    }

    fn nextInteger(parser: *Parser) error{Reported}!Spanned(u16) {
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => try parser.reporter.report(.debugger_unexpected_eol, .{
                .eol = .emptyAt(parser.source.len),
            }).abort(),
        };

        const integer = try parser.parseInteger(argument);

        return .{ .span = argument, .value = integer.underlying };
    }

    fn nextOptionalPositiveInt(parser: *Parser) error{Reported}!Spanned(u16) {
        const argument = parser.next() catch |err| switch (err) {
            // TODO: Maybe instead, change return to ?Spanned(u16)
            error.Eof => return .{ .span = .emptyAt(parser.source.len), .value = 1 },
        };

        const integer = try parser.parseInteger(argument);

        if (integer.underlying == 0) {
            try parser.reporter.report(.debugger_integer_too_small, .{
                .integer = argument,
                .minimum = 1,
            }).abort();
        }

        const value = integer.castToUnsigned() orelse {
            try parser.reporter.report(.integer_too_large, .{
                .integer = argument,
                .type_info = @typeInfo(u16).int,
            }).abort();
        };

        return .{ .span = argument, .value = value };
    }

    fn nextLocation(parser: *Parser) error{Reported}!Spanned(Command.Location) {
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => try parser.reporter.report(.debugger_unexpected_eol, .{
                .eol = .emptyAt(parser.source.len),
            }).abort(),
        };

        if (parsing.tryRegister(argument.view(parser.source))) |register|
            return .{ .span = argument, .value = .{ .register = register } };

        if (try parser.parseMemoryLocation(argument)) |memory|
            return .{ .span = argument, .value = .{ .memory = memory } };

        try parser.reporter.report(.debugger_invalid_argument_kind, .{
            .found = argument,
        }).abort();
    }

    fn nextOptionalMemoryLocation(
        parser: *Parser,
    ) error{Reported}!Spanned(Command.Location.Memory) {
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => return .{
                .value = .{ .pc_offset = 0 },
                .span = .emptyAt(parser.source.len),
            },
        };

        // TODO: Report, if is register

        if (try parser.parseMemoryLocation(argument)) |memory|
            return .{ .span = argument, .value = memory };

        try parser.reporter.report(.debugger_invalid_argument_kind, .{
            .found = argument,
        }).abort();
    }

    fn nextMemoryLocation(parser: *Parser) error{Reported}!Spanned(Command.Location.Memory) {
        const argument = parser.next() catch |err| switch (err) {
            error.Eof => try parser.reporter.report(.debugger_unexpected_eol, .{
                .eol = .emptyAt(parser.source.len),
            }).abort(),
        };

        // TODO: Report, if is register

        if (try parser.parseMemoryLocation(argument)) |memory|
            return .{ .span = argument, .value = memory };

        try parser.reporter.report(.debugger_invalid_argument_kind, .{
            .found = argument,
        }).abort();
    }

    fn parseInteger(parser: *Parser, argument: Span) error{Reported}!integers.SourceInt(16) {
        return try parser.tryParseInteger(argument) orelse {
            try parser.reporter.report(.debugger_invalid_argument_kind, .{
                .found = argument,
            }).abort();
        };
    }

    fn tryParseInteger(parser: *Parser, argument: Span) error{Reported}!?integers.SourceInt(16) {
        return integers.tryInteger(argument.view(parser.source)) catch |err| switch (err) {
            // TODO: These exact same branches exist in `compile/parse`... merge ?
            error.MalformedInteger => {
                try parser.reporter.report(.malformed_integer, .{
                    .integer = argument,
                }).abort();
            },
            error.ExpectedDigit => {
                try parser.reporter.report(.expected_digit, .{
                    .integer = argument,
                }).abort();
            },
            error.InvalidDigit => {
                try parser.reporter.report(.invalid_digit, .{
                    .integer = argument,
                }).abort();
            },
            error.UnexpectedDelimiter => {
                try parser.reporter.report(.unexpected_delimiter, .{
                    .integer = argument,
                }).abort();
            },
            error.IntegerTooLarge => {
                try parser.reporter.report(.integer_too_large, .{
                    .integer = argument,
                    .type_info = @typeInfo(u16).int,
                }).abort();
            },
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

        if (argument.view(parser.source)[0] != '~')
            return null;

        const integer_span: Span = .{ .offset = argument.offset + 1, .len = argument.len - 1 };

        if (integer_span.len == 0)
            return 0;

        const integer = try parser.tryParseInteger(integer_span) orelse {
            try parser.reporter.report(.debugger_invalid_argument_kind, .{
                .found = integer_span,
            }).abort();
        };

        return integer.castToSmaller(i16) catch {
            try parser.reporter.report(.integer_too_large, .{
                .integer = argument,
                .type_info = @typeInfo(i16).int,
            }).abort();
        };
    }

    fn parseAddress(parser: *Parser, argument: Span) error{Reported}!?u16 {
        const integer = try parser.tryParseInteger(argument) orelse
            return null;

        return integer.castToUnsigned() orelse {
            try parser.reporter.report(.integer_too_large, .{
                .integer = argument,
                .type_info = @typeInfo(u16).int,
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

        const is_label = parsing.isLabel(label_string) catch
            return null;

        if (!is_label) {
            try parser.reporter.report(.debugger_invalid_argument_kind, .{
                .found = argument,
            }).abort();
        }

        const offset_string = offset_string_opt orelse
            return .{ .name = label, .offset = 0 };

        const offset_span: Span = .{ // Include sign character
            .offset = argument.offset + label_string.len,
            .len = offset_string.len,
        };

        const integer = try parser.parseInteger(offset_span);

        assert(integer.form.sign.?.position == .pre_radix);

        const offset = integer.castToSmaller(i16) catch {
            try parser.reporter.report(.integer_too_large, .{
                .integer = argument,
                .type_info = @typeInfo(i16).int,
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

        const nearest =
            if (parser.findSingleTagMatch(.nearest, &tags.single, first)) |nearest|
                nearest.value
            else
                null;

        try parser.reporter.report(.debugger_invalid_command, .{
            .command = first,
            .nearest = nearest,
        }).abort();
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
                    try parser.reporter.report(.debugger_missing_subcommand, .{
                        .first = first,
                        .eol = .emptyAt(parser.source.len),
                    }).abort();
                };
                return .{ .span = first, .value = tag };
            },
        };

        if (parser.findSingleTagMatch(.exact, &double.second, second)) |tag|
            return .{ .span = first.join(second), .value = tag.value };

        const nearest =
            if (parser.findSingleTagMatch(.nearest, &double.second, second)) |nearest|
                nearest.value
            else
                null;

        try parser.reporter.report(.debugger_invalid_command, .{
            .command = second,
            .nearest = nearest,
        }).abort();
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
