const std = @import("std");

const Reporter = @import("../../report/Reporter.zig");
const Span = @import("../../compile/Span.zig");
const Lexer = @import("../../compile/parse/Lexer.zig");
const Command = @import("command.zig").Command;
const tags = @import("tags.zig");

pub fn parseCommand(string: []const u8, reporter: *Reporter) !?Command {
    var lexer = Lexer.new(string, false);

    const tag = try parseCommandTag(&lexer, string, reporter) orelse
        return null;

    std.debug.print("{t}\n", .{tag});

    return error.Unimplemented;
}

fn parseCommandTag(lexer: *Lexer, source: []const u8, reporter: *Reporter) !?Command.Tag {
    const first = lexer.next() orelse
        return null;

    for (tags.double) |double| {
        if (try findDoubleMatch(double, first, lexer, source, reporter)) |tag|
            return tag;
    }

    return findSingleMatch(&tags.single, first, source, reporter) orelse {
        try reporter.report(.debugger_any_err, .{
            .code = error.InvalidCommand,
            .span = first,
        }).abort();
    };
}

fn findDoubleMatch(
    double: tags.DoubleEntry,
    first: Span,
    lexer: *Lexer,
    source: []const u8,
    reporter: *Reporter,
) !?Command.Tag {
    if (!anyCandidateMatches(double.first, first.view(source)))
        return null;

    const second = lexer.next() orelse
        return double.default orelse {
            try reporter.report(.debugger_any_err, .{
                .code = error.MissingSubcommand,
                .span = .emptyAt(source.len),
            }).abort();
        };

    return findSingleMatch(&double.second, second, source, reporter) orelse {
        try reporter.report(.debugger_any_err, .{
            .code = error.InvalidSubcommand,
            .span = second,
        }).abort();
    };
}

fn findSingleMatch(
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
