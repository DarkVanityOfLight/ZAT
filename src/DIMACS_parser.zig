const std = @import("std");
const CNF = @import("clauses.zig").CNF;
const Literal = @import("variables.zig").Literal;
const not = @import("variables.zig").not;

const TokenIterator = std.mem.TokenIterator;

const CNFMeta = struct { clauses: usize, variables: usize };

const NotCNFError = error{};
const NoPreamble = error{};
const InvalidHeaderFormat = error{
    NotCNFError,
    NoPreamble,
};

// FIXME: Does not accept comments as first line

fn parse_first_line(line: []const u8) !CNFMeta {
    var tokens = std.mem.tokenizeAny(u8, line, " ");

    if (tokens.peek() == null) return error.NoPreamble;
    const starts_with_p = std.mem.eql(u8, tokens.next().?, "p");
    if (!starts_with_p) {
        return error.NoPreamble;
    }

    if (tokens.peek() == null) return error.NoPreamble;
    const is_cnf = std.mem.eql(u8, tokens.next().?, "cnf");
    if (!is_cnf) {
        return error.NoPreamble;
    }

    if (tokens.peek() == null) return error.NoPreamble;
    const num_variables = try std.fmt.parseInt(usize, tokens.next().?, 10);
    if (tokens.peek() == null) return error.NoPreamble;
    const num_clauses = try std.fmt.parseInt(usize, tokens.next().?, 10);

    return CNFMeta{ .clauses = num_clauses, .variables = num_variables };
}

fn parse_line(alloc: std.mem.Allocator, line: []const u8, cnf: *CNF) !bool {
    var content = std.mem.tokenizeAny(u8, line, " ");

    if (content.peek() == null) return false;
    if (std.mem.eql(u8, content.peek().?, "c")) return false;

    var literals = std.AutoHashMap(Literal, void).init(alloc);
    defer literals.deinit();

    while (content.next()) |token| {
        if (std.mem.eql(u8, token, "0")) break;
        const lit = try std.fmt.parseInt(i32, token, 10);
        if (literals.contains(not(lit))) return true; // We have x and not x, this is a tautology
        try literals.put(lit, {});
    }

    const keys = try alloc.alloc(i32, literals.count());
    defer alloc.free(keys);

    var it = literals.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) {
        keys[i] = k.*;
    }
    try cnf.addClause(keys);
    return true;
}

pub fn parse_dimacs(alloc: std.mem.Allocator, content: []const u8) !*CNF {
    var lines = std.mem.tokenizeAny(u8, content, "\n");
    if (lines.peek() == null) return error.NoPreamble;

    var line_opt = lines.next();
    while (line_opt) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " ");
        if (tokens.peek() == null or std.mem.eql(u8, tokens.peek().?, "c")) {
            line_opt = lines.next();
            continue;
        }
        break;
    }

    const cnf_meta = try parse_first_line(line_opt.?);

    const cnf = try CNF.init(
        alloc,
        cnf_meta.clauses,
        cnf_meta.variables,
    );

    var clause_count: usize = 0;
    while (lines.next()) |line| {
        if (clause_count >= cnf.num_clauses) {
            break;
        }
        const success = parse_line(alloc, line, cnf) catch |err| blk: {
            std.debug.print("{any} Could not parse line: {s}\n", .{ err, line });
            break :blk false;
        };
        if (success) {
            clause_count += 1;
        }
    }

    return cnf;
}

pub fn read_dimacs(
    alloc: std.mem.Allocator,
    file: []const u8,
) !*CNF {
    const arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const f = try std.fs.cwd().openFile(file, .{ .mode = .read_only });
    defer f.close();

    const data = try f.readToEndAlloc(alloc, 1_000_000);
    return try parse_dimacs(alloc, data);
}
