//! The bank is a global singleton, tracking execution costs
const std = @import("std");
const Statistics = @import("Statistics.zig");

pub const OutOfBudget = error{
    OutOfAssigns,
    OutOfPropagations,
    OutOfConflicts,
};

pub const BankStats = struct {
    assigns: usize,
    props: usize,
    confs: usize,
};

/// Constant representing an unlimited budget
pub const unlimited = std.math.maxInt(usize);

/// Budget limits for the current search cycle
var budgets = BankStats{
    .assigns = unlimited,
    .props = unlimited,
    .confs = unlimited,
};

/// Current cycle counters (reset on bank.reset())
pub var current = BankStats{
    .assigns = 0,
    .props = 0,
    .confs = 0,
};

/// Set the limits for the next search call
pub fn setBudgets(a: usize, p: usize, c: usize) void {
    budgets.assigns = a;
    budgets.props = p;
    budgets.confs = c;
}

pub fn countAssign() OutOfBudget!void {
    if (current.assigns >= budgets.assigns) return error.OutOfAssigns;
    current.assigns += 1;
}

pub fn countPropagate() OutOfBudget!void {
    if (current.props >= budgets.props) return error.OutOfPropagations;
    current.props += 1;
}

pub fn countConflict() OutOfBudget!void {
    if (current.confs >= budgets.confs) return error.OutOfConflicts;
    current.confs += 1;
}

/// Resets the current session counters (used when a budget is hit)
pub fn reset() void {
    current.assigns = 0;
    current.props = 0;
    current.confs = 0;
}
