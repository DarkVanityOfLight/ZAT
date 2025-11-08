const std = @import("std");

pub const Variable = u32;
pub const Literal = i32;

pub inline fn isPositive(l: Literal) bool {
    return l > 0;
}

pub inline fn isNegative(l: Literal) bool {
    return l < 0;
}

pub inline fn variableFromLiteral(l: Literal) Variable {
    return @abs(l);
}
