const Debugger = @This();

const std = @import("std");

const Span = @import("../compile/Span.zig");
const Lexer = @import("../compile/parse/Lexer.zig");
const Runtime = @import("Runtime.zig");

pub fn new() Debugger {
    return .{};
}

pub const Command = union(enum) {
    help,
    @"continue",
    registers,
    print: struct { location: Location },
    move: struct { location: Location, value: u16 },
    goto: struct { location: Location.Memory },
    assembly: struct { location: Location.Memory },
    eval: struct { instruction: Span },
    echo: struct { string: Span },
    reset,
    quit,
    exit,
    step_over,
    step_into: struct { count: u16 },
    step_out,
    break_list,
    break_add: struct { location: Location.Memory },
    break_remove: struct { location: Location.Memory },

    pub const Tag = std.meta.Tag(@This());

    pub const Location = union(enum) {
        register: u3,
        memory: Memory,

        pub const Memory = union(enum) {
            pc_offset: i16,
            address: u16,
            label: Label,
        };
    };

    pub const Label = struct {
        name: Span,
        offset: i16,
    };

    pub fn tagString(command: Tag) [:0]const u8 {
        return switch (command) {
            .help => "help",
            .@"continue" => "continue",
            .registers => "registers",
            .print => "print",
            .move => "move",
            .goto => "goto",
            .assembly => "assembly",
            .eval => "eval",
            .echo => "echo",
            .reset => "reset",
            .quit => "quit",
            .exit => "exit",
            .step_over => "step over",
            .step_into => "step into",
            .step_out => "step out",
            .break_list => "break list",
            .break_add => "break add",
            .break_remove => "break remove",
        };
    }
};

const tags = struct {
    pub const Candidates = []const []const u8;

    pub const SingleMap = std.EnumArray(Command.Tag, SingleEntry);

    pub const SingleEntry = struct {
        aliases: Candidates = &.{},
        suggestions: Candidates = &.{},
    };

    const DoubleEntry = struct {
        first: Candidates,
        second: SingleMap,
        default: ?Command.Tag,
    };

    pub const single: SingleMap = .init(.{
        .help = .{
            .aliases = &.{ "h", "help", "--help", "-h", ":h", "man", "info", "wtf" },
        },
        .@"continue" = .{
            .aliases = &.{ "c", "continue", "cont" },
            .suggestions = &.{ "con", "proceed" },
        },
        .print = .{
            .aliases = &.{ "p", "print" },
            .suggestions = &.{ "get", "show", "display", "put", "puts", "out" },
        },
        .move = .{
            .aliases = &.{ "m", "move" },
            .suggestions = &.{ "set", "mov", "mv", "assign" },
        },
        .registers = .{
            .aliases = &.{ "r", "registers", "reg" },
            .suggestions = &.{ "dump", "register", "regs" },
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
        .reset = .{
            .aliases = &.{ "z", "reset" },
            .suggestions = &.{ "restart", "refresh", "reboot" },
        },
        .echo = .{
            .aliases = &.{"echo"},
        },
        .quit = .{
            .aliases = &.{ "q", "quit" },
        },
        .exit = .{
            .aliases = &.{ "x", "exit", ":q", ":wq", "^C" },
            .suggestions = &.{ "halt", "end", "stop" },
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

    const double = [_]DoubleEntry{
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
};

fn parseCommand(string: []const u8) !Command {
    var lexer = Lexer.new(string, false);

    const tag = try parseCommandTag(&lexer, string);

    std.debug.print("{t}\n", .{tag});

    return error.Unimplemented;
}

fn parseCommandTag(lexer: *Lexer, source: []const u8) !Command.Tag {
    const first = lexer.next() orelse
        return error.EmptyCommand;
    for (tags.double) |double| {
        if (try findDoubleMatch(double, first, lexer, source)) |tag|
            return tag;
    }
    return findSingleMatch(&tags.single, first.view(source)) orelse
        error.InvalidCommand;
}

fn findDoubleMatch(
    double: tags.DoubleEntry,
    first: Span,
    lexer: *Lexer,
    source: []const u8,
) !?Command.Tag {
    if (!anyCandidateMatches(double.first, first.view(source)))
        return null;
    const second = lexer.next() orelse
        return double.default orelse error.MissingSubcommand;
    return findSingleMatch(&double.second, second.view(source)) orelse
        error.InvalidSubcommand;
}

fn findSingleMatch(singles: *const tags.SingleMap, string: []const u8) ?Command.Tag {
    for (std.meta.tags(Command.Tag)) |tag| {
        const entry = singles.get(tag);
        if (anyCandidateMatches(entry.aliases, string))
            return tag;
        if (anyCandidateMatches(entry.suggestions, string)) {
            std.debug.print("DID YOU MEAN: {s}\n", .{Command.tagString(tag)});
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

pub fn invoke(debugger: *Debugger, runtime: *Runtime) !?Runtime.Control {
    std.debug.print("[INVOKE DEBUGGER]\n", .{});

    var command_buffer: [20]u8 = undefined;

    while (true) {
        std.debug.print("\n", .{});

        const command_string = try debugger.readCommand(runtime, &command_buffer);

        const command = parseCommand(command_string) catch |err| {
            std.debug.print("Error: {t}\n", .{err});
            continue;
        };

        std.debug.print("Command: {}\n", .{command});
        return null;
    }
}

fn readCommand(debugger: *Debugger, runtime: *Runtime, buffer: []u8) ![]const u8 {
    _ = debugger;

    var length: usize = 0;

    try runtime.tty.enableRawMode();

    while (true) {
        std.debug.print("\r\x1b[K", .{});
        std.debug.print("> {s}", .{buffer[0..length]});

        const char = try runtime.readByte();

        switch (char) {
            '\n' => break,

            std.ascii.control_code.bs,
            std.ascii.control_code.del,
            => if (length > 0) {
                length -= 1;
            },

            else => if (length < buffer.len) {
                buffer[length] = char;
                length += 1;
            },
        }
    }

    std.debug.print("\n", .{});
    try runtime.tty.disableRawMode();

    return buffer[0..length];
}
