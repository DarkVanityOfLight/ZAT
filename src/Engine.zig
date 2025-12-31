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
const Statistics = @import("Statistics.zig");

const STARTING_CLAUSE_LIMIT = 1000;
const CLAUSE_LIMIT_INCREASE = 1000;
const VSIDS_BUMP = 1.0;
const VSIDS_DECAY_FACTOR = 1.1;

// TODO: Handle learned unit clauses everywhere

const ConflictData = struct {
    backtrack_level: usize,
    uip: Literal,
    second_watch: ?Literal, // Null if the learned clause is unit (size 1)
    lbd: usize, // The literal block distance, aka, the number of decision levels that used in this conflict clause
};

/// Helper to get the literal currently watched by the specific slot (1 or 2)
inline fn getWatchedLiteral(cMeta: Clauses.ClauseMeta, is_watch_1: bool) ?Literal {
    return if (is_watch_1) cMeta.watch1 else cMeta.watch2;
}

const Self = @This();

trail: Trail,
learningClauseList: std.array_list.Managed(Literal),
learningClauseSet: ClauseSet,
watcher: Watcher,
cnf: *CNF,
proof: *DRAT_Proof,
learned_clause_limit: usize,
writer: *std.Io.Writer,
statistics: Statistics,

pub fn init(gpa: std.mem.Allocator, cnf: *CNF, proof: *DRAT_Proof, writer: *std.Io.Writer) !Self {
    var list = std.ArrayList(Literal).empty;
    return Self{
        .trail = try Trail.init(gpa, cnf.num_variables, VSIDS_BUMP, VSIDS_DECAY_FACTOR),
        .learningClauseSet = try ClauseSet.init(gpa, cnf.num_variables),
        .learningClauseList = list.toManaged(gpa),
        .watcher = try Watcher.init(gpa, cnf.num_variables),
        .cnf = cnf,
        .proof = proof,
        .learned_clause_limit = STARTING_CLAUSE_LIMIT,
        .writer = writer,
        .statistics = undefined,
    };
}

pub fn deinit(self: *Self) void {
    self.trail.deinit();
    self.learningClauseSet.deinit();
    self.learningClauseList.deinit();
    self.watcher.deinit();
}

pub fn solve(self: *Self) !Result {
    self.statistics = Statistics.init();
    bank.setBudgets(bank.unlimited, bank.unlimited, 1000);

    switch (try self.initializeWatches()) {
        .unsat => return .unsat,
        else => {},
    }

    var restarts: usize = 0;
    process_loop: while (true) {
        return self.search() catch |err| switch (err) {
            error.OutOfAssigns, error.OutOfPropagations, error.OutOfConflicts => {
                if (restarts % 10 == 0 and restarts > 0) {
                    try self.writer.print(
                        "Check-in at restart {d}:\n{f}",
                        .{ restarts, self.statistics },
                    );
                }

                self.statistics.syncWithBank();
                bank.reset();

                try self.trail.backtrack(0);
                restarts += 1;
                continue :process_loop;
            },
            else => return err,
        };
    }
}

fn initializeWatches(self: *Self) !Result {
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
            try self.watcher.addWatch(lit, cMeta);
        }
    }

    // Initialize the watches for all others
    cMetaIter = self.cnf.aliveClausesMeta();
    while (cMetaIter.next()) |cMeta| {
        const len = cMeta.end - cMeta.start;
        if (len < 2) continue; // Skip unit clause

        // Pick initial watches.
        // We don't need to be fancy here propagate will fix things (I hope)
        const lits = self.cnf.getClause(cMeta.*);
        cMeta.watch1 = lits[0];
        cMeta.watch2 = lits[1];

        // Register them
        try self.watcher.register(cMeta);
    }

    return .unknown;
}

fn pruneClauses(self: *Self) !void {
    const fixed_count = self.cnf.fixed_index;
    // We only care about the learned clauses
    const learned_slice = self.cnf.clauses.items[fixed_count..];

    // Sort: Locked < LBD < Dead
    const ltFn = struct {
        fn lessThan(_: void, a: *const Clauses.ClauseMeta, b: *const Clauses.ClauseMeta) bool {
            // Push Alive (true) to front, Dead (false) to back
            if (a.alive != b.alive) return a.alive;
            // Push Locked (true) to front
            if (a.locked != b.locked) return a.locked;
            // Lower LBD is better
            return a.clauseType.learned.lbd < b.clauseType.learned.lbd;
        }
    }.lessThan;

    std.sort.block(*Clauses.ClauseMeta, learned_slice, {}, ltFn);

    // Number of learned clauses to keep
    const keep_limit = @divFloor(self.cnf.num_learned_clauses, 2);

    // Prune and track the new boundary
    var kept_learned_count: usize = 0;
    for (learned_slice) |cMeta| {
        // Since we sorted dead clauses to the end, the first 'false' alive
        // signals the end of all potentially useful clauses.
        if (!cMeta.alive) break;

        // Decide if we keep this clause
        const should_keep = (kept_learned_count < keep_limit) or cMeta.locked;

        if (should_keep) {
            kept_learned_count += 1;
        } else {
            // Mark for deletion. This clause (and any following it)
            // will now fall outside the new length of the ArrayList.
            try self.proof.delClause(self.cnf.getClause(cMeta.*)); //FIXME: Invalidates our DRAT proof somehow
            try self.cnf.invalidateClause(cMeta);
        }
    }

    // Increase the limit for the next cycle
    self.learned_clause_limit += CLAUSE_LIMIT_INCREASE;
    self.statistics.max_learned_clauses = self.learned_clause_limit;
    self.statistics.learned_clauses = self.cnf.num_learned_clauses;

    // Shrink: The new length is the fixed clauses + kept learned clauses
    for (self.cnf.clauses.items[fixed_count + kept_learned_count ..]) |cMeta| {
        self.cnf.destroyClause(cMeta);
    }
    self.cnf.clauses.shrinkRetainingCapacity(fixed_count + kept_learned_count);
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
            if (self.trail.current_level == 0) return .unsat;

            try bank.countConflict();
            self.trail.vsids.decay();
            // TODO: Where to put this???
            if (self.cnf.num_learned_clauses >= self.learned_clause_limit) try self.pruneClauses();

            try self.resolveConflict(conflict);
            // Reset processed_head to the item we just added so propagate sees it
            processed_head = self.trail.items().len - 1;

            continue; // Jump back to propagate immediately
        }

        // 5. SAT Check
        if (self.trail.items().len == self.cnf.num_variables) {
            return Result{ .sat = try self.trail.toLiteralArray() };
        }

        // 6. Decision Phase
        if (self.trail.chooseLit()) |lit| {
            try self.trail.assign(lit, .assigned);
            // processed_head tracks the start of unpropagated literals.
            // The new decision is at the end, so point to it.
            processed_head = self.trail.items().len - 1;
        } else {
            // Should be covered by SAT check, but safe fallback
            @branchHint(.cold);
            return Result{ .sat = try self.trail.toLiteralArray() };
        }
    }
}

fn resolveConflict(self: *Self, conflict: *Clauses.ClauseMeta) !void {
    const data = try self.conflictAnalysis(conflict);

    // Create the new clause from the set
    const new_clause = self.learningClauseList.items;

    // Utilitis
    try self.proof.addClause(new_clause);
    self.trail.vsids.bumpActivityMany(new_clause);
    self.statistics.learned_clauses = self.cnf.num_learned_clauses;

    const meta_ptr = try self.cnf.addClause(
        new_clause,
        data.uip,
        data.second_watch,
        Clauses.LearnedInfo{ .lbd = data.lbd },
    ); // Will copy new_clause

    try self.watcher.addWatch(meta_ptr.watch1.?, meta_ptr);
    if (data.second_watch) |_| try self.watcher.addWatch(meta_ptr.watch2.?, meta_ptr);

    self.learningClauseSet.reset();
    self.learningClauseList.clearRetainingCapacity();

    // 3. Backtracking
    try self.trail.backtrack(data.backtrack_level);

    // The learned clause makes the UIP unit at the backtrack level.
    // We must assign it manually, providing the new clause as the reason.
    try self.trail.assign(data.uip, .{ .unit_propagation = meta_ptr });
}

fn conflictAnalysis(self: *Self, conflict: *Clauses.ClauseMeta) !ConflictData {
    var counter: usize = 0;
    var trail_idx = self.trail.items().len - 1;

    // Reserve spot for the UIP literal (Asserting Literal)
    try self.learningClauseList.append(undefined);

    // Initialize with the conflict clause
    for (self.cnf.getClause(conflict.*)) |lit| {
        if (!self.learningClauseSet.contains(lit)) {
            self.learningClauseSet.set(lit, {});

            const assgn_lvl = self.trail.assignments.getValue(Variables.not(lit)).?;
            if (assgn_lvl == self.trail.current_level) {
                counter += 1;
            } else if (assgn_lvl > 0) {
                try self.learningClauseList.append(lit);
            }
        }
    }

    // Resolve until 1st UIP is found
    // We stop when 'counter == 1', meaning only one literal from the current level remains.
    while (counter > 1) : (counter -= 1) {
        // Find the next literal on the trail that is part of our conflict
        while (!self.learningClauseSet.contains(Variables.not(self.trail.items()[trail_idx].literal))) : (trail_idx -= 1) {}

        const frame = self.trail.items()[trail_idx];
        const p = frame.literal;

        // Resolve the current clause with the reason for literal 'p'
        const reason_clause = switch (frame.reason) {
            .unit_propagation => |u_reason| u_reason,
            else => unreachable, // 1st UIP logic ensures we only resolve propagated literals
        };

        for (self.cnf.getClause(reason_clause.*)) |lit| {
            // Skip the literal we are currently resolving (p).
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

        // Prepare for the next search step
        trail_idx -= 1;
    }

    // Identify the UIP
    // The 1st UIP is the only literal from the current level left in the clause
    while (!self.learningClauseSet.contains(Variables.not(self.trail.items()[trail_idx].literal))) : (trail_idx -= 1) {}

    const asserting_lit = Variables.not(self.trail.items()[trail_idx].literal);
    self.learningClauseList.items[0] = asserting_lit;

    // Calculate Backtrack Level
    var bt_lvl: usize = 0;
    var second_watch_idx: usize = 0;

    // We don't need learningClauseSet anymore so we abuse it for LBD calculation
    // Since we only need to talk about variables we only use positive literals
    self.learningClauseSet.reset();

    var lbd: usize = 0;
    if (self.learningClauseList.items.len > 1) {
        second_watch_idx = 1;
        for (self.learningClauseList.items, 0..) |lit, i| {
            const lvl = self.trail.assignments.getValue(Variables.not(lit)).?;

            // FIXME: This might get 2?? to large at the maximum decision level
            const lvl_key: i32 = @intCast(lvl + 1);
            if (!self.learningClauseSet.contains(lvl_key)) {
                self.learningClauseSet.set(lvl_key, {});
                lbd += 1;
            }

            // Ignore the UIP
            if (i > 0 and lvl > bt_lvl) {
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
        .lbd = lbd,
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

            const w1 = clause.watch1;
            const w2 = clause.watch2;

            // --- LAZY CLEANUP LOGIC ---
            // If clause is deleted, remove it.
            // If false_lit is no longer one of the two watched literals, remove it.
            const is_actually_watched = (w1 == false_lit or w2 == false_lit);
            if (!clause.alive or !is_actually_watched) {
                _ = watch_list.swapRemove(i);
                // Do not increment i, because swapRemove moved a new element here
                continue;
            }
            // --------------------------

            // Determine which slot is the other one
            const other_lit = if (w1 == false_lit) w2 else w1;
            const is_slot_1 = (w1 == false_lit);

            // If the OTHER watcher is already True, clause satisfied
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
                if (other_lit == null or self.trail.contains(Variables.not(other_lit.?))) {
                    // The other literal is ALSO False. Conflict!
                    return clause;
                } else {
                    // The other literal is Unassigned (it implies Unit).
                    // We propagate 'other_lit' to make the clause True.
                    // NOTE: We leave the watch on 'false_lit' for now,
                    try bank.countPropagate();
                    try self.trail.assign(other_lit.?, .{ .unit_propagation = clause });

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
    var candidate: ?Literal = null;
    const literals = self.cnf.getClause(cMeta);
    for (literals) |other_candidate| {
        if (other_watch != null and other_candidate == other_watch.?) continue;

        // If candidate is satisified choose that one
        if (self.trail.contains(other_candidate)) return other_candidate;

        // If it is unassigned pick that as candidate
        if (!self.trail.contains(Variables.notMaybe(other_candidate))) {
            candidate = candidate orelse other_candidate;
        }
    }
    return candidate;
}

/// Tries to move the watcher for `cMeta` from the `current_slot` to a new literal.
/// Returns true if successful (watch moved).
/// Returns false if no other non-false literal exists (cannot move).
/// THIS REMOVAL IS LAZY
fn moveWatch(self: *Self, cMeta: *Clauses.ClauseMeta, moving_slot_1: bool) !bool {
    if (cMeta.end - cMeta.start < 3) return false;

    const other_lit = getWatchedLiteral(cMeta.*, !moving_slot_1);

    if (self.findWatchCandidate(cMeta.*, other_lit)) |replacement| {
        // Update Metadata locally in the clause
        if (moving_slot_1) cMeta.watch1 = replacement else cMeta.watch2 = replacement;

        // ONLY add to the new list.
        // We do NOT remove from the current_lit list yet.
        try self.watcher.addWatch(replacement, cMeta);
        return true;
    }
    return false;
}
