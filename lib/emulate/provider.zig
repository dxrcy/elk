const std = @import("std");
const assert = std.debug.assert;

const Reporter = @import("../reporting/reporting.zig").Primary;
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

    pub fn resolveLabelOperand(
        provider: Provider,
        instruction: *Air.Instruction,
        index: usize,
        source: Source,
        reporter: *Reporter,
    ) error{Reported}!void {
        return switch (instruction.*) {
            .br => |*operands| provider.resolveFieldLabel(&operands.dest, index, source, reporter),
            .jsr => |*operands| provider.resolveFieldLabel(&operands.dest, index, source, reporter),
            .ld => |*operands| provider.resolveFieldLabel(&operands.src, index, source, reporter),
            .ldi => |*operands| provider.resolveFieldLabel(&operands.src, index, source, reporter),
            .lea => |*operands| provider.resolveFieldLabel(&operands.src, index, source, reporter),
            .st => |*operands| provider.resolveFieldLabel(&operands.dest, index, source, reporter),
            .sti => |*operands| provider.resolveFieldLabel(&operands.dest, index, source, reporter),
            .call => |*operands| provider.resolveFieldLabel(&operands.dest, index, source, reporter),
            else => {},
        };
    }

    fn resolveFieldLabel(
        provider: Provider,
        operand: anytype,
        index: usize,
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

        const assembly = switch (provider) {
            .assembly => |assembly| assembly,
            // TODO:
            .symbols => unreachable,
            .none => unreachable,
        };

        const string = operand.span.view(source);

        const definition =
            assembly.air.findLabel(.exact, string, assembly.source) orelse {
                const nearest: Reporter.Diagnostic.NearestSpan =
                    if (assembly.air.findLabel(.nearest, string, assembly.source)) |label|
                        if (std.ascii.eqlIgnoreCase(string, label.span.view(assembly.source)))
                            .{ .case_insensitive = label.span }
                        else
                            .{ .edit_distance = label.span }
                    else
                        .none;
                try reporter.report(.undefined_label, .{
                    .reference = operand.span,
                    .nearest = nearest,
                    .definition_source = assembly.source,
                }).abort();
            };

        const offset = calculateOffset(Int, definition.index, index) orelse {
            try reporter.report(.offset_too_large, .{
                .reference = operand.span,
                .definition = definition.span,
                .offset = calculateOffset(i17, definition.index, index) orelse
                    unreachable,
                .bits = @typeInfo(Int).int.bits,
                .definition_source = assembly.source,
            }).abort();
        };

        definition.references += 1;
        operand.value = .{ .resolved = .{ .integer = offset, .form = null } };
    }
};

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
