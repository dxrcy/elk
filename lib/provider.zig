const std = @import("std");
const assert = std.debug.assert;

const elk = @import("root.zig");
const Span = elk.Span;
const Source = elk.Source;
const Reporter = elk.reporting.Primary;
const Air = elk.Air;
const Operand = elk.Air.Instruction.Operand;

pub const Provider = union(enum) {
    none,
    assembly: Assembly,
    symbols: Symbols,

    pub const Assembly = struct {
        air: *const Air,
        source: Source,
    };

    pub const Symbols = struct {
        items: []const Entry,
        pub const Entry = struct {
            address: u16,
            name: []const u8,
        };

        pub fn getAddress(symbols: Symbols, name: []const u8) ?u16 {
            for (symbols.items) |entry| {
                if (std.mem.eql(u8, entry.name, name))
                    return entry.address;
            }
            return null;
        }

        pub fn getName(symbols: Symbols, address: u16) ?[]const u8 {
            for (symbols.items) |entry| {
                if (entry.address == address)
                    return entry.name;
            }
            return null;
        }
    };

    /// Also increments reference count of definition, when using `Assembly` provider.
    pub fn resolveOperand(
        provider: Provider,
        instruction: *Air.Instruction,
        address: usize,
        source: Source,
        reporter: *Reporter,
    ) error{Reported}!void {
        return switch (instruction.*) {
            .br => |*operands| provider.resolveField(&operands.dest, address, source, reporter),
            .jsr => |*operands| provider.resolveField(&operands.dest, address, source, reporter),
            .ld => |*operands| provider.resolveField(&operands.src, address, source, reporter),
            .ldi => |*operands| provider.resolveField(&operands.src, address, source, reporter),
            .lea => |*operands| provider.resolveField(&operands.src, address, source, reporter),
            .st => |*operands| provider.resolveField(&operands.dest, address, source, reporter),
            .sti => |*operands| provider.resolveField(&operands.dest, address, source, reporter),
            .call => |*operands| provider.resolveField(&operands.dest, address, source, reporter),
            else => {},
        };
    }

    fn resolveField(
        provider: Provider,
        operand: anytype,
        address: usize,
        source: Source,
        reporter: *Reporter,
    ) error{Reported}!void {
        // Extract integer type from operand argument type
        const Spanned = @typeInfo(@TypeOf(operand)).pointer.child;
        const Value = @FieldType(Spanned, "value");
        const Formed = @FieldType(Value, "resolved");
        const Int = @FieldType(Formed, "integer");

        switch (operand.value) {
            .unresolved => {},
            .resolved => return,
        }

        const definition = try provider.resolveAbsolute(operand.span, source, reporter);

        const offset = calculateOffset(Int, definition, address) orelse {
            try reporter.report(.offset_too_large, .{
                .reference = operand.span,
                // TODO:
                .definition = .fromBounds(0, 0),
                .offset = calculateOffset(i17, definition, address) orelse
                    unreachable,
                .bits = @typeInfo(Int).int.bits,
                .definition_source = source,
            }).abort();
        };

        operand.value = .{ .resolved = .{ .integer = offset, .form = null } };
    }

    /// Also increments reference count of definition, when using `Assembly` provider.
    pub fn resolveAbsolute(
        provider: Provider,
        operand: Span,
        source: Source,
        reporter: *Reporter,
    ) error{Reported}!u16 {
        return switch (provider) {
            .none => {
                // TODO: Report properly
                std.log.err("label operand cannot be resolved", .{});
                return error.Reported;
            },
            .assembly => |assembly| try resolveAssemblyAbsolute(operand, assembly, source, reporter),
            .symbols => |symbols| try resolveSymbolAbsolute(operand, symbols, source, reporter),
        };
    }
};

fn resolveAssemblyAbsolute(
    operand: Span,
    assembly: Provider.Assembly,
    source: Source,
    reporter: *Reporter,
) error{Reported}!u16 {
    const string = operand.view(source);

    const definition = blk: {
        const nearest: Reporter.Diagnostic.NearestSpan =
            switch (assembly.air.findLabel(string, assembly.source)) {
                .exact => |label| break :blk label,
                .case_insensitive => |label| .{ .case_insensitive = label.span },
                .edit_distance => |label| .{ .edit_distance = label.span },
                .none => .none,
            };
        try reporter.report(.undefined_label, .{
            .reference = operand,
            .nearest = nearest,
            .definition_source = assembly.source,
        }).abort();
    };

    definition.references += 1;
    return definition.index + assembly.air.origin;
}

fn resolveSymbolAbsolute(
    operand: Span,
    symbols: Provider.Symbols,
    source: Source,
    reporter: *Reporter,
) error{Reported}!u16 {
    const string = operand.view(source);

    // TODO: Provide suggestion for nearest match
    return symbols.getAddress(string) orelse {
        try reporter.report(.undefined_label, .{
            .reference = operand,
            .nearest = .none,
            .definition_source = .empty,
        }).abort();
    };
}

fn calculateOffset(comptime T: type, definition: usize, reference: usize) ?T {
    comptime assert(@typeInfo(T).int.signedness == .signed);
    return std.math.cast(
        T,
        std.math.sub(
            isize,
            @intCast(definition),
            @intCast(reference),
        ) catch
            return null,
    );
}
