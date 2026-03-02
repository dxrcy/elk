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
        try runtime.writer.ensureNewline();
        try runtime.writer.interface.writeAll("Input> ");
        try runtime.writer.interface.flush();
    }

    if (runtime.tty.state == .uninit)
        try runtime.tty.init();
    try runtime.tty.enableRawMode();

    const char = try readByte(runtime);

    try runtime.tty.disableRawMode();

    if (vect == .in) {
        try runtime.writer.interface.writeByte(char);
        try runtime.writer.ensureNewline();
        try runtime.writer.interface.flush();
    }

    runtime.registers[0] = char;
}

fn readByte(runtime: *const Runtime) error{ EndOfStream, ReadFailed }!u8 {
    var char: u8 = undefined;
    runtime.reader.readSliceAll(@ptrCast(&char)) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.ReadFailed,
    };
    return char;
}

pub fn out(runtime: *Runtime) Traps.Result {
    const word: u8 = @truncate(runtime.registers[0]);
    try runtime.writer.interface.writeByte(word);
    try runtime.writer.interface.flush();
}

pub fn puts(runtime: *Runtime) Traps.Result {
    var i: usize = runtime.registers[0];
    while (true) : (i += 1) {
        const word: u8 = @truncate(runtime.memory[i]);
        if (word == 0x00)
            break;
        try runtime.writer.interface.writeByte(word);
    }
    try runtime.writer.interface.flush();
}

pub fn putsp(runtime: *Runtime) Traps.Result {
    var i: usize = runtime.registers[0];
    while (true) : (i += 1) {
        const words: [2]u8 = @bitCast(runtime.memory[i]);
        if (words[0] == 0x00)
            break;
        try runtime.writer.interface.writeByte(words[0]);
        if (words[1] == 0x00)
            break;
        try runtime.writer.interface.writeByte(words[1]);
    }
    try runtime.writer.interface.flush();
}

pub fn putn(runtime: *Runtime) Traps.Result {
    try runtime.writer.ensureNewline();
    try runtime.writer.interface.print("{}\n", .{runtime.registers[0]});
    try runtime.writer.interface.flush();
}

pub fn reg(runtime: *Runtime) Traps.Result {
    try runtime.printRegisters();
    try runtime.writer.interface.flush();
}
