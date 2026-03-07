const std = @import("std");

const Runtime = @import("Runtime.zig");
const Control = Runtime.Control;

pub fn invoke(runtime: *Runtime) !?Control {
    std.debug.print("[INVOKE DEBUGGER]\n", .{});

    try runtime.tty.enableRawMode();

    var buffer: [64]u8 = undefined;
    var length: usize = 0;

    while (true) {
        std.debug.print("\r\x1b[K", .{});
        std.debug.print("{s}", .{buffer[0..length]});

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

    try runtime.tty.disableRawMode();

    std.debug.print("\n", .{});
    std.debug.print("[{s}]\n", .{buffer[0..length]});

    return null;
}
