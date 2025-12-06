const std = @import("std");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const Trail = @import("trail.zig").Trail;
const Result = @import("result.zig").Result;

const Literal = Variables.Literal;

/// Helper to get the literal currently watched by the specific slot (1 or 2)
inline fn getWatchedLiteral(cMeta: Clauses.ClauseMeta, is_watch_1: bool) ?Literal {
    return if (is_watch_1) cMeta.watch1 else cMeta.watch2;
}

/// Helper to determine which slot (1 or 2) a specific literal occupies in a clause
inline fn getWatcherSlot(cMeta: Clauses.ClauseMeta, lit: Literal) ?bool {
    if (cMeta.watch1 == lit) return true;
    if (cMeta.watch2 == lit) return false;
    return null;
}

/// Tries to move the watcher for `cMeta` from the `current_slot` to a new literal.
/// Returns true if successful (watch moved).
/// Returns false if no other non-false literal exists (cannot move).
fn tryMoveWatch(cMeta: *Clauses.ClauseMeta, moving_slot_1: bool, trail: *Trail, cnf: *Clauses.CNF) !bool {
    const current_lit = getWatchedLiteral(cMeta.*, moving_slot_1).?;
    const other_lit = getWatchedLiteral(cMeta.*, !moving_slot_1);

    // Iterate over the clause literals to find a replacement
    const literals = cnf.getClause(cMeta.*);

    for (literals) |candidate_lit| {
        // We cannot pick the literal currently watched by the OTHER slot
        if (candidate_lit == other_lit) continue;

        // If candidate is NOT False (i.e., it is True or Unassigned), we can watch it.
        // contains(not(lit)) means lit is False.
        if (!trail.contains(Variables.notMaybe(candidate_lit))) {

            // 1. Update the metadata
            if (moving_slot_1) {
                cMeta.watch1 = candidate_lit;
            } else {
                cMeta.watch2 = candidate_lit;
            }

            // 2. Update the Watcher data structure
            // This removes cMeta from `current_lit` list and adds to `candidate_lit` list
            try cnf.watcher.moveWatch(current_lit, candidate_lit, cMeta);

            return true;
        }
    }

    return false;
}

/// Propagates unit clauses based on the current trail.
/// Returns: `null` if successful, or `*ClauseMeta` if a conflict occurred.
fn propagate(trail: *Trail, cnf: *Clauses.CNF, start_index: usize) !?*Clauses.ClauseMeta {
    var q_head = start_index;

    while (q_head < trail.items().len) {
        // Get the literal that was just assigned
        const assigned_lit = trail.items()[q_head].literal;
        q_head += 1;

        // We need to notify clauses watching Not(X) (because Not(X) just became False)
        const false_lit = Variables.not(assigned_lit);

        // Get the list of clauses watching this now-false literal
        const watch_list = cnf.watcher.watched(false_lit);

        var i: usize = 0;
        while (i < watch_list.items.len) {
            const clause = watch_list.items[i];

            if (!clause.alive) {
                i += 1;
                continue;
            }

            // Determine which slot of the clause is watching 'false_lit'
            // If it's in the watch list, it MUST be in slot 1 or 2
            const is_slot_1 = getWatcherSlot(clause.*, false_lit).?;

            // Check the OTHER watcher
            const other_lit = getWatchedLiteral(clause.*, !is_slot_1) orelse {
                // The only reason the other literal might be null is if the clause only contains one literal
                return clause;
            };

            //If the OTHER watcher is already True, the clause is satisfied.
            // We don't need to do anything, not even move the watch.
            if (trail.contains(other_lit)) {
                i += 1;
                continue;
            }

            // Try to find a new literal to watch to replace 'false_lit'
            const moved = try tryMoveWatch(clause, is_slot_1, trail, cnf);

            if (moved) {
                // IMPORTANT: moveWatch uses swapRemove on this list.
                // The element at index `i` has been replaced by the last element.
                // We must process index `i` again in the next iteration.
                // Do NOT increment i.
                continue;
            } else {
                // We could not move the watch. The clause is now Unit or Conflicting.

                // Check status of the other literal
                if (trail.contains(Variables.not(other_lit))) {
                    // The other literal is ALSO False. Conflict!
                    return clause;
                } else {
                    // The other literal is Unassigned (it implies Unit).
                    // We propagate 'other_lit' to make the clause True.
                    // Note: We leave the watch on 'false_lit' for now,
                    try trail.assign(other_lit, .{ .unit_propagation = clause });

                    // We move to the next clause in this list
                    i += 1;
                }
            }
        }
    }

    return null;
}

fn chooseLit(trail: *Trail, cnf: *Clauses.CNF) ?Variables.Literal {
    // Dumb Heuristic: First unassigned variable
    var var_idx: usize = 1;
    while (var_idx <= cnf.num_variables) : (var_idx += 1) {
        const lit: Literal = @intCast(var_idx);
        if (!trail.contains(lit) and !trail.contains(Variables.not(lit))) {
            return lit;
        }
    }
    return null;
}

pub fn dpll(gpa: std.mem.Allocator, cnf: *Clauses.CNF) !Result {
    const trail = try Trail.init(gpa, cnf.num_variables);
    defer trail.deinit();

    // Initial check (Level 0 propagation)
    if (try propagate(trail, cnf, 0)) |_| {
        return Result.unsat;
    }

    var processed_head: usize = 0;

    while (true) {
        // 1. Propagation Phase
        const conflict = try propagate(trail, cnf, processed_head);

        // Mark all current items as processed
        processed_head = trail.items().len;

        if (conflict) |_| {
            // 2. Conflict Handling
            if (trail.current_level == 0) {
                return Result.unsat;
            }

            // Your specific pop() implementation unwinds to the last .assigned decision
            if (trail.pop()) |decision_lit| {
                // We found the decision 'X'. We now know 'X' leads to conflict.
                // We must try 'not(X)'.
                // We mark it as .backtracked so that if this also fails, pop()
                // will skip it and go to the previous decision level.
                try trail.assign(Variables.not(decision_lit), .backtracked);

                // Reset propagation head to the new item we just added
                processed_head = trail.items().len - 1;
                continue;
            } else {
                // If pop returns null, we have exhausted the decision stack
                return Result.unsat;
            }
        }

        // 3. SAT Check
        if (trail.items().len == cnf.num_variables) {
            return Result{ .sat = try trail.toLiteralArray() };
        }

        // 4. Decision Phase
        if (chooseLit(trail, cnf)) |lit| {
            try trail.assign(lit, .assigned); // This marks the new level
            processed_head = trail.items().len - 1;
        } else {
            return Result{ .sat = try trail.toLiteralArray() };
        }
    }
}
