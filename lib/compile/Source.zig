const Source = @This();

text: []const u8,
path: ?Path,

pub const Path = struct {
    original: []const u8,
    display: []const u8,
};

pub const empty: Source = .{
    .text = "",
    .path = null,
};
