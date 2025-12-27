const std = @import("std");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const Trail = @import("trail.zig").Trail;
const Result = @import("result.zig").Result;
const DRAT_Proof = @import("DRAT_proof.zig").Proof;

const bank = @import("bank.zig");

const ClauseSet = @import("datastructures/EpochDict.zig").LiteralEpochDict(void);

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

    // Early exit for binary clauses
    if (cMeta.end - cMeta.start < 3) {
        return false;
    }

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
                    // NOTE: We leave the watch on 'false_lit' for now,
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

const ConflictData = struct {
    backtrack_level: usize,
    uip: Literal,
    second_watch: ?Literal, // Null if the learned clause is unit (size 1)
};

fn conflictAnalysis(
    conflict: *Clauses.ClauseMeta,
    trail: *Trail,
    cnf: *Clauses.CNF,
    learningClauseSet: *ClauseSet,
    learningClauseList: *std.array_list.Managed(Literal),
) !ConflictData {
    const conflict_clause = cnf.getClause(conflict.*);

    var at_current_level: usize = 0;

    // Variables for finding the second highest level
    var max_level: usize = 0;
    var second_watch_lit: ?Literal = null;

    try learningClauseList.ensureUnusedCapacity(conflict_clause.len);
    // 1. Initialize with the current conflicting clause
    for (conflict_clause) |literal| {
        // Only process if not already in the set
        if (!learningClauseSet.contains(literal)) {
            learningClauseSet.set(literal, undefined);
            try learningClauseList.append(literal);

            const lvl = trail.assignments.getValue(Variables.not(literal)).?; // Variable level

            if (lvl == trail.current_level) {
                at_current_level += 1;
            } else if (lvl > max_level) {
                max_level = lvl;
                second_watch_lit = literal;
            } else if (second_watch_lit == null) {
                // Determine a second watch even if level is 0 or same as max_level
                second_watch_lit = literal;
            }
        }
    }

    // 2. Iterate backwards (Resolution) to find 1-UIP
    var index = trail.stack.items.len - 1;

    while (at_current_level > 1) : (index -= 1) {
        const entry = trail.stack.items[index];
        const conflict_lit = Variables.not(entry.literal);

        if (!learningClauseSet.contains(conflict_lit)) continue;

        // Remove the literal we are resolving on
        learningClauseSet.unset(conflict_lit);
        at_current_level -= 1;

        // Add antecedents
        switch (entry.reason) {
            .unit_propagation => |antecedent_ref| {
                const antecedent = cnf.getClause(antecedent_ref.*);
                for (antecedent) |ant_lit| {
                    if (ant_lit == entry.literal) continue;

                    if (!learningClauseSet.contains(ant_lit)) {
                        learningClauseSet.set(ant_lit, undefined);
                        try learningClauseList.append(ant_lit);

                        const lvl = trail.assignments.getValue(Variables.not(ant_lit)).?;

                        if (lvl == trail.current_level) {
                            at_current_level += 1;
                        } else if (lvl > max_level) {
                            max_level = lvl;
                            second_watch_lit = ant_lit;
                        } else if (second_watch_lit == null) {
                            second_watch_lit = ant_lit;
                        }
                    }
                }
            },
            else => unreachable, // Should not happen if at_current_level > 1
        }
    }

    // 3. Find the UIP
    // The UIP is the only literal remaining in learningClauseSet with level == current_level
    var uip: Literal = 0;
    var found_uip = false;

    // We have to iterate the dict to find it because we don't track it explicitly in the loop
    for (0..learningClauseSet.dict.arr.len) |i| {
        const lit = learningClauseSet.literalOf(i);
        if (learningClauseSet.contains(lit)) {
            const lvl = trail.assignments.getValue(Variables.not(lit)).?;
            if (lvl == trail.current_level) {
                uip = lit;
                found_uip = true;
                break;
            }
        }
    }
    std.debug.assert(found_uip);

    return .{
        .backtrack_level = max_level,
        .uip = uip,
        .second_watch = second_watch_lit,
    };
}

fn setToClause(clauseSet: *ClauseSet, clauseList: *std.array_list.Managed(Literal)) []Literal {
    var write_index: usize = 0;

    for (clauseList.items) |lit| {
        if (clauseSet.contains(lit)) {
            clauseList.items[write_index] = lit;
            write_index += 1;
        }
    }

    clauseList.items = clauseList.items[0..write_index];
    return clauseList.items;
}

pub fn search(gpa: std.mem.Allocator, cnf: *Clauses.CNF, proof: *DRAT_Proof) !Result {
    const trail = try Trail.init(gpa, cnf.num_variables);
    defer trail.deinit();

    const learningClauseSet = try ClauseSet.init(gpa, cnf.num_variables);
    defer learningClauseSet.deinit();
    var learningClauseList: std.array_list.Managed(Literal) = blk: {
        var list = std.ArrayList(Literal).empty;
        // toManaged returns the struct by value, not a pointer
        break :blk list.toManaged(gpa);
    };
    defer learningClauseList.deinit();
    // Initial Propagation (Level 0)
    if (try propagate(trail, cnf, 0)) |_| {
        return .unsat;
    }

    var processed_head: usize = 0;

    // Main Loop
    while (true) {
        // 1. Propagation Phase
        const maybeConflict = try propagate(trail, cnf, processed_head);

        // Update head to current end of trail
        processed_head = trail.items().len;

        if (maybeConflict) |conflict| {
            // 2. Conflict Resolution
            if (trail.current_level == 0) {
                return .unsat;
            }

            try bank.countConflict();
            const data = try conflictAnalysis(
                conflict,
                trail,
                cnf,
                learningClauseSet,
                &learningClauseList,
            );

            // Create the new clause from the set
            const new_clause = setToClause(learningClauseSet, &learningClauseList);
            try proof.addClause(new_clause);

            // Add to database manually to not invoke watch
            // append clause at the end of literals array
            const start = cnf.literals.items.len;
            try cnf.literals.appendSlice(cnf.allocator, new_clause);

            const meta_ptr = try cnf.arena.allocator().create(Clauses.ClauseMeta);
            meta_ptr.* = Clauses.ClauseMeta{
                .start = start,
                .end = start + new_clause.len,
                .capacity = new_clause.len,
                .alive = true,
                .watch1 = data.uip,
                .watch2 = data.second_watch,
            };
            try cnf.clauses.append(cnf.allocator, meta_ptr);
            try cnf.watcher.register(meta_ptr);
            meta_ptr.watch2 = meta_ptr.watch2 orelse data.uip; // We learned a unit clause

            learningClauseSet.reset();
            learningClauseList.clearRetainingCapacity();

            // 3. Backtracking
            trail.backtrack(data.backtrack_level);

            // The learned clause makes the UIP unit at the backtrack level.
            // We must assign it manually, providing the new clause as the reason.
            try trail.assign(data.uip, .{ .unit_propagation = meta_ptr });

            // Reset processed_head to the item we just added so propagate sees it
            processed_head = trail.items().len - 1;

            continue; // Jump back to propagate immediately
        }

        // 5. SAT Check
        if (trail.items().len == cnf.num_variables) {
            return Result{ .sat = try trail.toLiteralArray() };
        }

        // 6. Decision Phase
        if (chooseLit(trail, cnf)) |lit| {
            try trail.assign(lit, .assigned);
            // processed_head tracks the start of unpropagated literals.
            // The new decision is at the end, so point to it.
            processed_head = trail.items().len - 1;
        } else {
            // Should be covered by SAT check, but safe fallback
            return Result{ .sat = try trail.toLiteralArray() };
        }
    }
}
