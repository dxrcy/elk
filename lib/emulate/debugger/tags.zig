const std = @import("std");

const Command = @import("Command.zig");

/// First item is 'canonical' name, eg. `"step"` is canonical name of "s".
pub const Candidates = []const []const u8;

pub const SingleEntry = struct {
    aliases: Candidates = &.{},
    suggestions: Candidates = &.{},
};

pub const SingleMap = std.EnumArray(Command.Tag, SingleEntry);

pub const DoubleEntry = struct {
    first: Candidates,
    second: SingleMap,
    default: ?Command.Tag,
};

pub const single: SingleMap = .init(.{
    .help = .{
        .aliases = &.{ "help", "h", "--help", "-h", ":h", "man", "info", "wtf" },
    },
    .quit = .{
        .aliases = &.{ "quit", "q" },
    },
    .exit = .{
        .aliases = &.{ "exit", "x", ":q", ":wq", "^C" },
        .suggestions = &.{ "halt", "end", "stop" },
    },
    .clear = .{
        .aliases = &.{"clear"},
    },
    .reset = .{
        .aliases = &.{ "reset", "z" },
        .suggestions = &.{ "restart", "refresh", "reboot" },
    },
    .registers = .{
        .aliases = &.{ "registers", "r", "reg" },
        .suggestions = &.{ "dump", "register", "regs" },
    },
    .@"continue" = .{
        .aliases = &.{ "continue", "c", "cont" },
        .suggestions = &.{ "con", "proceed" },
    },
    .print = .{
        .aliases = &.{ "print", "p" },
        .suggestions = &.{ "get", "show", "display", "put", "puts", "out" },
    },
    .list = .{
        .aliases = &.{ "list", "l" },
        .suggestions = &.{ "ls", "listing", "dump", "memory" },
    },
    .move = .{
        .aliases = &.{ "move", "m" },
        .suggestions = &.{ "set", "mov", "mv", "assign" },
    },
    .goto = .{
        .aliases = &.{ "goto", "g" },
        .suggestions = &.{ "jump", "call", "go", "go-to", "jsr", "jsrr", "br", "brn", "brz", "brp", "brnz", "brnp", "brzp", "brnzp" },
    },
    .assembly = .{
        .aliases = &.{ "assembly", "a", "asm" },
        .suggestions = &.{ "source", "src", "ass", "inspect" },
    },
    .eval = .{
        .aliases = &.{ "eval", "e", "evil", "evaluate" },
        .suggestions = &.{ "run", "exec", "execute", "sim", "simulate", "instruction", "instr" },
    },
    .echo = .{
        .aliases = &.{"echo"},
    },
    .step_over = .{
        .aliases = &.{},
        .suggestions = &.{ "next", "step-over", "stepover" },
    },
    .step_into = .{
        .aliases = &.{ "stepinto", "si" },
        .suggestions = &.{ "into", "in", "stepin", "step-into", "step-in", "stepi", "step-i", "sin" },
    },
    .step_out = .{
        .aliases = &.{ "stepout", "so" },
        .suggestions = &.{ "finish", "fin", "out", "step-out", "stepo", "step-o", "sout" },
    },
    .break_list = .{
        .aliases = &.{ "breaklist", "bl" },
        .suggestions = &.{ "break-list", "break-ls", "blist", "bls", "bp", "breakpoint", "breakpointlist", "breakpoint-list" },
    },
    .break_add = .{
        .aliases = &.{ "breakadd", "ba" },
        .suggestions = &.{ "break-add", "badd", "breakpointadd", "breakpoint-add" },
    },
    .break_remove = .{
        .aliases = &.{ "breakremove", "br" },
        .suggestions = &.{ "break-remove", "break-rm", "bremove", "brm", "breakpointremove", "breakpoint-remove" },
    },
});

pub const double = [_]DoubleEntry{
    .{
        .first = &.{ "step", "s" },
        .second = .initDefault(.{}, .{
            .step_over = .{
                .suggestions = &.{"next"},
            },
            .step_into = .{
                .aliases = &.{ "i", "into" },
                .suggestions = &.{"in"},
            },
            .step_out = .{
                .aliases = &.{ "o", "out" },
                .suggestions = &.{ "finish", "fin" },
            },
        }),
        .default = .step_over,
    },
    .{
        .first = &.{ "break", "b" },
        .second = .initDefault(.{}, .{
            .break_list = .{
                .aliases = &.{ "l", "list" },
                .suggestions = &.{ "print", "show", "display", "dump", "ls" },
            },
            .break_add = .{
                .aliases = &.{ "a", "add" },
                .suggestions = &.{ "set", "move" },
            },
            .break_remove = .{
                .aliases = &.{ "r", "remove" },
                .suggestions = &.{ "delete", "rm" },
            },
        }),
        .default = null,
    },
};
