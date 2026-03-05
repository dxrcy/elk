const Policies = @This();

pub const Policy = enum { permit, forbid };

pub const default: Policies = .{
    .extension = .forbid_all,
    .smell = .forbid_all,
    .style = .forbid_all,
};
pub const config_laser: Policies = blk: {
    var policies: Policies = .default;
    policies.style.undesirable_integer_forms = .permit;
    break :blk policies;
};
pub const config_lace: Policies = blk: {
    var policies: Policies = .default;
    policies.extension.stack_instructions = .permit;
    policies.extension.implicit_origin = .permit;
    policies.extension.implicit_end = .permit;
    policies.extension.label_declaration_colons = .permit;
    policies.style.missing_operand_commas = .permit;
    policies.style.whitespace_commas = .permit;
    break :blk policies;
};

extension: struct {
    stack_instructions: Policy,
    implicit_origin: Policy,
    implicit_end: Policy,
    multiline_strings: Policy,
    more_integer_radixes: Policy,
    more_integer_forms: Policy,
    label_declaration_colons: Policy,

    pub const forbid_all = fillFields(@This(), .forbid);
    pub const permit_all = fillFields(@This(), .permit);
},

smell: struct {
    pc_offset_literals: Policy,
    explicit_trap_instructions: Policy,
    unknown_trap_vectors: Policy,

    pub const forbid_all = fillFields(@This(), .forbid);
    pub const permit_all = fillFields(@This(), .permit);
},

style: struct {
    undesirable_integer_forms: Policy,
    missing_operand_commas: Policy,
    whitespace_commas: Policy,
    unconventional_case_instructions: Policy,
    unconventional_case_directives: Policy,
    unconventional_case_labels: Policy,
    unconventional_case_registers: Policy,
    unconventional_case_integers: Policy,

    pub const forbid_all = fillFields(@This(), .forbid);
    pub const permit_all = fillFields(@This(), .permit);
},

fn fillFields(comptime T: type, comptime value: Policy) T {
    var filled: T = undefined;
    for (@typeInfo(T).@"struct".fields) |field|
        @field(filled, field.name) = value;
    return filled;
}
