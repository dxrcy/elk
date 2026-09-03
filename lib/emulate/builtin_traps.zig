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
    var stringz: Stringz = .{
        .memory = runtime.state.memory,
        .address = runtime.state.registers[0],
    };
    while (stringz.next()) |word| {
        const byte: u8 = @truncate(word);
        try runtime.writeChar(byte);
    }
    try runtime.writer.flush();
}

pub fn putsp(runtime: *Runtime) Traps.Result {
    var stringz: Stringz = .{
        .memory = runtime.state.memory,
        .address = runtime.state.registers[0],
    };
    while (stringz.next()) |word| {
        const bytes: [2]u8 = @bitCast(word);
        try runtime.writeChar(bytes[0]);
        try runtime.writeChar(bytes[1]);
    }
    try runtime.writer.flush();
}

const Stringz = struct {
    memory: *const [Runtime.memory_size]u16,
    address: u16,
    end: bool = false,

    pub fn next(stringz: *Stringz) ?u16 {
        if (stringz.end)
            return null;
        const word = stringz.memory[stringz.address];
        if (word == 0x0000) {
            stringz.end = true;
            return null;
        }
        stringz.address += 1;
        return word;
    }
};

pub fn putn(runtime: *Runtime) Traps.Result {
    try runtime.ensureWriterNewline();
    try runtime.writer.print("{}\n", .{runtime.state.registers[0]});
    try runtime.writer.flush();
}

pub fn reg(runtime: *Runtime) Traps.Result {
    try runtime.printRegisters();
    try runtime.writer.flush();
}
