const Literal = @import("variables.zig").Literal;
const Proof = @import("DRAT_proof.zig").Proof;

pub const Result = union(enum) {
    sat: []Literal,
    unsat: Proof,
    unknown,
};
