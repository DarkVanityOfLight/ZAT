const std = @import("std");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const Trail = @import("trail.zig").Trail;
const Result = @import("Result.zig").Result;
const DRAT_Proof = @import("DRAT_proof.zig").Proof;
const CNF = @import("clauses.zig").CNF;
const bank = @import("Bank.zig");
const Watcher = @import("Watcher.zig");
const ClauseSet = @import("datastructures/EpochDict.zig").LiteralEpochDict(void);
const Literal = Variables.Literal;

// TODO: Handle unit clauses at other levels

const ConflictData = struct {
    backtrack_level: usize,
    uip: Literal,
    second_watch: ?Literal, // Null if the learned clause is unit (size 1)
};

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

fn setToClause(clauseSet: *ClauseSet, clauseList: *std.array_list.Managed(Literal)) []Literal {
    var i: usize = 0;
    while (i < clauseList.items.len) {
        const lit = clauseList.items[i];

        if (clauseSet.contains(lit)) {
            // Keep it, move to next
            i += 1;
        } else {
            // Remove it by swapping the last element into this slot
            _ = clauseList.swapRemove(i);
            // Do NOT increment 'i' here, because the "new" element
            // at index 'i' needs to be checked in the next iteration.
        }
    }

    return clauseList.items;
}

const Self = @This();

trail: Trail,
learningClauseList: std.array_list.Managed(Literal),
learningClauseSet: ClauseSet,
watcher: Watcher,
cnf: *CNF,
proof: *DRAT_Proof,

pub fn init(gpa: std.mem.Allocator, cnf: *CNF, proof: *DRAT_Proof) !Self {
    var list = std.ArrayList(Literal).empty;
    return Self{
        .trail = try Trail.init(gpa, cnf.num_variables),
        .learningClauseSet = try ClauseSet.init(gpa, cnf.num_variables),
        .learningClauseList = list.toManaged(gpa),
        .watcher = try Watcher.init(gpa, cnf.num_variables),
        .cnf = cnf,
        .proof = proof,
    };
}

fn learnClause(self: *Self, literals: []Literal, uip: Literal, second: ?Literal) !void {
    // Step 1: Tell the CNF to store it. It returns a stable pointer.
    const meta_ptr = try self.cnf.addClause(literals, uip, second);

    // Step 2: Tell the Watcher to track this new pointer.
    try self.watcher.register(meta_ptr);
}

pub fn deinit(self: *Self) void {
    self.trail.deinit();
    self.learningClauseSet.deinit();
    self.learningClauseList.deinit();
    self.watcher.deinit();
}

pub fn solve(self: *Self) !Result {

    // Search for unit clauses
    var cMetaIter = self.cnf.aliveClausesMeta();
    while (cMetaIter.next()) |cMeta| {
        const len = cMeta.end - cMeta.start;
        if (len == 0) return .unsat;
        if (len == 1) {
            const lit = self.cnf.getClause(cMeta.*)[0];

            if (self.trail.contains(Variables.not(lit))) return .unsat;
            try self.trail.assign(lit, .unit);
            cMeta.watch1 = lit;
            try self.watcher.modifyWatch(lit, cMeta, true);
        }
    }

    // Initialize the watches for all others
    cMetaIter = self.cnf.aliveClausesMeta();
    while (cMetaIter.next()) |cMeta| {
        const len = cMeta.end - cMeta.start;
        if (len < 2) continue; // Skip unit clause

        // Pick initial watches.
        // We don't need to be fancy here propagate will fix things.
        const lits = self.cnf.getClause(cMeta.*);
        cMeta.watch1 = lits[0];
        cMeta.watch2 = lits[1];

        // Register them
        try self.watcher.register(cMeta);
    }

    return self.search();
}

fn search(self: *Self) !Result {
    var processed_head: usize = 0;

    // Main Loop
    while (true) {
        // 1. Propagation Phase
        const maybeConflict = try self.propagate(processed_head);

        // Update head to current end of trail
        processed_head = self.trail.items().len;

        if (maybeConflict) |conflict| {
            // 2. Conflict Resolution
            if (self.trail.current_level == 0) {
                return .unsat;
            }

            try bank.countConflict();
            const data = try self.conflictAnalysis(conflict);

            // Create the new clause from the set
            const new_clause = setToClause(&self.learningClauseSet, &self.learningClauseList);
            try self.proof.addClause(new_clause);

            // Add to database manually to not invoke watch
            // append clause at the end of literals array

            const meta_ptr = try self.cnf.addClause(
                new_clause,
                data.uip,
                data.second_watch,
            );

            try self.watcher.register(meta_ptr);
            self.learningClauseSet.reset();
            self.learningClauseList.clearRetainingCapacity();

            // 3. Backtracking
            self.trail.backtrack(data.backtrack_level);

            // The learned clause makes the UIP unit at the backtrack level.
            // We must assign it manually, providing the new clause as the reason.
            try self.trail.assign(data.uip, .{ .unit_propagation = meta_ptr });

            // Reset processed_head to the item we just added so propagate sees it
            processed_head = self.trail.items().len - 1;

            continue; // Jump back to propagate immediately
        }

        // 5. SAT Check
        if (self.trail.items().len == self.cnf.num_variables) {
            return Result{ .sat = try self.trail.toLiteralArray() };
        }

        // 6. Decision Phase
        if (self.chooseLit()) |lit| {
            try self.trail.assign(lit, .assigned);
            // processed_head tracks the start of unpropagated literals.
            // The new decision is at the end, so point to it.
            processed_head = self.trail.items().len - 1;
        } else {
            // Should be covered by SAT check, but safe fallback
            return Result{ .sat = try self.trail.toLiteralArray() };
        }
    }
}

// The actual learned clause is in learningClauseSet
// learningClauseList contains ALL literals encountered while propagating
fn conflictAnalysis(
    self: *Self,
    conflict: *Clauses.ClauseMeta,
) !ConflictData {
    const conflict_clause = self.cnf.getClause(conflict.*);

    var at_current_level: usize = 0;

    // Variables for finding the second highest level
    var max_level: usize = 0;
    var second_watch_lit: ?Literal = null;

    try self.learningClauseList.ensureUnusedCapacity(conflict_clause.len);
    // 1. Initialize with the current conflicting clause
    for (conflict_clause) |literal| {
        // Only process if not already in the set
        if (!self.learningClauseSet.contains(literal)) {
            self.learningClauseSet.set(literal, undefined);
            try self.learningClauseList.append(literal);

            const lvl = self.trail.assignments.getValue(Variables.not(literal)).?; // Variable level

            if (lvl == self.trail.current_level) {
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
    var index = self.trail.stack.items.len - 1;

    while (at_current_level > 1) : (index -= 1) {
        const entry = self.trail.stack.items[index];
        const conflict_lit = Variables.not(entry.literal);

        if (!self.learningClauseSet.contains(conflict_lit)) continue;

        // Remove the literal we are resolving on
        self.learningClauseSet.unset(conflict_lit);
        at_current_level -= 1;

        // Add antecedents
        switch (entry.reason) {
            .unit_propagation => |antecedent_ref| {
                const antecedent = self.cnf.getClause(antecedent_ref.*);
                for (antecedent) |ant_lit| {
                    if (ant_lit == entry.literal) continue;

                    if (!self.learningClauseSet.contains(ant_lit)) {
                        self.learningClauseSet.set(ant_lit, undefined);
                        try self.learningClauseList.append(ant_lit);

                        const lvl = self.trail.assignments.getValue(Variables.not(ant_lit)).?;

                        if (lvl == self.trail.current_level) {
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
    for (0..self.learningClauseSet.dict.arr.len) |i| {
        const lit = self.learningClauseSet.literalOf(i);
        if (self.learningClauseSet.contains(lit)) {
            const lvl = self.trail.assignments.getValue(Variables.not(lit)).?;
            if (lvl == self.trail.current_level) {
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

/// Propagates unit clauses based on the current trail.
/// Returns: `null` if successful, or `*ClauseMeta` if a conflict occurred.
fn propagate(self: *Self, start_index: usize) !?*Clauses.ClauseMeta {
    var q_head = start_index;

    while (q_head < self.trail.items().len) {
        // Get the literal that was just assigned
        const assigned_lit = self.trail.items()[q_head].literal;
        q_head += 1;

        // We need to notify clauses watching Not(X) (because Not(X) just became False)
        const false_lit = Variables.not(assigned_lit);

        // Get the list of clauses watching this now-false literal
        const watch_list = self.watcher.watched(false_lit);

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
            if (self.trail.contains(other_lit)) {
                i += 1;
                continue;
            }

            // Try to find a new literal to watch to replace 'false_lit'
            const moved = try self.moveWatch(clause, is_slot_1);

            if (moved) {
                // IMPORTANT: moveWatch uses swapRemove on this list.
                // The element at index `i` has been replaced by the last element.
                // We must process index `i` again in the next iteration.
                // Do NOT increment i.
                continue;
            } else {
                // We could not move the watch. The clause is now Unit or Conflicting.

                // Check status of the other literal
                if (self.trail.contains(Variables.not(other_lit))) {
                    // The other literal is ALSO False. Conflict!
                    return clause;
                } else {
                    // The other literal is Unassigned (it implies Unit).
                    // We propagate 'other_lit' to make the clause True.
                    // NOTE: We leave the watch on 'false_lit' for now,
                    try self.trail.assign(other_lit, .{ .unit_propagation = clause });

                    // We move to the next clause in this list
                    i += 1;
                }
            }
        }
    }

    return null;
}

/// Searches for a literal within a clause that is not False and is not `other_watch`.
/// Returns null if no such literal exists.
fn findWatchCandidate(self: *Self, cMeta: Clauses.ClauseMeta, other_watch: ?Literal) ?Literal {
    // TODO: Maybe search for a good candidate
    const literals = self.cnf.getClause(cMeta);
    for (literals) |candidate| {
        if (other_watch != null and candidate == other_watch.?) continue;

        if (!self.trail.contains(Variables.notMaybe(candidate))) {
            return candidate;
        }
    }
    return null;
}

/// Tries to move the watcher for `cMeta` from the `current_slot` to a new literal.
/// Returns true if successful (watch moved).
/// Returns false if no other non-false literal exists (cannot move).
fn moveWatch(self: *Self, cMeta: *Clauses.ClauseMeta, moving_slot_1: bool) !bool {
    // Early exit for binary clauses
    if (cMeta.end - cMeta.start < 3) return false;

    const current_lit = getWatchedLiteral(cMeta.*, moving_slot_1);
    const other_lit = getWatchedLiteral(cMeta.*, !moving_slot_1);

    if (self.findWatchCandidate(cMeta.*, other_lit)) |replacement| {
        // 1. Update Metadata
        if (moving_slot_1) cMeta.watch1 = replacement else cMeta.watch2 = replacement;

        // 2. Update Watcher lists
        try self.watcher.moveWatch(current_lit.?, replacement, cMeta);
        return true;
    }

    return false;
}

fn chooseLit(self: *Self) ?Variables.Literal {
    // Dumb Heuristic: First unassigned variable
    var var_idx: usize = 1;
    while (var_idx <= self.cnf.num_variables) : (var_idx += 1) {
        const lit: Literal = @intCast(var_idx);
        if (!self.trail.contains(lit) and !self.trail.contains(Variables.not(lit))) {
            return lit;
        }
    }
    return null;
}
