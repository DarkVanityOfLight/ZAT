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

    const allocator = std.heap.page_allocator;
    const cnf = try DIMACS.read_dimacs(allocator, file_path);

    // Do something with cnf
    try ctx.writer.print("Loaded CNF from {s}\n", .{file_path});

    const str = try cnf.toString(allocator);
    defer allocator.free(str);

    _ = try ctx.writer.write(str);
    try ctx.writer.flush();
}
