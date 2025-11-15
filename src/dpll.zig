const std = @import("std");
const Bank = @import("ZAT").Bank;
const Clauses = @import("ZAT").Clauses;
const Variables = @import("ZAT").Variables;
const LiteralDict = @import("ZAT").LiteralEpochDict;

const Reason = enum { pure, unit_propagation, assigned };
const TrailFrame = struct {
    literal: Variables.Literal,
    reason: Reason,
};

const Trail = std.array_list.Managed(TrailFrame);

// Everyone should clean up after themself
// Be carefull with nested usages
// This is scoped for the dpll function
var literalSet: LiteralDict = undefined;

fn onTrail(trail: *Trail, lit: Variables.Literal) bool {
    for (trail.items) |frame| {
        if (frame.literal == lit) return true;
    }
    return false;
}

// Assume trail is in literalSet
fn chooseLit(cnf: *Clauses.CNF, lastAssigned: ?Variables.Literal) ?Variables.Literal {
    var iter = cnf.aliveClauses();
    while (iter.next()) |clause| {
        for (clause) |literal| {
            if (!literalSet.containsLiteral(literal) and lastAssigned != literal) return literal;
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
}

fn unitPropagation(cnf: *Clauses.CNF, trail: *Trail) void {
    var flag = true;
    while (flag) : (flag = false) {
        var iter = cnf.aliveClauses();
        while (iter.next()) |clause| {
            var unassigned: ?Variables.Literal = null;
            var unassigned_count: usize = 0;

            for (clause.literals) |literal| {
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

            if (unassigned_count == 1 and unassigned) {
                trail.append(TrailFrame{
                    .literal = unassigned.?,
                    .reason = .unit_propagation,
                });
                literalSet.addLiteral(unassigned.?, void);
                flag = true;
            }
        }
    }
}

fn pureLiteral(gpa: std.mem.Allocator, cnf: *Clauses.CNF, trail: *Trail) !void {
    const pureSet = try LiteralDict.init(gpa, @divFloor(cnf.num_variables, 2) + 1);
    defer pureSet.deinit();

    const Pure = struct {
        pos: bool,
        neg: bool,
    };

    for (pureSet.arr) |e| {
        e.ptr = &Pure{
            .pos = false,
            .neg = false,
        };
    }

    var flag = true;
    while (flag) : (flag = false) {
        var iter = cnf.aliveClauses();
        while (iter.next()) |clause| {
            for (clause) |literal| {
                const pPtr: *Pure = pureSet.getAt(Pure, Variables.varOf(literal));
                if (Variables.isPositive(literal)) {
                    pPtr.pos = true;
                } else {
                    pPtr.neg = true;
                }
            }
        }

        for (0..cnf.num_variables) |i| {
            const at = pureSet.getAt(Pure, i);
            if (!(at.pos and at.neg)) {
                const lit = blk: {
                    if (at.pos) {
                        break :blk i;
                    } else {
                        break :blk Variables.not(i);
                    }
                };

                if (!literalSet.containsLiteral(lit)) {
                    trail.append(TrailFrame{
                        .literal = lit,
                        .reason = .pure,
                    });
                    literalSet.addLiteral(lit, void);
                    flag = true;
                }
            }
        }
    }
}

pub fn dpll(gpa: std.mem.Allocator, cnf: *Clauses.CNF) !Clauses.Satisfiable {
    const gpaa = std.heap.ArenaAllocator.init(gpa);
    defer gpaa.deinit();

    // Initialize module wide epoch set
    literalSet = LiteralDict.init(gpaa, cnf.num_variables);
    defer literalSet.deinit();

    // Init a trail
    var trail = Trail.init(gpaa);
    defer trail.deinit();

    var lastAssigned: ?Variables.Literal = null;
    // Let's go
    while (true) {
        switch (checkCnf(cnf)) {
            // Found an assignment
            .sat => return Clauses.Satisfiable.sat,
            // Backtrack
            .unsat => {
                if (trail.getLastOrNull() != null) {
                    lastAssigned = popTrail(trail);
                } else if (lastAssigned != null) {
                    // We assigned something, but still are at the end of the stack
                    // unsat
                    return Clauses.Satisfiable.unsat;
                }
            },
        }
        // Unknown: Keep on working
        unitPropagation(cnf, &trail);
        try pureLiteral(gpa, cnf, &trail);

        // Choose the next literal to assign
        if (chooseLit(cnf, lastAssigned)) |lit| {
            trail.append(TrailFrame{ .literal = lit, .reason = Reason.assigned });
            literalSet.addLiteral(lit, void);
            lastAssigned = lit;
        }
    }
}
