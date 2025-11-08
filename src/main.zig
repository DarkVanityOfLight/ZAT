const std = @import("std");
const ZAT = @import("ZAT");

const Clauses = @import("clauses.zig");
const DIMACS = @import("DIMACS_parser.zig");

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try ZAT.bufferedPrint();
}

test "parse dimacs" {
    const allocator = std.testing.allocator;

    const t = "p cnf 2 2\nc foo \n1 0\n-1\n";
    const cnf = try DIMACS.parse_dimacs(allocator, t);
    cnf.deinit();
    allocator.destroy(cnf);
}
