const Options = @This();

strictness: Strictness = .normal,
verbosity: Verbosity = .normal,
features: Features = .{
    .extension = .none,
    .smells = .none,
    .style = .none,
},

pub const Strictness = enum {
    strict,
    normal,
    relaxed,
};

pub const Verbosity = enum {
    verbose,
    normal,
    quiet,
};

// TODO: Rename. This is more broad than just "features"
// TODO: Rename boolean fields to be consistent. Remove "allow". Maybe replace bool with enum
pub const Features = struct {
    extension: struct {
        implicit_origin: bool,
        implicit_end: bool,
        multiline_strings: bool,
        more_integer_radixes: bool,
        more_integer_forms: bool,
        label_colons: bool,

        pub const none = fillFields(@This(), false);
        pub const all = fillFields(@This(), true);
    },

    smells: struct {
        allow_literal_pc_offset: bool,

        pub const none = fillFields(@This(), false);
        pub const all = fillFields(@This(), true);
    },

    style: struct {
        allow_undesirable_integer_forms: bool,
        allow_missing_operand_commas: bool,
        allow_whitespace_commas: bool,

        pub const none = fillFields(@This(), false);
        pub const all = fillFields(@This(), true);
    },

    fn fillFields(comptime T: type, comptime value: bool) T {
        var filled: T = undefined;
        for (@typeInfo(T).@"struct".fields) |field|
            @field(filled, field.name) = value;
        return filled;
    }
};
