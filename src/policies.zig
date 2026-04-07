const std = @import("std");
const assert = std.debug.assert;

pub const Policies = packed struct {
    pub const Policy = enum(u1) { permit, forbid };

    pub const none: Policies = .{
        .extension = .forbid_all,
        .smell = .forbid_all,
        .style = .forbid_all,
        .case_convention = .forbid_all,
    };

    pub const predefs = struct {
        pub const laser: Policies = blk: {
            var policies: Policies = .none;
            policies.style.undesirable_integer_forms = .permit;
            break :blk policies;
        };
        pub const lace: Policies = blk: {
            var policies: Policies = .none;
            policies.extension.stack_instructions = .permit;
            policies.extension.implicit_origin = .permit;
            policies.extension.implicit_end = .permit;
            policies.extension.label_definition_colons = .permit;
            policies.style.missing_operand_commas = .permit;
            policies.style.whitespace_commas = .permit;
            break :blk policies;
        };
    };

    extension: packed struct {
        stack_instructions: Policy,
        implicit_origin: Policy,
        implicit_end: Policy,
        multiline_strings: Policy,
        more_integer_radixes: Policy,
        more_integer_forms: Policy,
        label_definition_colons: Policy,
        multiple_labels: Policy,
        character_literals: Policy,

        pub const forbid_all = fillFields(@This(), .forbid);
        pub const permit_all = fillFields(@This(), .permit);
    },

    smell: packed struct {
        pc_offset_literals: Policy,
        explicit_trap_instructions: Policy,
        unknown_trap_vectors: Policy,
        unused_label_definitions: Policy,

        pub const forbid_all = fillFields(@This(), .forbid);
        pub const permit_all = fillFields(@This(), .permit);
    },

    style: packed struct {
        undesirable_integer_forms: Policy,
        missing_operand_commas: Policy,
        whitespace_commas: Policy,

        pub const forbid_all = fillFields(@This(), .forbid);
        pub const permit_all = fillFields(@This(), .permit);
    },

    case_convention: packed struct {
        mnemonics: Policy,
        directives: Policy,
        labels: Policy,
        registers: Policy,
        integers: Policy,

        pub const forbid_all = fillFields(@This(), .forbid);
        pub const permit_all = fillFields(@This(), .permit);
    },

    fn fillFields(comptime T: type, comptime value: Policy) T {
        var filled: T = undefined;
        for (@typeInfo(T).@"struct".fields) |field|
            @field(filled, field.name) = value;
        return filled;
    }

    pub fn get(policies: *const Policies, category: []const u8, item: []const u8) ?Policy {
        inline for (@typeInfo(Policies).@"struct".fields) |category_field| {
            if (std.mem.eql(u8, category_field.name, category)) {
                inline for (@typeInfo(category_field.type).@"struct".fields) |item_field| {
                    if (std.mem.eql(u8, item_field.name, item)) {
                        return @field(@field(policies, category_field.name), item_field.name);
                    }
                }
            }
        }
        return null;
    }

    pub fn set(policies: *Policies, category: []const u8, item: []const u8, policy: Policy) bool {
        inline for (@typeInfo(Policies).@"struct".fields) |category_field| {
            if (std.mem.eql(u8, category_field.name, category)) {
                inline for (@typeInfo(category_field.type).@"struct".fields) |item_field| {
                    if (std.mem.eql(u8, item_field.name, item)) {
                        @field(@field(policies, category_field.name), item_field.name) = policy;
                        return true;
                    }
                }
            }
        }
        return false;
    }

    pub fn unionWith(lhs: Policies, rhs: Policies) Policies {
        var result: Policies = .none;
        inline for (@typeInfo(Policies).@"struct".fields) |category| {
            inline for (@typeInfo(category.type).@"struct".fields) |item| {
                const lhs_item = lhs.get(category.name, item.name) orelse unreachable;
                const rhs_item = rhs.get(category.name, item.name) orelse unreachable;
                if (lhs_item == .permit or rhs_item == .permit)
                    assert(result.set(category.name, item.name, .permit) == true);
            }
        }
        return result;
    }

    pub fn parseList(string: []const u8) !Policies {
        var policies: Policies = .none;

        var words = std.mem.tokenizeScalar(u8, string, ',');
        while (words.next()) |word| {
            if (std.mem.cutPrefix(u8, word, "+")) |predef_name| {
                const predef = resolvePredef(predef_name) orelse
                    return error.InvalidPredefName;
                policies = policies.unionWith(predef);
                continue;
            }

            var segmentts = std.mem.tokenizeScalar(u8, word, '.');
            const category = segmentts.next() orelse
                return error.MalformedPolicyName;
            const item = segmentts.next() orelse
                return error.MalformedPolicyName;
            if (segmentts.next() != null)
                return error.MalformedPolicyName;

            if (!policies.set(category, item, .permit))
                return error.InvalidPolicyName;
        }

        return policies;
    }

    fn resolvePredef(name: []const u8) ?Policies {
        inline for (@typeInfo(predefs).@"struct".decls) |predef| {
            if (std.mem.eql(u8, predef.name, name))
                return @field(predefs, predef.name);
        }
        return null;
    }
};
