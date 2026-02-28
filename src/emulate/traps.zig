const std = @import("std");
const Io = std.Io;

const Runtime = @import("Runtime.zig");

pub const Error =
    Runtime.IoError ||
    error{ TrapFailed, Halt };

pub const Result = Error!void;

pub const Vect = enum(u8) {
    getc = 0x20,
    out = 0x21,
    puts = 0x22,
    in = 0x23,
    putsp = 0x24,
    halt = 0x25,
    putn = 0x26,
    reg = 0x27,
    _,
};

pub const Table = struct {
    entries: [1 << 8]?Entry,

    pub const Entry = struct {
        procedure: Procedure,
        data: *const anyopaque,

        pub const Procedure = *const fn (*Runtime, *const anyopaque) Result;
    };

    pub const default: Table = blk: {
        var table: Table = .{ .entries = @splat(null) };
        for (@typeInfo(Vect).@"enum".fields) |field| {
            table.register(@field(Vect, field.name), @field(defaults, field.name), undefined);
        }
        break :blk table;
    };

    pub fn register(
        table: *Table,
        vect: Vect,
        procedure: Entry.Procedure,
        data: *const anyopaque,
    ) void {
        table.entries[@intFromEnum(vect)] = .{
            .procedure = procedure,
            .data = data,
        };
    }
};

pub const defaults = struct {
    pub fn halt(_: *Runtime, _: *const anyopaque) Result {
        return error.Halt;
    }

    pub fn getc(runtime: *Runtime, _: *const anyopaque) Result {
        return readChar(runtime, .getc);
    }

    pub fn in(runtime: *Runtime, _: *const anyopaque) Result {
        return readChar(runtime, .in);
    }

    fn readChar(runtime: *Runtime, comptime vect: enum { in, getc }) Result {
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

    pub fn out(runtime: *Runtime, _: *const anyopaque) Result {
        const word: u8 = @truncate(runtime.registers[0]);
        try runtime.writer.interface.writeByte(word);
        try runtime.writer.interface.flush();
    }

    pub fn puts(runtime: *Runtime, _: *const anyopaque) Result {
        var i: usize = runtime.registers[0];
        while (true) : (i += 1) {
            const word: u8 = @truncate(runtime.memory[i]);
            if (word == 0x00)
                break;
            try runtime.writer.interface.writeByte(word);
        }
        try runtime.writer.interface.flush();
    }

    pub fn putsp(runtime: *Runtime, _: *const anyopaque) Result {
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

    pub fn putn(runtime: *Runtime, _: *const anyopaque) Result {
        try runtime.writer.ensureNewline();
        try runtime.writer.interface.print("{}\n", .{runtime.registers[0]});
        try runtime.writer.interface.flush();
    }

    pub fn reg(runtime: *Runtime, _: *const anyopaque) Result {
        try runtime.printRegisters();
        try runtime.writer.interface.flush();
    }
};
