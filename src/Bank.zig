//! The bank is a global singleton, tracking execution costs
const std = @import("std");

pub const OutOfBudget = error{
    OutOfAssigns,
    OutOfPropagations,
    OutOfConflicts,
    OutOfOperations,
};

/// Constant representing an unlimited budget
pub const unlimited = std.math.maxInt(usize);

// Global state variables
var assigns: usize = 0;
var propagations: usize = 0;
var conflicts: usize = 0;
var operations: usize = 0;

var total_assigns: usize = 0;
var total_propagations: usize = 0;
var total_conflicts: usize = 0;

var assign_budget: usize = unlimited;
var propagation_budget: usize = unlimited;
var conflict_budget: usize = unlimited;
var operation_budget: usize = unlimited;

pub fn setBudgets(a: usize, p: usize, c: usize, o: usize) void {
    assign_budget = a;
    propagation_budget = p;
    conflict_budget = c;
    operation_budget = o;
}

pub fn countAssign() OutOfBudget!void {
    // If budget is not unlimited, check against the limit
    if (assign_budget != unlimited and assigns >= assign_budget)
        return OutOfBudget.OutOfAssigns;
    assigns += 1;
    total_assigns += 1;
}

pub fn countPropagate() OutOfBudget!void {
    if (propagation_budget != unlimited and propagations >= propagation_budget)
        return OutOfBudget.OutOfPropagations;
    propagations += 1;
    total_propagations += 1;
}

pub fn countConflict() OutOfBudget!void {
    if (conflict_budget != unlimited and conflicts >= conflict_budget)
        return OutOfBudget.OutOfConflicts;
    conflicts += 1;
    total_conflicts += 1;
}

pub fn countOperations(ops: usize) OutOfBudget!void {
    const r = @addWithOverflow(operations, ops);

    // Overflow check for the counter itself (prevents panic)
    if (r[1] == 1) {
        operations = std.math.maxInt(usize);
    } else {
        operations = r[0];
    }

    // Only return error if budget is enforced and exceeded
    if (operation_budget != unlimited and operations >= operation_budget)
        return OutOfBudget.OutOfOperations;
}

pub fn reset() void {
    assigns = 0;
    propagations = 0;
    conflicts = 0;
    operations = 0;
}

pub fn getAssigns() usize {
    return assigns;
}
pub fn getConflicts() usize {
    return conflicts;
}

pub fn report() void { // Or pass as args
    const msg =
        \\c === Solver Statistics === 
        \\c Conflicts    : {d}
        \\c Propagations : {d}
        \\c Assignments  : {d}
        \\
    ;
    std.debug.print(msg, .{ total_conflicts, total_propagations, total_assigns });
}
