const std = @import("std");
const Bank = @import("bank.zig");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const LiteralDict = @import("datastructures/LiteralEpochDict.zig").LiteralEpochDict;

//TODO: Make backtrack explicit
const Reason = enum { pure, unit_propagation, assigned };
const TrailFrame = struct {
    literal: Variables.Literal,
    reason: Reason,
};

const Trail = std.array_list.Managed(TrailFrame);

// Everyone should clean up after themself
// Be carefull with nested usages
// This is scoped for the dpll function
var literalSet: *LiteralDict = undefined;

fn onTrail(trail: *Trail, lit: Variables.Literal) bool {
    for (trail.items) |frame| {
        if (frame.literal == lit) return true;
    }
    return false;
}

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

// Returns unsat if the trail is poped to empty
fn popTrail(trail: *Trail) ?Variables.Literal {
    while (trail.pop()) |frame| {
        literalSet.removeLiteral(frame.literal);
        if (frame.reason == .assigned) {
            return frame.literal;
        }
    }
    return null;
}

fn unitPropagation(cnf: *Clauses.CNF, trail: *Trail) !void {
    var flag = true;
    while (flag) : (flag = false) {
        var iter = cnf.aliveClauses();
        while (iter.next()) |clause| {
            var unassigned: ?Variables.Literal = null;
            var unassigned_count: usize = 0;

            for (clause) |literal| {
                if (literalSet.containsLiteral(literal)) {
                    // Clause satisfied
                    unassigned_count = 0;
                    break;
                } else if (!literalSet.containsLiteral(Variables.not(literal))) {
                    // Literal is unassigned
                    unassigned = literal;
                    unassigned_count += 1;
                }
            }

            if (unassigned_count == 1 and unassigned != null) {
                try trail.append(TrailFrame{
                    .literal = unassigned.?,
                    .reason = .unit_propagation,
                });
                literalSet.addLiteral(unassigned.?, undefined);
                flag = true;
            }
        }
    }
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
                    try trail.append(TrailFrame{
                        .literal = lit,
                        .reason = .pure,
                    });
                    literalSet.addLiteral(lit, undefined);
                    flag = true;
                }
            }
        }
    }
}

pub fn dpll(gpa: std.mem.Allocator, cnf: *Clauses.CNF) !Clauses.Satisfiable {
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
                return Clauses.Satisfiable.sat;
            },
            // Backtrack
            .unsat => {
                const last_decision = popTrail(&trail);

                if (last_decision) |decision_lit| {
                    const flipped_lit = Variables.not(decision_lit);
                    try trail.append(TrailFrame{
                        .literal = flipped_lit,
                        .reason = .unit_propagation,
                    });
                    literalSet.addLiteral(flipped_lit, undefined);
                } else {
                    return Clauses.Satisfiable.unsat;
                }
            },
            .unknown => {},
        }
        // Unknown: Keep on working
        try unitPropagation(cnf, &trail);
        try pureLiteral(gpaai, cnf, &trail);

        // Choose the next literal to assign
        if (chooseLit(cnf)) |lit| {
            try trail.append(TrailFrame{ .literal = lit, .reason = Reason.assigned });
            literalSet.addLiteral(lit, undefined);
        }
    }
}
