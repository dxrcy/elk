const Source = @This();

text: []const u8,
path: ?[]const u8,

pub const empty: Source = .{ .text = "", .path = null };
