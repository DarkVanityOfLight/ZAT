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

fn checkCnf(cnf: *Clauses.CNF) Clauses.Satisfiable {
    var iter = cnf.aliveClausesMeta();

    var all_satisfied = true;
    while (iter.next()) |clause| {
        const w1 = clause.watch1;
        const w2 = clause.watch2;

        const satisfied =
            (w1 != null and trail.containsLiteral(w1.?)) or
            (w2 != null and trail.containsLiteral(w2.?));

        if (satisfied) continue;

        if ((w1 == null or trail.containsLiteral(Variables.notMaybe(w1))) and
            (w2 == null or trail.containsLiteral(Variables.notMaybe(w2))))
            return .unsat;

        // TODO: The clause might still contain a satisified literal, not currently watched
        all_satisfied = false;
    }
    return if (all_satisfied) .sat else .unknown;
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
            const movedWatcherSlot = getWatcherSlot(clauseToMove.*, Variables.not(literal)).?;

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

        // Choose the next literal to assign
        if (chooseLit(cnf)) |lit| {
            try trail.assign(lit, .assigned);
        }
    }
}
