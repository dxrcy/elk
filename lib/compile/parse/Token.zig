const Token = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const Traps = @import("../../Traps.zig");
const Span = @import("../Span.zig");
const parsing = @import("parsing.zig");
const integers = @import("integers.zig");

span: Span,
value: Value,

pub const Error =
    integers.Error ||
    error{
        InvalidDirective,
        UnknownDirective,
        InvalidLabel,
        InvalidToken,
        UnmatchedQuote,
    };

pub fn isValidChar(char: u8) bool {
    return switch (char) {
        0x20...0x7e, '\t', '\r', '\n' => true,
        else => false,
    };
}

pub fn from(span: Span, source: []const u8, traps: *const Traps) Error!Token {
    const value: Value = try .from(span.viewString(source), traps);
    return .{ .span = span, .value = value };
}

pub const Value = union(enum) {
    newline,
    comma,
    colon,

    directive: Directive,
    mnemonic: Mnemonic,
    trap_alias: u8,
    label,

    register: u3,
    integer: integers.SourceInt(16),
    /// Contained in `Token.span`.
    string: Span,

    pub const Directive = enum {
        orig,
        end,
        fill,
        blkw,
        stringz,
    };

    pub const Mnemonic = enum {
        // Arithmetic
        add,
        @"and",
        not,
        // Branch
        br,
        brn,
        brz,
        brp,
        brnz,
        brzp,
        brnp,
        brnzp,
        // Jump
        jmp,
        ret,
        jsr,
        jsrr,
        // Load / store
        lea,
        ld,
        st,
        ldi,
        sti,
        ldr,
        str,
        // Trap *aliases* are handled separatly
        trap,
        // Extension instructions
        push,
        pop,
        call,
        rets,
        // Only used in 'supervisor' mode
        rti,
    };

    pub fn from(string: []const u8, traps: *const Traps) Error!Value {
        assert(string.len > 0);

        // Trap aliases always take precedence
        if (try tryTrap(string, traps)) |value|
            return value;

        const parsers = [_]fn ([]const u8) Error!?Value{
            // Order is important
            tryKeyword,
            tryRegister,
            tryInteger,
            tryString,
            tryDirective,
            tryMnemonic,
            tryLabel,
        };
        inline for (parsers) |parser| {
            if (try parser(string)) |value|
                return value;
        }
        return error.InvalidToken;
    }

    fn tryKeyword(string: []const u8) Error!?Value {
        return if (std.mem.eql(u8, string, "\n"))
            .newline
        else if (std.mem.eql(u8, string, ","))
            .comma
        else if (std.mem.eql(u8, string, ":"))
            .colon
        else
            null;
    }

    fn tryRegister(string: []const u8) Error!?Value {
        const register = parsing.tryRegister(string) orelse
            return null;
        return .{ .register = register };
    }

    fn tryInteger(string: []const u8) Error!?Value {
        const integer = try integers.tryInteger(string) orelse
            return null;
        return .{ .integer = integer };
    }

    fn tryString(string: []const u8) Error!?Value {
        if (string.len < 2)
            return null;
        const has_initial_quote = string[0] == '"';
        const has_final_quote = string[string.len - 1] == '"';
        if (!has_initial_quote and !has_final_quote)
            return null;
        if (!has_initial_quote or !has_final_quote)
            return error.UnmatchedQuote;
        return .{ .string = .fromBounds(1, string.len - 1) };
    }

    fn tryDirective(string: []const u8) Error!?Value {
        if (string.len < 2 or string[0] != '.')
            return null;
        const rest = string[1..];
        if (!parsing.isIdent(rest))
            return error.InvalidDirective;
        if (matchTagName(Directive, rest)) |directive| {
            return .{ .directive = directive };
        }
        return error.UnknownDirective;
    }

    fn tryMnemonic(string: []const u8) Error!?Value {
        assert(string.len > 0);
        if (matchTagName(Mnemonic, string)) |mnemonic| {
            return .{ .mnemonic = mnemonic };
        }
        return null;
    }

    fn tryLabel(string: []const u8) Error!?Value {
        return if (try parsing.isLabel(string)) .label else null;
    }

    fn tryTrap(string: []const u8, traps: *const Traps) Error!?Value {
        assert(string.len > 0);
        for (traps.entries, 0..) |entry, vect| {
            if (entry.alias) |alias|
                if (std.ascii.eqlIgnoreCase(string, alias))
                    return .{ .trap_alias = @intCast(vect) };
        }
        return null;
    }

    fn matchTagName(comptime T: type, string: []const u8) ?T {
        for (std.meta.tags(T)) |tag| {
            if (std.ascii.eqlIgnoreCase(string, @tagName(tag)))
                return tag;
        }
        return null;
    }
};

pub const Escaped = struct {
    delim: Delim,
    string: []const u8,
    index: usize,
    is_escaped: bool,

    pub const Delim = enum(u8) { single = '\'', double = '"' };

    const indicator = '\\';
    fn escapeChar(char: u8) ?u8 {
        return switch (char) {
            indicator => indicator,
            '"' => '"',
            '\'' => '\'',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => null,
        };
    }

    pub fn validLength(delim: Delim, string: []const u8) usize {
        var length: usize = 0;
        var escaped: Escaped = .new(delim, string);
        while (escaped.next()) |result| {
            _ = result catch continue;
            length += 1;
        }
        return length;
    }

    pub fn new(delim: Delim, string: []const u8) Escaped {
        if (string.len > 0) assert(string[string.len - 1] != indicator);
        return .{
            .delim = delim,
            .string = string,
            .index = 0,
            .is_escaped = false,
        };
    }

    pub fn next(escaped: *Escaped) ?error{InvalidSequence}!u8 {
        var raw = escaped.nextRaw() orelse
            return null;

        if (!escaped.is_escaped and raw == indicator) {
            escaped.is_escaped = true;
            raw = escaped.nextRaw() orelse
                unreachable; // Trailing indicator should have been checked already
        }

        if (!escaped.is_escaped) {
            if (raw == @intFromEnum(escaped.delim))
                return error.InvalidSequence;
            return raw;
        }

        const char_opt = escapeChar(raw);
        escaped.is_escaped = false;
        return char_opt orelse error.InvalidSequence;
    }

    fn nextRaw(escaped: *Escaped) ?u8 {
        if (escaped.index >= escaped.string.len)
            return null;
        const raw = escaped.string[escaped.index];
        escaped.index += 1;
        return raw;
    }
};
