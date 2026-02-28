const Options = @This();

strictness: Strictness = .default,
verbosity: Verbosity = .default,
policies: Policies = .default,

pub const Strictness = enum {
    strict,
    normal,
    relaxed,
    const default: Strictness = .normal;
};

pub const Verbosity = enum {
    normal,
    quiet,
    const default: Verbosity = .normal;
};

pub const Policies = struct {
    pub const Policy = enum { permit, forbid };

    pub const default: Policies = .{
        .extension = .forbidAll,
        .smell = .forbidAll,
        .style = .forbidAll,
    };
    pub const config_laser: Policies = blk: {
        var policies: Policies = .default;
        policies.style.undesirable_integer_forms = .permit;
        break :blk policies;
    };
    pub const config_lace: Policies = blk: {
        var policies: Policies = .default;
        policies.extension.implicit_origin = .permit;
        policies.extension.implicit_end = .permit;
        policies.extension.label_declaration_colons = .permit;
        policies.style.missing_operand_commas = .permit;
        policies.style.whitespace_commas = .permit;
        break :blk policies;
    };

    extension: struct {
        implicit_origin: Policy,
        implicit_end: Policy,
        multiline_strings: Policy,
        more_integer_radixes: Policy,
        more_integer_forms: Policy,
        label_declaration_colons: Policy,

        pub const forbidAll = fillFields(@This(), .forbid);
        pub const permitAll = fillFields(@This(), .permit);
    },

    smell: struct {
        pc_offset_literals: Policy,

        pub const forbidAll = fillFields(@This(), .forbid);
        pub const permitAll = fillFields(@This(), .permit);
    },

    style: struct {
        undesirable_integer_forms: Policy,
        missing_operand_commas: Policy,
        whitespace_commas: Policy,
        // non_lowercase_instructions: Policy,
        // non_uppercase_directives: Policy,

        pub const forbidAll = fillFields(@This(), .forbid);
        pub const permitAll = fillFields(@This(), .permit);
    },

    fn fillFields(comptime T: type, comptime value: Policy) T {
        var filled: T = undefined;
        for (@typeInfo(T).@"struct".fields) |field|
            @field(filled, field.name) = value;
        return filled;
    }
};
