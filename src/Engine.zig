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
            try self.watcher.modifyWatch(lit, cMeta, true); // This is what .register does under the hood for both watchers
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
            const new_clause = self.learningClauseList.items;
            try self.proof.addClause(new_clause);

            // Add to database manually to not invoke watch
            // append clause at the end of literals array

            const meta_ptr = try self.cnf.addClause(
                new_clause,
                data.uip,
                data.second_watch,
            ); // Will copy new_clause

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

fn conflictAnalysis(self: *Self, conflict: *Clauses.ClauseMeta) !ConflictData {
    var counter: usize = 0;
    var p: Literal = 0;
    var trail_idx = self.trail.items().len - 1;

    try self.learningClauseList.append(undefined); // Reserve UIP spot

    // Start with the conflict clause as the first 'reason'
    var reason = conflict;

    while (true) {
        const clause_lits = self.cnf.getClause(reason.*);
        for (clause_lits) |lit| {
            // Skip the literal we are currently resolving (p).
            // In the first iteration, p is 0 (Bottom), so no literals are skipped.
            if (lit == p) continue;

            if (!self.learningClauseSet.contains(lit)) {
                self.learningClauseSet.set(lit, {});

                // Use Variable level (negating the literal to get the assigned version)
                const var_lit = Variables.not(lit);
                const assgn_lvl = self.trail.assignments.getValue(var_lit).?;

                if (assgn_lvl == self.trail.current_level) {
                    counter += 1;
                } else if (assgn_lvl > 0) {
                    try self.learningClauseList.append(lit);
                }
            }
        }

        // Find the next literal on the trail to resolve
        while (true) {
            const frame = self.trail.items()[trail_idx];
            if (self.learningClauseSet.contains(Variables.not(frame.literal))) {
                p = frame.literal;

                if (counter == 1) break;

                reason = switch (frame.reason) {
                    .unit_propagation => |u_reason| u_reason,
                    else => unreachable, // Should only happen if counter == 1 (UIP is decision)
                };
                break;
            }
            trail_idx -= 1;
        }

        if (counter <= 1) break; // counter == 1 means p is the 1st UIP
        counter -= 1;
        trail_idx -= 1; // Move to next item for the next search
    }

    const asserting_lit = Variables.not(p);
    self.learningClauseList.items[0] = asserting_lit;

    // Calculate Backtrack Level and find the best second watch
    var bt_lvl: usize = 0;
    var second_watch_idx: usize = 0;

    if (self.learningClauseList.items.len > 1) {
        // Initialize with the first available non-UIP literal
        second_watch_idx = 1;
        for (self.learningClauseList.items[1..], 1..) |lit, i| {
            const lvl = self.trail.assignments.getValue(Variables.not(lit)).?;
            if (lvl > bt_lvl) {
                bt_lvl = lvl;
                second_watch_idx = i;
            }
        }
    }

    return ConflictData{
        .backtrack_level = bt_lvl,
        .uip = asserting_lit,
        .second_watch = if (self.learningClauseList.items.len > 1)
            self.learningClauseList.items[second_watch_idx]
        else
            null,
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
