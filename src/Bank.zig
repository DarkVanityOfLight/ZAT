//! The bank is a global singleton, tracking execution costs
const std = @import("std");

pub const OutOfBudget = error{
    OutOfAssigns,
    OutOfPropagations,
    OutOfConflicts,
    OutOfOperations,
};

// Global state variables (private to this module by default)
var assigns: usize = 0;
var propagations: usize = 0;
var conflicts: usize = 0;
var operations: usize = 0;

var assign_budget: usize = 0;
var propagation_budget: usize = 0;
var conflict_budget: usize = 0;
var operation_budget: usize = 0;

// Configuration functions
pub fn setBudgets(a: usize, p: usize, c: usize, o: usize) void {
    assign_budget = a;
    propagation_budget = p;
    conflict_budget = c;
    operation_budget = o;
}

pub fn countAssign() OutOfBudget!void {
    if (assigns >= assign_budget) return OutOfBudget.OutOfAssigns;
    assigns += 1;
}

pub fn countPropagate() OutOfBudget!void {
    if (propagations >= propagation_budget) return OutOfBudget.OutOfPropagations;
    propagations += 1;
}

pub fn countConflict() OutOfBudget!void {
    if (conflicts >= conflict_budget) return OutOfBudget.OutOfConflicts;
    conflicts += 1;
}

pub fn countOperations(ops: usize) OutOfBudget!void {
    const r = @addWithOverflow(operations, ops);

    if (r[1] == 1 or r[0] >= operation_budget)
        return OutOfBudget.OutOfOperations;

    operations = r[0];
}

pub fn reset() void {
    assigns = 0;
    propagations = 0;
    conflicts = 0;
    operations = 0;
}

// Getters if you need to inspect counts elsewhere
pub fn getAssigns() usize {
    return assigns;
}
pub fn getConflicts() usize {
    return conflicts;
}
