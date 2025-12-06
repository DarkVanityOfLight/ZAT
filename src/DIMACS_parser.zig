const std = @import("std");
const CNF = @import("clauses.zig").CNF;
const Literal = @import("variables.zig").Literal;
const not = @import("variables.zig").not;
const LiteralSet = @import("datastructures/EpochDict.zig").LiteralEpochDict;

const TokenIterator = std.mem.TokenIterator;

const CNFMeta = struct { clauses: usize, variables: usize };

const NotCNFError = error{};
const NoPreamble = error{};
const InvalidHeaderFormat = error{
    NotCNFError,
    NoPreamble,
};

var literalSet: *LiteralSet = undefined;
var clause: std.array_list.Managed(Literal) = undefined;

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

fn parse_line(line: []const u8, cnf: *CNF) !bool {
    var content = std.mem.tokenizeAny(u8, line, " ");

    if (content.peek() == null) return false;
    if (std.mem.eql(u8, content.peek().?, "c")) return false;

    while (content.next()) |token| {
        if (std.mem.eql(u8, token, "0")) break;
        const lit = try std.fmt.parseInt(i32, token, 10);
        if (literalSet.containsLiteral(not(lit))) return true; // We have x and not x, this is a tautology
        literalSet.addLiteral(lit, undefined);
        try clause.append(lit);
    }

    try cnf.addClause(clause.items);
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

    literalSet = try LiteralSet.init(alloc, cnf.num_variables);
    defer literalSet.deinit();

    clause = std.array_list.Managed(Literal).init(alloc);
    defer clause.deinit();

    var clause_count: usize = 0;
    std.debug.print("{d}", .{cnf.num_clauses});
    while (lines.next()) |line| {
        if (clause_count >= cnf.num_clauses) {
            break;
        }
        const success = parse_line(line, cnf) catch |err| blk: {
            std.debug.print("{any} Could not parse line: {s}\n", .{ err, line });
            break :blk false;
        };
        if (success) {
            clause_count += 1;
        }
        literalSet.reset();
        clause.clearRetainingCapacity();
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

    const bufSize = (try f.stat()).size / @sizeOf(u8);
    const buf = try alloc.alloc(u8, bufSize);
    defer alloc.free(buf);

    var r = std.fs.File.Reader.init(f, buf);
    const d = try r.interface.readAlloc(alloc, try r.getSize());
    defer alloc.free(d);

    return try parse_dimacs(alloc, d);
}
