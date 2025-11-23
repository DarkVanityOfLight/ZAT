const std = @import("std");

const ZAT = @import("ZAT");
const Clauses = ZAT.Clauses;
const DIMACS = ZAT.DIMACS;

const zli = @import("zli");

pub fn run(ctx: zli.CommandContext) !void {
    const file_path = ctx.getArg("DIMACS_CNF") orelse {
        try ctx.writer.print("No file provided\n", .{});
        return;
    };

    const gpa = std.heap.page_allocator;
    const cnf = try DIMACS.read_dimacs(gpa, file_path);

    const res = try ZAT.DPLL.dpll(gpa, cnf);

    switch (res) {
        .sat => |assignment| {
            _ = try ctx.writer.write("s SATSIFIABLE\n");

            _ = try ctx.writer.write("v ");
            for (assignment, 0..) |v, i| {
                if (i != 0) _ = try ctx.writer.write(" ");
                try ctx.writer.print("{d}", .{v});
            }
            gpa.free(assignment);
            _ = try ctx.writer.print("\n", .{});
        },
        .unsat => _ = try ctx.writer.write("s UNSATISFIABLE\n"),
        .unknown => _ = try ctx.writer.write("s UNKNOWN\n"),
    }

    try ctx.writer.flush();
}
