const std = @import("std");
const Bank = @import("bank.zig");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const LiteralDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;
const Result = @import("result.zig").Result;

//TODO: Make backtrack explicit
const Reason = enum { pure, unit_propagation, assigned };
const TrailFrame = struct {
    literal: Variables.Literal,
    reason: Reason,
};

const Trail = std.array_list.Managed(TrailFrame);

fn extendTrail(self: *Trail, cnf: *Clauses.CNF, literal: Variables.Literal, reason: Reason) !void {
    try self.append(TrailFrame{
        .literal = literal,
        .reason = reason,
    });
    literalSet.addLiteral(literal, undefined);

    // Do the watching
    const affected = cnf.watcher.watched(Variables.not(literal));
    for (affected.items) |cMeta| {
        if (!cMeta.alive) continue;

        // We need to find and register a new watcher for the clause
        // If the clause isn't already satisfied
        if (literalSet.containsLiteral(cMeta.watch1) or literalSet.containsLiteral(cMeta.watch2)) continue;

        var backup: ?Variables.Literal = null;

        for (cnf.getClause(cMeta.*)) |lit| {
            if (literalSet.containsLiteral(lit)) {
                // This literal satisfies the clause, use it immediately
                backup = lit;
                break;
            } else if (literalSet.containsLiteral(Variables.not(lit))) {
                // literal is false, skip
                continue;
                // first unassigned literal, keep as backup, if not already the other watched literal
            } else if (backup == null and (lit != cMeta.watch1 or cMeta.watch2 != lit)) {
                backup = lit;
                break; // FIXME: This could be wrong
            }
        }

        // TODO: Should I be checking here if the clause is unsat?
        // FIXME: Leave watch be
        if (literal == cMeta.watch1) {
            cMeta.watch1 = backup;
        } else {
            cMeta.watch2 = backup;
        }

        // Register with the new watcher
        if (backup) |_| {
            try cnf.watcher.modifyWatch(literal, cMeta, true);
        }
    }
    //FIXME: If we leave watches  don't full clear, only clear till conflict
    affected.clearRetainingCapacity();
}

// Everyone should clean up after themself
// Be carefull with nested usages
// This is scoped for the dpll function
var literalSet: *LiteralDict = undefined;

// Assume trail is in literalSet
fn chooseLit(cnf: *Clauses.CNF) ?Variables.Literal {
    var iter = cnf.aliveClauses();
    while (iter.next()) |clause| {
        for (clause) |literal| {
            if (!(literalSet.containsLiteral(literal) or literalSet.containsLiteral(Variables.not(literal)))) return literal;
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
            if (literalSet.containsLiteral(literal)) {
                continue :clauseIter; // We have assigned a correct literal, clause is sat
            } else if (!literalSet.containsLiteral(Variables.not(literal))) {
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

fn popTrail(trail: *Trail) ?Variables.Literal {
    while (trail.pop()) |frame| {
        literalSet.removeLiteral(frame.literal);
        if (frame.reason == .assigned) {
            return frame.literal;
        }
    }
    return null;
}

// FIXME: Two pointer trail,
fn watchedUnitPropagation(cnf: *Clauses.CNF, trail: *Trail) !Clauses.Satisfiable {
    var flag = true;
    while (flag) : (flag = false) {
        for (cnf.clauses.items) |cMeta| {
            if (!cMeta.alive) {
                continue;
            }
            // Unit
            //FIXME: Check satisfied
            if (cMeta.watch1 == null and cMeta.watch2 != null) {
                flag = true;
                if (literalSet.containsLiteral(Variables.not(cMeta.watch2.?))) return .unsat;
                try extendTrail(trail, cnf, cMeta.watch2.?, .unit_propagation);
            } else if (cMeta.watch2 == null and cMeta.watch1 != null) { // Unit
                flag = true;
                if (literalSet.containsLiteral(Variables.not(cMeta.watch1.?))) return .unsat;
                try extendTrail(trail, cnf, cMeta.watch1.?, .unit_propagation);
            } else if (cMeta.watch1 == null and cMeta.watch2 == null) { // Falsified
                return .unsat;
            } else { // No unit propagation
                continue;
            }
        }
    }
    return .unknown;
}

fn pureLiteral(gpa: std.mem.Allocator, cnf: *Clauses.CNF, trail: *Trail) !void {
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

        //TODO: Off by one?
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

                if (!literalSet.containsLiteral(lit)) {
                    try extendTrail(trail, cnf, lit, .pure);
                    flag = true;
                }
            }
        }
    }
}

fn trailToArr(gpa: std.mem.Allocator, trail: Trail) ![]Variables.Literal {
    const items = trail.items;
    var res = try gpa.alloc(Variables.Literal, items.len);
    for (items, 0..) |frame, i| {
        res[i] = frame.literal;
    }
    return res;
}

pub fn dpll(gpa: std.mem.Allocator, cnf: *Clauses.CNF) !Result {
    var gpaa = std.heap.ArenaAllocator.init(gpa);
    const gpaai = gpaa.allocator();
    defer gpaa.deinit();

    // Initialize module wide epoch set
    literalSet = try LiteralDict.init(gpaai, cnf.num_variables);
    defer literalSet.deinit();

    // Init a trail
    var trail = Trail.init(gpaai);
    defer trail.deinit();

    // Let's go
    while (true) {
        switch (checkCnf(cnf)) {
            // Found an assignment
            .sat => {
                return Result{ .sat = try trailToArr(gpa, trail) };
            },
            // Backtrack
            .unsat => {
                const last_decision = popTrail(&trail);

                if (last_decision) |decision_lit| {
                    const flipped_lit = Variables.not(decision_lit);
                    try extendTrail(&trail, cnf, flipped_lit, .unit_propagation);
                } else {
                    return Result.unsat;
                }
            },
            .unknown => {},
        }
        // Unknown: Keep on working
        const res = try watchedUnitPropagation(cnf, &trail);
        if (res == .unsat) {
            continue;
        } // Unit propagation made a clause unsat

        try pureLiteral(gpaai, cnf, &trail);

        // Choose the next literal to assign
        if (chooseLit(cnf)) |lit| {
            try extendTrail(&trail, cnf, lit, Reason.assigned);
        }
    }
}
