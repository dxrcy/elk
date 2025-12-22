const std = @import("std");
const fs = std.fs;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("Tokenizer.zig");
const utils = @import("utils.zig");
const Token = @import("tokens.zig").Token;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "hw.asm";

    const flags: fs.File.OpenFlags = .{};
    const file = try fs.cwd().openFile(path, flags);

    var text = try utils.readFile(file, allocator);
    defer text.deinit(allocator);

    var lines = std.mem.tokenizeAny(u8, text.items, "\r\n");
    while (lines.next()) |line| {
        std.debug.print("-" ** 20 ++ "\n", .{});
        std.debug.print("[{s}]\n", .{line});

        var tokens = Tokenizer.new(line);
        while (tokens.next()) |string| {
            std.debug.print("\t[{s}]", .{string});
            if (Token.from(string)) |token| {
                std.debug.print("\t{f}\n", .{token});
            } else |err| {
                std.debug.print("\tERROR: {t}\n", .{err});
            }
        }

        std.debug.print("\n", .{});
    }
}
