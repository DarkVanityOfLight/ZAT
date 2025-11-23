const Literal = @import("variables.zig").Literal;

pub const Result = union(enum) {
    sat: []Literal,
    unsat,
    unknown,
};
