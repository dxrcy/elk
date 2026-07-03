const std = @import("std");

const Air = @import("../compile/Air.zig");
const Source = @import("../compile/Source.zig");

pub const Provider = union(enum) {
    none,
    assembly: Assembly,
    symbols: []const SymbolEntry,

    pub const Assembly = struct {
        air: *const Air,
        source: Source,
    };

    pub const SymbolEntry = struct {
        address: u16,
        name: []const u8,
    };

    pub fn getSymbolAddress(name: []const u8, symbols: []const SymbolEntry) ?u16 {
        for (symbols) |entry| {
            if (std.mem.eql(u8, entry.name, name))
                return entry.address;
        }
        return null;
    }

    pub fn getSymbolName(address: u16, symbols: []const SymbolEntry) ?[]const u8 {
        for (symbols) |entry| {
            if (entry.address == address)
                return entry.name;
        }
        return null;
    }
};
