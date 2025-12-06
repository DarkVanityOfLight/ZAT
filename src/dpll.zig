const std = @import("std");
const Bank = @import("bank.zig");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const LiteralDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;
const Result = @import("result.zig").Result;

const trail = @import("trail.zig");

// Assume trail is in literalSet
fn chooseLit(cnf: *Clauses.CNF) ?Variables.Literal {
    var iter = cnf.aliveClauses();
    while (iter.next()) |clause| {
        for (clause) |literal| {
            if (!(trail.containsLiteral(literal) or trail.containsLiteral(Variables.not(literal)))) return literal;
        }
    }
    return null;
}

// Assume trail is in literalSet
fn checkCnf(cnf: *Clauses.CNF) Clauses.Satisfiable {
    var iter = cnf.aliveClauses();
    clauseIter: while (iter.next()) |clause| {
        var hasUnassignedVariable = false;
        for (clause) |literal| {
            if (trail.containsLiteral(literal)) {
                continue :clauseIter; // We have assigned a correct literal, clause is sat
            } else if (!trail.containsLiteral(Variables.not(literal))) {
                hasUnassignedVariable = true; // Var is not assigned as true or false, so it isn't assigned
            }
        }

        if (hasUnassignedVariable) {
            // Not satisfied but still variables left to assign
            return Clauses.Satisfiable.unknown;
        } else {
            return Clauses.Satisfiable.unsat; // No variables more to assign, and it isn't satisified
        }
    }

    return Clauses.Satisfiable.sat;
}

inline fn getWatchedLiteral(cMeta: Clauses.ClauseMeta, watcher: bool) ?Variables.Literal {
    return if (watcher) cMeta.watch1 else cMeta.watch2;
}

inline fn getWatcherSlot(cMeta: Clauses.ClauseMeta, literal: Variables.Literal) ?bool {
    return if (cMeta.watch1 == literal) true else if (cMeta.watch2 == literal) false else null;
}

// Indicates success to move
fn moveWatch(cMeta: *Clauses.ClauseMeta, watcherToMove: bool, cnf: *Clauses.CNF) !bool {
    var backup: ?Variables.Literal = null;

    const watchedLiteral = getWatchedLiteral(cMeta.*, watcherToMove);

    for (cnf.getClause(cMeta.*)) |lit| {
        if (trail.containsLiteral(lit)) {
            if (watcherToMove) {
                cMeta.watch1 = lit;
            } else {
                cMeta.watch2 = lit;
            }
            return true;
        } else if (trail.containsLiteral(Variables.not(lit))) {
            // literal is false, skip
            continue;
        } else {
            // first unassigned literal, keep as backup, if not already the other watched literal
            if (lit != getWatchedLiteral(cMeta.*, !watcherToMove)) {
                backup = lit;
            }
        }
    }

    if (backup != null) {
        if (watcherToMove) {
            cMeta.watch1 = backup;
        } else {
            cMeta.watch2 = backup;
        }
        try cnf.watcher.moveWatch(watchedLiteral.?, backup.?, cMeta);

        return true; // Could move watch
    } else {
        return false; // Could not move watch
    }
}

// Indicates if it could propagate everything or produced a conflict
fn propagate(cnf: *Clauses.CNF) !bool {
    if (trail.items().len == 0) return true;
    var qHead = trail.items().len - 1;

    // While we haven't propageted everything we put on the trail
    while (qHead < trail.items().len) : (qHead += 1) {
        const literal = trail.items()[qHead].literal;

        // Get the clauses that are watched by negation of the literal we are currently handeling
        const watched = cnf.watcher.watched(Variables.not(literal));

        // Search for new watchers, keep track of the index by hand
        // because we modify the Watchers page (watched clauses)
        var i: usize = 0;
        while (i < watched.items.len) {
            // This clause needs a new watcher
            const clauseToMove = watched.items[i];

            // If the clause isn't alive, ignore it
            if (!clauseToMove.alive) {
                i += 1;
                continue;
            }

            // Get the slot the current watcher is in
            std.debug.print("{any}\n", .{clauseToMove});
            const movedWatcherSlot = getWatcherSlot(clauseToMove.*, literal).?;

            // Check if the watcher in the other slot is satsified
            const otherWatcherLiteral = getWatchedLiteral(clauseToMove.*, !movedWatcherSlot);
            if (trail.containsLiteral(otherWatcherLiteral)) {
                // If yes we can ignore this one
                i += 1;
                continue;
            }

            // Try to move our watcher, if successfull the clause is removed using swap remove and we have
            // a new unhandled clause at the same position
            const success = try moveWatch(clauseToMove, movedWatcherSlot, cnf);
            if (success) {
                continue; // We were able to either satisfy or move to another unassigned literal
            } else {
                // We could not move, either we set the other literal, or produce a conflict

                // Can we set the other watcher?
                if (otherWatcherLiteral != null and !trail.containsLiteral(Variables.not(otherWatcherLiteral.?))) {
                    // Yes => Extend the trail, and keep the current watch
                    try trail.assign(otherWatcherLiteral.?, .unit_propagation);
                    i += 1; // This clause is done and stays in the list
                } else {
                    // No => conflict
                    return false;
                }
            }
        }
    }

    return true;
}

fn pureLiteral(gpa: std.mem.Allocator, cnf: *Clauses.CNF) !void {
    const Pure = struct {
        pos: bool,
        neg: bool,
    };

    const pureSet = try gpa.alloc(Pure, cnf.num_variables + 1);
    defer gpa.free(pureSet);

    @memset(pureSet, Pure{ .pos = false, .neg = false });

    var flag = true;
    while (flag) : (flag = false) {
        @memset(pureSet, Pure{ .pos = false, .neg = false });
        var iter = cnf.aliveClauses();
        while (iter.next()) |clause| {
            for (clause) |literal| {
                var p = &pureSet[Variables.varOf(literal)];
                if (Variables.isPositive(literal)) {
                    p.pos = true;
                } else {
                    p.neg = true;
                }
            }
        }

        for (1..(cnf.num_variables + 1)) |i| {
            const at = pureSet[i];
            if (!(at.pos and at.neg)) {
                const lit = blk: {
                    if (at.pos) {
                        break :blk Variables.litOf(@intCast(i));
                    } else {
                        break :blk Variables.not(Variables.litOf(@intCast(i)));
                    }
                };

                if (!trail.containsLiteral(lit)) {
                    try trail.assign(lit, .pure);
                    flag = true;
                }
            }
        }
    }
}

pub fn dpll(gpa: std.mem.Allocator, cnf: *Clauses.CNF) !Result {
    var gpaa = std.heap.ArenaAllocator.init(gpa);
    const gpaai = gpaa.allocator();
    defer gpaa.deinit();

    // Initialize trail
    try trail.init(gpaai, cnf.num_variables);
    defer trail.deinit();

    // TODO: Handle unit propagations at level 0

    // Let's go
    while (true) {
        switch (checkCnf(cnf)) {
            // Found an assignment
            .sat => {
                return Result{ .sat = try trail.toArr(gpa) };
            },
            // Backtrack
            .unsat => {
                const last_decision = trail.pop();

                if (last_decision) |decision_lit| {
                    const flipped_lit = Variables.not(decision_lit);
                    try trail.assign(flipped_lit, .backtracked);
                } else {
                    return Result.unsat;
                }
            },
            .unknown => {},
        }
        // Unknown: Keep on working

        // Check for new unit propagations after assignment
        const res1 = try propagate(cnf);
        if (!res1) {
            continue; // Conflict
        }

        try pureLiteral(gpaai, cnf); // TODO: This will be removed later
        const res2 = try propagate(cnf);
        if (!res2) {
            continue; // Conflict
        }

        // Choose the next literal to assign
        if (chooseLit(cnf)) |lit| {
            try trail.assign(lit, .assigned);
        }
    }
}
