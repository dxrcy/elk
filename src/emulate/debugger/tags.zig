const std = @import("std");

const Command = @import("Command.zig");

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
        .aliases = &.{ "h", "help", "--help", "-h", ":h", "man", "info", "wtf" },
    },
    .quit = .{
        .aliases = &.{ "q", "quit" },
    },
    .exit = .{
        .aliases = &.{ "x", "exit", ":q", ":wq", "^C" },
        .suggestions = &.{ "halt", "end", "stop" },
    },
    .clear = .{
        .aliases = &.{"clear"},
    },
    .reset = .{
        .aliases = &.{ "z", "reset" },
        .suggestions = &.{ "restart", "refresh", "reboot" },
    },
    .registers = .{
        .aliases = &.{ "r", "registers", "reg" },
        .suggestions = &.{ "dump", "register", "regs" },
    },
    .@"continue" = .{
        .aliases = &.{ "c", "continue", "cont" },
        .suggestions = &.{ "con", "proceed" },
    },
    .print = .{
        .aliases = &.{ "p", "print" },
        .suggestions = &.{ "get", "show", "display", "put", "puts", "out" },
    },
    .list = .{
        .aliases = &.{ "l", "list" },
        .suggestions = &.{ "ls", "listing", "dump", "memory" },
    },
    .move = .{
        .aliases = &.{ "m", "move" },
        .suggestions = &.{ "set", "mov", "mv", "assign" },
    },
    .goto = .{
        .aliases = &.{ "g", "goto" },
        .suggestions = &.{ "jump", "call", "go", "go-to", "jsr", "jsrr", "br", "brn", "brz", "brp", "brnz", "brnp", "brzp", "brnzp" },
    },
    .assembly = .{
        .aliases = &.{ "a", "assembly", "asm" },
        .suggestions = &.{ "source", "src", "ass", "inspect" },
    },
    .eval = .{
        .aliases = &.{ "e", "eval", "evil", "evaluate" },
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
        .aliases = &.{ "si", "stepinto" },
        .suggestions = &.{ "into", "in", "stepin", "step-into", "step-in", "stepi", "step-i", "sin" },
    },
    .step_out = .{
        .aliases = &.{ "so", "stepout" },
        .suggestions = &.{ "finish", "fin", "out", "step-out", "stepo", "step-o", "sout" },
    },
    .break_list = .{
        .aliases = &.{ "bl", "breaklist" },
        .suggestions = &.{ "break-list", "break-ls", "blist", "bls", "bp", "breakpoint", "breakpointlist", "breakpoint-list" },
    },
    .break_add = .{
        .aliases = &.{ "ba", "breakadd" },
        .suggestions = &.{ "break-add", "badd", "breakpointadd", "breakpoint-add" },
    },
    .break_remove = .{
        .aliases = &.{ "br", "breakremove" },
        .suggestions = &.{ "break-remove", "break-rm", "bremove", "brm", "breakpointremove", "breakpoint-remove" },
    },
});

pub const double = [_]DoubleEntry{
    .{
        .first = &.{ "s", "step" },
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
        .first = &.{ "b", "break" },
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
