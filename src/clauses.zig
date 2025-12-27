const std = @import("std");
const Literal = @import("variables.zig").Literal;

pub const Satisfiable = enum {
    sat,
    unsat,
    unknown,
};

pub const ClauseMeta = struct {
    start: usize,
    end: usize,
    capacity: usize,
    alive: bool,
    watch1: ?Literal,
    watch2: ?Literal,
};

pub const CNF = struct {
    num_clauses: usize,
    num_variables: usize,
    literals: std.ArrayList(Literal),
    clauses: std.ArrayList(*ClauseMeta),
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, num_clauses: usize, num_variables: usize) !CNF {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return CNF{
            .num_clauses = num_clauses,
            .num_variables = num_variables,
            .literals = try std.ArrayList(Literal).initCapacity(arena.allocator(), num_clauses * 2),
            .clauses = try std.ArrayList(*ClauseMeta).initCapacity(arena.allocator(), num_clauses * 2),
            .arena = arena,
        };
    }

    pub fn deinit(self: *CNF) void {
        self.literals.deinit(self.arena.allocator());
        self.clauses.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn addClause(self: *CNF, new_literals: []Literal, w1: ?Literal, w2: ?Literal) !*ClauseMeta {
        // 1. Store the literals
        const start = self.literals.items.len;
        try self.literals.appendSlice(self.arena.allocator(), new_literals);

        // 2. Allocate the metadata in the stable Arena
        const meta_ptr = try self.arena.allocator().create(ClauseMeta);

        meta_ptr.* = ClauseMeta{
            .start = start,
            .end = start + new_literals.len,
            .capacity = new_literals.len,
            .alive = true,
            .watch1 = w1,
            .watch2 = w2,
        };

        // 3. Keep track of the pointer in our list
        try self.clauses.append(self.arena.allocator(), meta_ptr);

        // 4. Return the pointer so the caller can give it to the Watcher
        return meta_ptr;
    }

    pub fn deleteClause(self: *CNF, clause_index: usize) void {
        self.clauses.items[clause_index].alive = false;
        self.num_clauses -= 1;
    }

    pub fn getClause(self: *CNF, cMeta: ClauseMeta) []Literal {
        return self.literals.items[cMeta.start..cMeta.end];
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
    pub fn aliveClausesMeta(self: *CNF) AliveClauseMetaIter {
        return AliveClauseMetaIter{ .cnf = self, .index = 0 };
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

const AliveClauseMetaIter = struct {
    cnf: *CNF,
    index: usize,

    fn findNext(self: *AliveClauseMetaIter, startIndex: usize) ?*ClauseMeta {
        var i = startIndex;
        while (i < self.cnf.clauses.items.len) : (i += 1) {
            const meta_ptr = &self.cnf.clauses.items[i];
            if (meta_ptr.alive) {
                return meta_ptr;
            }
        }
        return null;
    }

    pub fn next(self: *AliveClauseMetaIter) ?*ClauseMeta {
        while (self.index < self.cnf.clauses.items.len) {
            const meta_ptr = self.cnf.clauses.items[self.index];
            self.index += 1;
            if (meta_ptr.alive) {
                return meta_ptr;
            }
        }
        return null;
    }

    pub fn peek(self: *AliveClauseMetaIter) ?*ClauseMeta {
        return self.findNext(self.index);
    }
};
