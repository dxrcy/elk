const std = @import("std");
const Io = std.Io;

const elk = @import("../root.zig");
const Traps = elk.Traps;
const Runtime = elk.Runtime;

pub fn halt(_: *Runtime) Traps.Result {
    return error.Halt;
}

pub fn getc(runtime: *Runtime) Traps.Result {
    return readChar(runtime, .getc);
}

pub fn in(runtime: *Runtime) Traps.Result {
    return readChar(runtime, .in);
}

fn readChar(runtime: *Runtime, comptime vect: enum { in, getc }) Traps.Result {
    if (vect == .in) {
        try runtime.ensureWriterNewline();
        try runtime.writer.writeAll("Input> ");
        try runtime.writer.flush();
    }

    try runtime.tty.enableRawMode();
    errdefer runtime.tty.disableRawMode() catch {};

    const char = runtime.readByte() catch |err| switch (err) {
        error.EndOfStream => std.ascii.control_code.eot,
        else => |e| return e,
    };

    try runtime.tty.disableRawMode();

    if (vect == .in) {
        try runtime.writeChar(char);
        try runtime.ensureWriterNewline();
        try runtime.writer.flush();
    }

    runtime.state.registers[0] = char;
}

pub fn out(runtime: *Runtime) Traps.Result {
    const word: u8 = @truncate(runtime.state.registers[0]);
    try runtime.writeChar(word);
    try runtime.writer.flush();
}

pub fn puts(runtime: *Runtime) Traps.Result {
    var stringz = runtime.stringzAt(runtime.state.registers[0]);
    while (stringz.next() catch
        return error.TrapFailed) |word|
    {
        const byte: u8 = @truncate(word);
        try runtime.writeChar(byte);
    }
    try runtime.writer.flush();
}

pub fn putsp(runtime: *Runtime) Traps.Result {
    var stringz = runtime.stringzAt(runtime.state.registers[0]);
    while (stringz.next() catch
        return error.TrapFailed) |word|
    {
        const bytes: [2]u8 = @bitCast(word);
        try runtime.writeChar(bytes[0]);
        try runtime.writeChar(bytes[1]);
    }
    try runtime.writer.flush();
}

pub fn putn(runtime: *Runtime) Traps.Result {
    try runtime.ensureWriterNewline();
    try runtime.writer.print("{}\n", .{runtime.state.registers[0]});
    try runtime.writer.flush();
}

pub fn reg(runtime: *Runtime) Traps.Result {
    try runtime.printRegisters();
    try runtime.writer.flush();
}
