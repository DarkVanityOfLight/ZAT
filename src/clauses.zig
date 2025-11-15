const std = @import("std");
const Literal = @import("variables.zig").Literal;

pub const Satisfiable = enum {
    sat,
    unsat,
    unknown,
};

const ClausePosition = struct {
    start: usize,
    end: usize,
    capacity: usize,
    alive: bool,
};

pub const CNF = struct {
    allocator: std.mem.Allocator,
    num_clauses: usize,
    num_variables: usize,
    literals: std.ArrayList(Literal),
    clauses: std.ArrayList(ClausePosition),

    pub fn init(alloc: std.mem.Allocator, num_clauses: usize, num_variables: usize) !*CNF {
        const cnf = try alloc.create(CNF);

        cnf.* = CNF{
            .allocator = alloc,
            .num_clauses = num_clauses,
            .num_variables = num_variables,
            .literals = try std.ArrayList(Literal).initCapacity(alloc, num_variables * num_clauses),
            .clauses = try std.ArrayList(ClausePosition).initCapacity(alloc, num_clauses * 2),
        };
        return cnf;
    }

    pub fn deinit(self: *CNF) void {
        self.literals.deinit(self.allocator);
        self.clauses.deinit(self.allocator);
    }

    pub fn addClause(self: *CNF, new_literals: []Literal) !void {
        // append clause at the end of literals array
        const start = self.literals.items.len;
        try self.literals.appendSlice(self.allocator, new_literals);
        const pos = ClausePosition{
            .start = start,
            .end = start + new_literals.len,
            .capacity = new_literals.len,
            .alive = true,
        };
        try self.clauses.append(self.allocator, pos);
        self.num_clauses += 1;
    }

    pub fn deleteClause(self: *CNF, clause_index: usize) void {
        self.clauses.items[clause_index].alive = false;
        self.num_clauses -= 1;
    }

    pub fn modifyClause(self: *CNF, clause_index: usize, new_literals: []Literal) !void {
        var pos = self.clauses.items[clause_index];
        if (new_literals.len <= pos.capacity) {
            // overwrite in place
            std.mem.copy(Literal, self.literals.items[pos.start .. pos.start + new_literals.len], new_literals);
            pos.end = pos.start + new_literals.len;
            self.clauses.items[clause_index] = pos;
        } else {
            // append at end
            const start = self.literals.items.len;
            try self.literals.appendAll(new_literals);
            pos.start = start;
            pos.end = start + new_literals.len;
            pos.capacity = new_literals.len;
            pos.alive = true;
            self.clauses.items[clause_index] = pos;
        }
    }

    pub fn aliveClauses(self: *CNF) AliveClauseIter {
        return AliveClauseIter{ .cnf = self, .index = 0 };
    }

    pub fn toString(self: *CNF, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(allocator);

        var iter = self.aliveClauses();
        var clauseIndex: usize = 0;

        while (iter.next()) |clause| {
            try list.writer(allocator).print("Clause {d}: [", .{clauseIndex});

            var first = true;
            for (clause) |lit| {
                if (!first) {
                    try list.appendSlice(allocator, ", ");
                }
                first = false;
                try list.writer(allocator).print("{}", .{lit});
            }

            try list.appendSlice(allocator, "]\n");
            clauseIndex += 1;
        }

        return list.toOwnedSlice(allocator);
    }
};

const AliveClauseIter = struct {
    cnf: *CNF,
    index: usize,

    fn findNext(self: *AliveClauseIter, startIndex: usize) ?[]Literal {
        var i = startIndex;
        while (i < self.cnf.clauses.items.len) : (i += 1) {
            const pos = self.cnf.clauses.items[i];
            if (pos.alive) {
                return self.cnf.literals.items[pos.start..pos.end];
            }
        }
        return null;
    }

    pub fn next(self: *AliveClauseIter) ?[]Literal {
        while (self.index < self.cnf.clauses.items.len) {
            const pos = self.cnf.clauses.items[self.index];
            self.index += 1;
            if (pos.alive) {
                return self.cnf.literals.items[pos.start..pos.end];
            }
        }
        return null;
    }

    pub fn peek(self: *AliveClauseIter) ?[]Literal {
        return self.findNext(self.index);
    }
};
