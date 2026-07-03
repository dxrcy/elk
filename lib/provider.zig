const std = @import("std");
const assert = std.debug.assert;

const Reporter = @import("reporting/reporting.zig").Primary;
const Air = @import("compile/Air.zig");
const Span = @import("compile/Span.zig");
const Operand = @import("compile/Operand.zig");
const Source = @import("compile/Source.zig");

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

    pub fn resolveOperand(
        provider: Provider,
        instruction: *Air.Instruction,
        address: usize,
        source: Source,
        reporter: *Reporter,
        comptime increment_references: bool,
    ) error{Reported}!void {
        if (increment_references)
            assert(provider == .assembly);
        return switch (instruction.*) {
            .br => |*operands| provider.resolveField(&operands.dest, address, source, reporter, increment_references),
            .jsr => |*operands| provider.resolveField(&operands.dest, address, source, reporter, increment_references),
            .ld => |*operands| provider.resolveField(&operands.src, address, source, reporter, increment_references),
            .ldi => |*operands| provider.resolveField(&operands.src, address, source, reporter, increment_references),
            .lea => |*operands| provider.resolveField(&operands.src, address, source, reporter, increment_references),
            .st => |*operands| provider.resolveField(&operands.dest, address, source, reporter, increment_references),
            .sti => |*operands| provider.resolveField(&operands.dest, address, source, reporter, increment_references),
            .call => |*operands| provider.resolveField(&operands.dest, address, source, reporter, increment_references),
            else => {},
        };
    }

    fn resolveField(
        provider: Provider,
        operand: anytype,
        address: usize,
        source: Source,
        reporter: *Reporter,
        comptime increment_references: bool,
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

        const offset = switch (provider) {
            .none => {
                // TODO: Report properly
                std.log.err("label operand cannot be resolved", .{});
                return error.Reported;
            },

            .assembly => |assembly| try resolveFieldAssembly(
                Int,
                operand.span,
                address,
                assembly,
                source,
                reporter,
                increment_references,
            ),
            .symbols => |symbols| try resolveFieldSymbols(Int, operand.span, address, symbols, source, reporter),
        };

        operand.value = .{ .resolved = .{ .integer = offset, .form = null } };
    }
};

fn resolveFieldAssembly(
    comptime Int: type,
    operand: Span,
    address: usize,
    assembly: Provider.Assembly,
    source: Source,
    reporter: *Reporter,
    comptime increment_references: bool,
) error{Reported}!Int {
    const string = operand.view(source);

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
                .reference = operand,
                .nearest = nearest,
                .definition_source = assembly.source,
            }).abort();
        };

    const definition_address = definition.index + assembly.air.origin;
    const offset = calculateOffset(Int, definition_address, address) orelse {
        try reporter.report(.offset_too_large, .{
            .reference = operand,
            .definition = definition.span,
            .offset = calculateOffset(i17, definition_address, address) orelse
                unreachable,
            .bits = @typeInfo(Int).int.bits,
            .definition_source = assembly.source,
        }).abort();
    };

    if (increment_references)
        definition.references += 1;

    return offset;
}

fn resolveFieldSymbols(
    comptime Int: type,
    operand: Span,
    address: usize,
    symbols: []const Provider.SymbolEntry,
    source: Source,
    reporter: *Reporter,
) error{Reported}!Int {
    const string = operand.view(source);

    // TODO: Provide suggestion for nearest match
    const definition = (Provider.getSymbolAddress(string, symbols) orelse {
        try reporter.report(.undefined_label, .{
            .reference = operand,
            .nearest = .none,
            .definition_source = .empty,
        }).abort();
    });

    return calculateOffset(Int, definition, address) orelse {
        // TODO: Report properly
        std.log.err("offset too large", .{});
        return error.Reported;
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
