const std = @import("std");
const Literal = @import("variables.zig").Literal;
const Watcher = @import("Watcher.zig");

pub const LearnedInfo = struct {
    lbd: usize,
};

pub const ClauseType = union(enum) { learned: LearnedInfo, fixed };

pub const ClauseMeta = struct {
    start: usize,
    end: usize,
    capacity: usize,
    alive: bool,
    watch1: ?Literal,
    watch2: ?Literal,
    clauseType: ClauseType,
    locked: bool, // Is this clause currently part of a conflict on the trail
};

/// The list clauses/literals list should be organized like this:
/// 0..fixed_index contains all fixed clauses
/// then follwed by all learned clauses
/// fixed_index..len-1
///
pub const CNF = struct {
    num_fixed_clauses: usize,
    num_learned_clauses: usize,
    num_variables: usize,
    literals: std.ArrayList(Literal),
    clauses: std.ArrayList(*ClauseMeta),
    arena: std.heap.ArenaAllocator,
    fixed_index: usize,

    pub fn init(gpa: std.mem.Allocator, num_clauses: usize, num_variables: usize) !CNF {
        var arena = std.heap.ArenaAllocator.init(gpa);
        return CNF{
            .num_fixed_clauses = 0, // we count them later
            .num_learned_clauses = 0,
            .num_variables = num_variables,
            .literals = try std.ArrayList(Literal).initCapacity(arena.allocator(), num_clauses * 2),
            .clauses = try std.ArrayList(*ClauseMeta).initCapacity(arena.allocator(), num_clauses * 2),
            .arena = arena,
            .fixed_index = 0,
        };
    }

    pub fn deinit(self: *CNF) void {
        self.literals.deinit(self.arena.allocator());
        self.clauses.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn addClause(self: *CNF, new_literals: []Literal, w1: ?Literal, w2: ?Literal, learnedData: ?LearnedInfo) !*ClauseMeta {
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
            .clauseType = if (learnedData) |ld| .{ .learned = ld } else .fixed,
            .locked = false,
        };

        // 3. Keep track of the pointer in our list
        try self.clauses.append(self.arena.allocator(), meta_ptr);

        if (learnedData == null) {
            @branchHint(.unlikely);
            // If this is a fixed clause but we already have learned clauses,
            // swap it to the fixed_index position to keep the order.
            if (self.fixed_index < self.clauses.items.len - 1) {
                const last_idx = self.clauses.items.len - 1;
                std.mem.swap(*ClauseMeta, &self.clauses.items[self.fixed_index], &self.clauses.items[last_idx]);
            }
            self.fixed_index += 1;
            self.num_fixed_clauses += 1;
        } else {
            self.num_learned_clauses += 1;
        }

        // 4. Return the pointer so the caller can give it to the Watcher
        return meta_ptr;
    }

    pub fn invalidateClause(self: *CNF, cMeta: *ClauseMeta, watcher: *Watcher) !void {
        if (!cMeta.alive) return;
        cMeta.alive = false;
        switch (cMeta.clauseType) {
            ClauseType.learned => self.num_learned_clauses -= 1,
            ClauseType.fixed => self.num_fixed_clauses -= 1,
        }
        try watcher.unregister(cMeta); // NOTE: We can do this lazily if cost is to high
    }

    /// MAKE SURE YOU INVALIDATED FIRST
    pub fn destroyClause(self: *CNF, cMeta: *ClauseMeta) void {
        std.debug.assert(cMeta.alive != true);
        self.arena.allocator().destroy(cMeta);
    }

    pub fn getClause(self: *CNF, cMeta: ClauseMeta) []Literal {
        return self.literals.items[cMeta.start..cMeta.end];
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
