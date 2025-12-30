const std = @import("std");
const CNF = @import("clauses.zig").CNF;
const Literal = @import("variables.zig").Literal;
const not = @import("variables.zig").not;

const LiteralEpochDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;

const LiteralSet = LiteralEpochDict(void);
const CNFMeta = struct { clauses: usize, variables: usize };

fn parseFirstLine(line: []const u8) !CNFMeta {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");

    if (tokens.peek() == null) return error.NoPreamble;
    const starts_with_p = std.mem.eql(u8, tokens.next().?, "p");
    if (!starts_with_p) return error.NoPreamble;

    if (tokens.peek() == null) return error.NoPreamble;
    const is_cnf = std.mem.eql(u8, tokens.next().?, "cnf");
    if (!is_cnf) return error.NoPreamble;

    if (tokens.peek() == null) return error.NoPreamble;
    const num_variables = try std.fmt.parseInt(usize, tokens.next().?, 10);

    if (tokens.peek() == null) return error.NoPreamble;
    const num_clauses = try std.fmt.parseInt(usize, tokens.next().?, 10);

    return CNFMeta{ .clauses = num_clauses, .variables = num_variables };
}

fn parseLine(line: []const u8, cnf: *CNF, lit_set: *LiteralSet, clause_buf: *std.array_list.Managed(Literal)) !bool {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");

    // Check for comment or empty line
    if (tokens.peek() == null) return false;
    if (std.mem.eql(u8, tokens.peek().?, "c")) return false;

    // Reset the set and buffer for the new line
    lit_set.reset();
    clause_buf.clearRetainingCapacity();

    var is_tautology = false;

    while (tokens.next()) |token| {
        // '0' marks the end of a line in DIMACS
        if (std.mem.eql(u8, token, "0")) break;

        const lit = try std.fmt.parseInt(i32, token, 10);

        // 1. Check Tautology: Clause contains both L and -L
        // A tautology is always true, so we can skip adding this clause entirely.
        if (lit_set.contains(not(lit))) {
            is_tautology = true;
            // We continue parsing just to ensure the line format is valid,
            // or we could break immediately.
        }

        // 2. Check Duplicate: Clause contains L twice
        // A v A == A. We just skip adding it the second time.
        if (!lit_set.contains(lit)) {
            lit_set.set(lit, {}); // Add to set (value is void)
            try clause_buf.append(lit);
        }
    }

    // If it's a tautology, we count it as "parsed" (return true),
    // but we DO NOT add it to the CNF database.
    if (is_tautology) return true;

    // Only add if not empty (lines with just '0' are technically empty clauses -> UNSAT,
    // but usually parser artifacts)
    _ = try cnf.addClause(
        clause_buf.items,
        null,
        null,
        null,
    );

    return true;
}

pub fn parseDimacs(alloc: std.mem.Allocator, content: []const u8) !CNF {
    var lines = std.mem.tokenizeAny(u8, content, "\n\r");

    // 1. Find the preamble (p cnf ...)
    var line_opt = lines.next();
    while (line_opt) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const first = tokens.peek();
        // Skip empty lines or comments
        if (first == null or std.mem.eql(u8, first.?, "c")) {
            line_opt = lines.next();
            continue;
        }
        break;
    }

    if (line_opt == null) return error.NoPreamble;
    const cnf_meta = try parseFirstLine(line_opt.?);

    var cnf = try CNF.init(
        alloc,
        cnf_meta.clauses,
        cnf_meta.variables,
    );
    errdefer cnf.deinit();

    // 2. Initialize Helper Structures
    // We instantiate them here to avoid global state
    var lit_set = try LiteralSet.init(alloc, cnf.num_variables);
    defer lit_set.deinit();

    var clause_buf = std.array_list.Managed(Literal).init(alloc);
    defer clause_buf.deinit();

    // 3. Parse Clauses
    var clauses_found: usize = 0;
    while (lines.next()) |line| {
        // Some files have more lines than declared in preamble; stop if we hit limit
        // (Optional: strict parsers might error, lax parsers ignore extra)
        if (clauses_found >= cnf.num_clauses) {
            break;
        }

        const success = parseLine(line, &cnf, &lit_set, &clause_buf) catch |err| {
            std.debug.print("Error parsing line: {s} ({any})\n", .{ line, err });
            return err;
        };

        if (success) {
            clauses_found += 1;
        }
    }

    return cnf;
}

pub fn readDimacs(
    alloc: std.mem.Allocator,
    file_path: []const u8,
) !CNF {
    const f = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer f.close();

    // readToEndAlloc is safer and cleaner than manual stat/read
    // We add +1 for null terminator just in case, though not strictly needed for logic
    const content = try f.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(content);

    return try parseDimacs(alloc, content);
}
