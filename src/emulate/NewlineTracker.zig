const NewlineTracker = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

is_newline: bool,
inner: *Io.Writer,
interface: Io.Writer,

pub fn new(inner: *Io.Writer) NewlineTracker {
    return .{
        .is_newline = true,
        .inner = inner,
        .interface = .{
            .vtable = &.{
                .drain = drain,
            },
            .buffer = &.{},
        },
    };
}

fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const writer: *NewlineTracker = @alignCast(@fieldParentPtr("interface", io_w));

    assert(data.len <= 1);
    if (data.len == 0)
        return 0;

    const count = try writer.inner.vtable.drain(writer.inner, data, splat);
    if (count > 0) {
        const index = (count / splat) - 1; // Probably correct
        writer.is_newline = data[0][index] == '\n';
    }
    return count;
}

pub fn ensureNewline(writer: *NewlineTracker) Io.Writer.Error!void {
    if (!writer.is_newline)
        try writer.interface.writeByte('\n');
}
