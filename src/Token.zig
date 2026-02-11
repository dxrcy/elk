const Token = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const integers = @import("integers.zig");
const Span = @import("Span.zig");

// TODO: Rename, since "kind" might imply a tag with no data
kind: Kind,
span: Span,

pub const Error = error{
    InvalidInteger,
    InvalidDirective,
    InvalidIdent,
    InvalidToken,
};

pub fn from(span: Span, source: []const u8) !Token {
    const kind: Kind = try .from(span.resolve(source));
    return .{ .kind = kind, .span = span };
}

pub const Kind = union(enum) {
    // TODO: Use spans instead of slices
    // spans can be relative to (contained by) `token.span`
    newline,
    comma,
    register: u3,
    integer: u16,
    string: []const u8,
    directive: Directive,
    instruction: Instruction,
    label: []const u8,

    pub const Directive = enum {
        ORIG,
        END,
        FILL,
        BLKW,
        STRINGZ,
    };

    pub const Instruction = enum {
        // Arithmetic
        ADD,
        AND,
        NOT,
        // Branch / jump
        BR,
        BRN,
        BRZ,
        BRP,
        BRNZ,
        BRZP,
        BRNP,
        BRNZP,
        JMP,
        RET,
        JSR,
        JSRR,
        // Load / store
        LD,
        ST,
        LDI,
        STI,
        LDR,
        STR,
        LEA,
        // Traps
        TRAP,
        GETC,
        OUT,
        PUTS,
        IN,
        PUTSP,
        HALT,
        // Extension traps
        REG,
        DEBUG,
        // Only used in 'supervisor' mode
        RTI,
    };

    pub fn from(string: []const u8) Error!Kind {
        assert(string.len > 0);
        const parsers = [_]fn ([]const u8) Error!?Kind{
            tryKeyword,
            tryRegister,
            tryInteger,
            tryString,
            tryDirective,
            tryInstruction,
            tryLabel,
        };
        inline for (parsers) |parser| {
            if (try parser(string)) |kind|
                return kind;
        }
        return error.InvalidToken;
    }

    fn tryKeyword(string: []const u8) Error!?Kind {
        return if (std.mem.eql(u8, string, "\n"))
            .newline
        else if (std.mem.eql(u8, string, ","))
            .comma
        else
            null;
    }

    fn tryRegister(string: []const u8) Error!?Kind {
        if (string.len != 2)
            return null;
        switch (string[0]) {
            'r', 'R' => {},
            else => return null,
        }
        const register: u3 = switch (string[1]) {
            '0'...'7' => |char| @intCast(char - '0'),
            else => return null,
        };
        return .{ .register = register };
    }

    fn tryInteger(string: []const u8) Error!?Kind {
        const integer = try integers.tryInteger(string) orelse
            return null;
        return .{ .integer = integer };
    }

    fn tryString(string: []const u8) Error!?Kind {
        if (string.len < 2)
            return null;
        const has_initial_quote = string[0] == '"';
        const has_final_quote = string[string.len - 1] == '"';
        if (!has_initial_quote and !has_final_quote)
            return null;
        assert(has_initial_quote and has_final_quote);
        return .{ .string = string[1 .. string.len - 1] };
    }

    fn tryDirective(string: []const u8) Error!?Kind {
        if (string.len < 2 or string[0] != '.')
            return null;
        const rest = string[1..];
        if (!isIdent(rest))
            return error.InvalidIdent;
        if (matchTagName(Directive, rest)) |directive| {
            return .{ .directive = directive };
        }
        return error.InvalidDirective;
    }

    fn tryInstruction(string: []const u8) Error!?Kind {
        assert(string.len > 0);
        if (matchTagName(Instruction, string)) |instruction| {
            return .{ .instruction = instruction };
        }
        return null;
    }

    fn tryLabel(string: []const u8) Error!?Kind {
        assert(string.len > 0);
        if (!isIdent(string[0..1]))
            return null;
        if (!isIdent(string[1..]))
            return error.InvalidIdent;
        return .{ .label = string };
    }

    fn matchTagName(comptime T: type, string: []const u8) ?T {
        for (std.meta.tags(T)) |tag| {
            if (std.ascii.eqlIgnoreCase(string, @tagName(tag)))
                return tag;
        }
        return null;
    }

    fn isIdent(string: []const u8) bool {
        for (string, 0..) |char, i| {
            switch (char) {
                'a'...'z', 'A'...'Z', '_' => {},
                '0'...'9' => if (i == 0) return false,
                else => return false,
            }
        }
        return true;
    }

    pub fn format(kind: Kind, writer: *Io.Writer) Io.Writer.Error!void {
        switch (kind) {
            .newline => {
                try writer.print("newline", .{});
            },
            .comma => {
                try writer.print("comma", .{});
            },
            .register => |register| {
                try writer.print("register R{}", .{register});
            },
            .integer => |integer| {
                try writer.print("{}", .{integer});
            },
            .string => |string| {
                try writer.print("\"{s}\"", .{string});
            },
            .directive => |directive| {
                try writer.print("directive `{t}`", .{directive});
            },
            .instruction => |instruction| {
                try writer.print("instruction `{t}`", .{instruction});
            },
            .label => |string| {
                try writer.print("label `{s}`", .{string});
            },
        }
    }
};
