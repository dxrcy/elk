const std = @import("std");
const Io = std.Io;

const Runtime = @import("Runtime.zig");
const Traps = @import("../Traps.zig");

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

    const char = try runtime.readByte();

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
    var i: usize = runtime.state.registers[0];
    while (true) : (i += 1) {
        const word: u8 = @truncate(runtime.state.memory[i]);
        if (word == 0x00)
            break;
        try runtime.writeChar(word);
    }
    try runtime.writer.flush();
}

pub fn putsp(runtime: *Runtime) Traps.Result {
    var i: usize = runtime.state.registers[0];
    while (true) : (i += 1) {
        const words: [2]u8 = @bitCast(runtime.state.memory[i]);
        if (words[0] == 0x00)
            break;
        try runtime.writeChar(words[0]);
        if (words[1] == 0x00)
            break;
        try runtime.writeChar(words[1]);
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
