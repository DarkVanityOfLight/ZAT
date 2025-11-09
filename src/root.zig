//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const DIMACS = @import("DIMACS_parser.zig");
pub const Clauses = @import("clauses.zig");
pub const Variables = @import("variables.zig");
