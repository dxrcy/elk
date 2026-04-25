const Air = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Runtime = @import("../emulate/Runtime.zig");
const Span = @import("Span.zig");
const Source = @import("Source.zig");
pub const Instruction = @import("instruction.zig").Instruction;

origin: u16,
lines: ArrayList(Line),
labels: ArrayList(Label),

pub const Label = struct {
    /// Index in `lines`. `address - offset`.
    index: u16,
    span: Span,
    references: usize,
    kind: Kind,

    pub fn new(index: u16, span: Span, string: []const u8) Label {
        return .{
            .index = index,
            .span = span,
            .references = 0,
            .kind = .from(string),
        };
    }

    pub const Kind = enum {
        normal,
        breakpoint,
        pub fn from(string: []const u8) Kind {
            return if (std.mem.startsWith(u8, string, "__")) .breakpoint else .normal;
        }
    };
};

pub const Line = struct {
    span: Span,
    statement: Statement,
};

pub const Statement = union(enum) {
    raw_word: u16,
    instruction: Instruction,

    pub fn encode(statement: Statement) u16 {
        return switch (statement) {
            .raw_word => |raw| raw,
            .instruction => |instruction| instruction.encode(),
        };
    }
};

pub fn init() Air {
    return .{
        .origin = 0x3000,
        .lines = .empty,
        .labels = .empty,
    };
}

pub fn deinit(air: *Air, gpa: Allocator) void {
    air.lines.deinit(gpa);
    air.labels.deinit(gpa);
}

pub fn copyToRuntime(air: *const Air, runtime: *Runtime) !void {
    assert(air.lines.items.len <= 0xffff);

    runtime.state.pc = air.origin;
    for (air.lines.items, 0..) |line, i| {
        const raw = line.statement.encode();
        runtime.state.memory[air.origin + i] = raw;
    }
}

pub fn writeAssembly(air: *const Air, writer: *Io.Writer) !void {
    assert(air.lines.items.len <= 0xffff);

    try writer.writeInt(u16, air.origin, .big);
    for (air.lines.items) |line| {
        const raw = line.statement.encode();
        try writer.writeInt(u16, raw, .big);
    }
}

pub fn writeSymbols(air: *const Air, writer: *Io.Writer, source: Source) !void {
    for (air.labels.items) |label| {
        try writer.print("{s:<74} x{x:04}\n", .{
            label.span.view(source),
            air.origin + label.index,
        });
    }
}

pub fn writeListing(air: *const Air, writer: *Io.Writer, source: Source) !void {
    const helper: ListingHelper = .{ .writer = writer };
    try helper.writeHeader();

    var index: usize = 0;
    var line_no: usize = 1;

    // Cut just 1 trailing newline
    const source_trimmed = std.mem.cutSuffix(u8, source.text, "\n") orelse source.text;
    var lines = std.mem.splitScalar(u8, source_trimmed, '\n');

    while (lines.next()) |string| : (line_no += 1) {
        const end = @intFromPtr(string.ptr) - @intFromPtr(source_trimmed.ptr) + string.len;

        // If source line corresponds to >0 statements, print the first one here
        if (index < air.lines.items.len and
            air.lines.items[index].span.offset <= end)
        {
            try helper.writeAddress(@intCast(air.origin + index));
            try helper.writeValue(air.lines.items[index].statement.encode());
            index += 1;
        } else {
            try helper.writeAddress(null);
            try helper.writeValue(null);
        }

        try helper.writeLine(@intCast(line_no), string);

        // If source line corresponds to >1 statement, print the rest here
        // Eg. `.STRINGZ` emits multiple words
        while (index < air.lines.items.len and
            air.lines.items[index].span.end() <= end)
        {
            const word = air.lines.items[index].statement.encode();
            try helper.writeAddress(null);
            try helper.writeValue(word);
            try helper.writeLine(null, null);
            index += 1;
        }
    }
}

const ListingHelper = struct {
    writer: *Io.Writer,

    fn writeHeader(helper: ListingHelper) !void {
        try helper.writer.writeAll("  ADDR  |  HEX  |      BINARY      |  LN  |  ASSEMBLY\n");
    }

    fn writeAddress(helper: ListingHelper, address_opt: ?u16) !void {
        if (address_opt) |address|
            try helper.writer.print(" x{X:04}", .{address})
        else
            try helper.writer.print("  {s:4}", .{""});
    }

    fn writeValue(helper: ListingHelper, word_opt: ?u16) !void {
        if (word_opt) |word|
            try helper.writer.print("  | x{X:04} | {b:016}", .{ word, word })
        else
            try helper.writer.print("  |  {s:4} | {s:16}", .{ "", "" });
    }

    fn writeLine(helper: ListingHelper, line_no_opt: ?u16, string_opt: ?[]const u8) !void {
        if (string_opt) |string| {
            const line_no = line_no_opt orelse unreachable;
            try helper.writer.print(" | {:4} | {s}\n", .{ line_no, string });
        } else {
            assert(line_no_opt == null);
            try helper.writer.print(" | {s:4} |\n", .{""});
        }
    }
};

pub fn patchLabelValue(
    air: *Air,
    name: []const u8,
    raw_word: u16,
    source: Source,
) error{LabelNotFound}!void {
    for (air.labels.items) |label| {
        if (!std.mem.eql(u8, label.span.view(source), name))
            continue;
        // Keep span
        air.lines.items[label.index].statement = .{ .raw_word = raw_word };
        return;
    }
    return error.LabelNotFound;
}

pub fn findLabel(
    air: *const Air,
    reference: []const u8,
    case_mode: enum { sensitive, insensitive },
    source: Source,
) ?*Label {
    assertLabelOrder(air);
    for (air.labels.items) |*label| {
        const string = label.span.view(source);
        const matches = switch (case_mode) {
            .sensitive => std.mem.eql(u8, string, reference),
            .insensitive => std.ascii.eqlIgnoreCase(string, reference),
        };
        if (matches)
            return label;
    }
    return null;
}

pub fn assertLabelOrder(air: *const Air) void {
    var i: usize = 0;
    while (i + 1 < air.labels.items.len) : (i += 1) {
        const first = air.labels.items[i];
        const second = air.labels.items[i + 1];
        assert(first.index <= second.index);
    }
}
