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

    pub fn tagString(command: std.meta.Tag(Command)) [:0]const u8 {
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

const tag_maps = struct {
    pub const Candidates = []const []const u8;
    pub const TagMap = std.EnumArray(
        std.meta.Tag(Command),
        struct { Candidates, Candidates },
    );
    const Subcommand = struct {
        first: tag_maps.Candidates,
        second: tag_maps.TagMap,
        default: ?std.meta.Tag(Command),
    };

    pub const single: TagMap = .init(.{
        .help = .{
            &.{ "h", "help", "--help", "-h", ":h", "man", "info", "wtf" },
            &.{},
        },
        .@"continue" = .{
            &.{ "c", "continue", "cont" },
            &.{ "con", "proceed" },
        },
        .print = .{
            &.{ "p", "print" },
            &.{ "get", "show", "display", "put", "puts", "out" },
        },
        .move = .{
            &.{ "m", "move" },
            &.{ "set", "mov", "mv", "assign" },
        },
        .registers = .{
            &.{ "r", "registers", "reg" },
            &.{ "dump", "register", "regs" },
        },
        .goto = .{
            &.{ "g", "goto" },
            &.{ "jump", "call", "go", "go-to", "jsr", "jsrr", "br", "brn", "brz", "brp", "brnz", "brnp", "brzp", "brnzp" },
        },
        .assembly = .{
            &.{ "a", "assembly", "asm" },
            &.{ "source", "src", "ass", "inspect" },
        },
        .eval = .{
            &.{ "e", "eval", "evil", "evaluate" },
            &.{ "run", "exec", "execute", "sim", "simulate", "instruction", "instr" },
        },
        .reset = .{
            &.{ "z", "reset" },
            &.{ "restart", "refresh", "reboot" },
        },
        .echo = .{
            &.{"echo"},
            &.{},
        },
        .quit = .{
            &.{ "q", "quit" },
            &.{},
        },
        .exit = .{
            &.{ "x", "exit", ":q", ":wq", "^C" },
            &.{ "halt", "end", "stop" },
        },
        .step_over = .{
            &.{},
            &.{ "next", "step-over", "stepover" },
        },
        .step_into = .{
            &.{ "si", "stepinto" },
            &.{ "into", "in", "stepin", "step-into", "step-in", "stepi", "step-i", "sin" },
        },
        .step_out = .{
            &.{ "so", "stepout" },
            &.{ "finish", "fin", "out", "step-out", "stepo", "step-o", "sout" },
        },
        .break_list = .{
            &.{ "bl", "breaklist" },
            &.{ "break-list", "break-ls", "blist", "bls", "bp", "breakpoint", "breakpointlist", "breakpoint-list" },
        },
        .break_add = .{
            &.{ "ba", "breakadd" },
            &.{ "break-add", "badd", "breakpointadd", "breakpoint-add" },
        },
        .break_remove = .{
            &.{ "br", "breakremove" },
            &.{ "break-remove", "break-rm", "bremove", "brm", "breakpointremove", "breakpoint-remove" },
        },
    });

    const subcommands = [_]Subcommand{
        .{
            .first = &.{ "s", "step" },
            .second = .initDefault(.{ &.{}, &.{} }, .{
                .step_over = .{
                    &.{},
                    &.{"next"},
                },
                .step_into = .{
                    &.{ "i", "into" },
                    &.{"in"},
                },
                .step_out = .{
                    &.{ "o", "out" },
                    &.{ "finish", "fin" },
                },
            }),
            .default = .step_over,
        },
        .{
            .first = &.{ "b", "break" },
            .second = .initDefault(.{ &.{}, &.{} }, .{
                .break_list = .{
                    &.{ "l", "list" },
                    &.{ "print", "show", "display", "dump", "ls" },
                },
                .break_add = .{
                    &.{ "a", "add" },
                    &.{ "set", "move" },
                },
                .break_remove = .{
                    &.{ "r", "remove" },
                    &.{ "delete", "rm" },
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

fn parseCommandTag(lexer: *Lexer, source: []const u8) !std.meta.Tag(Command) {
    const first = lexer.next() orelse
        return error.EmptyCommand;

    for (tag_maps.subcommands) |subcommand| {
        if (try matchTagSubcommand(first, lexer, source, subcommand)) |tag|
            return tag;
    }

    return findTagMatch(&tag_maps.single, first.view(source)) orelse
        error.InvalidCommand;
}

fn matchTagSubcommand(
    first: Span,
    lexer: *Lexer,
    source: []const u8,
    subcommand: tag_maps.Subcommand,
) !?std.meta.Tag(Command) {
    if (tagMatches(subcommand.first, first.view(source))) {
        const second = lexer.next() orelse
            return subcommand.default orelse error.MissingSubcommand;
        return findTagMatch(&subcommand.second, second.view(source)) orelse
            error.InvalidSubcommand;
    }
    return null;
}

fn findTagMatch(map: *const tag_maps.TagMap, string: []const u8) ?std.meta.Tag(Command) {
    for (std.meta.tags(std.meta.Tag(Command))) |tag| {
        const aliases, const suggestions = map.get(tag);
        if (tagMatches(aliases, string))
            return tag;
        if (tagMatches(suggestions, string)) {
            std.debug.print("DID YOU MEAN: {s}\n", .{Command.tagString(tag)});
            return null;
        }
    }
    return null;
}

fn tagMatches(candidates: []const []const u8, string: []const u8) bool {
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
