const std = @import("std");

const ZAT = @import("ZAT");
const Clauses = ZAT.Clauses;
const DIMACS = ZAT.DIMACS;
const DRAT_Proof = ZAT.DRAT_Proof;
const Literal = ZAT.Variables.Literal;

const zli = @import("zli");

pub fn run(ctx: zli.CommandContext) !void {
    const gpa = std.heap.page_allocator;
    const stdout = ctx.writer; // Alias for readability

    const dimacs_path = ctx.getArg("DIMACS_CNF") orelse {
        try stdout.print("Error: No DIMACS file provided\n", .{});
        return;
    };

    var timer = try std.time.Timer.start();

    // Parsing
    const cnf = try DIMACS.readDimacs(gpa, dimacs_path);
    try stdout.print("c Finished parsing in {d} ms\n", .{timer.lap() / std.time.ns_per_ms});

    // DRAT Setup
    var drat_file: ?std.fs.File = blk: {
        const path = ctx.flag("DRAT_PROOF", []const u8);
        if (std.mem.eql(u8, "", path)) {
            break :blk null;
        }
        break :blk try std.fs.cwd().createFile(path, .{});
    };
    defer if (drat_file) |*f| f.close();

    var buf: [4096]u8 = undefined;
    var drat_bw = if (drat_file) |f| f.writer(&buf) else null;
    defer if (drat_bw) |*w| w.interface.flush() catch {};

    var proof = DRAT_Proof.Proof{
        .writer = if (drat_bw) |*w| &w.interface else null,
    };

    // Solving
    const res = try ZAT.DPLL.dpll(gpa, cnf, &proof);

    // Reporting
    switch (res) {
        .sat => |assignment| {
            defer gpa.free(assignment);
            std.mem.sort(Literal, assignment, {}, comptime std.sort.asc(i32));

            try stdout.writeAll("s SATISFIABLE\n");
            try stdout.writeAll("v");
            for (assignment) |v| try stdout.print(" {d}", .{v});
            try stdout.writeAll("\n");
        },
        .unsat => {
            try stdout.writeAll("s UNSATISFIABLE\n");
            try proof.addClause(&[_]Literal{});
        },
        .unknown => try stdout.writeAll("s UNKNOWN\n"),
    }

    try stdout.print("c Finished solving in {d} ms\n", .{timer.lap() / std.time.ns_per_ms});
    try stdout.flush();
}
