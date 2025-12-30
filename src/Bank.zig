//! The bank is a global singleton, tracking execution costs
const std = @import("std");
const Statistics = @import("Statistics.zig");

pub const OutOfBudget = error{
    OutOfAssigns,
    OutOfPropagations,
    OutOfConflicts,
    OutOfOperations,
};

/// Constant representing an unlimited budget
pub const unlimited = std.math.maxInt(usize);

// --- Internal State ---

/// Global totals and timers
pub var stats = Statistics{ .start_time = 0 };

/// Budget limits for the current search cycle
var budgets = struct {
    assign: usize = unlimited,
    prop: usize = unlimited,
    conf: usize = unlimited,
    ops: usize = unlimited,
}{};

/// Current cycle counters (reset on bank.reset())
var current = struct {
    assigns: usize = 0,
    props: usize = 0,
    confs: usize = 0,
    ops: usize = 0,
}{};

// --- Public API ---

/// Initialize the bank (sets the start clock)
pub fn init() void {
    stats = .{ .start_time = std.time.milliTimestamp() };
}

/// Set the limits for the next search call
pub fn setBudgets(a: usize, p: usize, c: usize, o: usize) void {
    budgets.assign = a;
    budgets.prop = p;
    budgets.conf = c;
    budgets.ops = o;
}

pub fn countAssign() OutOfBudget!void {
    if (current.assigns >= budgets.assign) return error.OutOfAssigns;
    current.assigns += 1;
    stats.assignments += 1;
}

pub fn countPropagate() OutOfBudget!void {
    if (current.props >= budgets.prop) return error.OutOfPropagations;
    current.props += 1;
    stats.propagations += 1;
}

pub fn countConflict() OutOfBudget!void {
    if (current.confs >= budgets.conf) return error.OutOfConflicts;
    current.confs += 1;
    stats.conflicts += 1;
}

pub fn countOperations(ops: usize) OutOfBudget!void {
    // Handle budget check
    const next_current = @addWithOverflow(current.ops, ops);
    if (next_current[1] == 1 or next_current[0] >= budgets.ops) {
        if (budgets.ops != unlimited) return error.OutOfOperations;
    }
    current.ops = next_current[0];

    // Handle global stats (with overflow protection)
    const next_total = @addWithOverflow(stats.operations, ops);
    stats.operations = if (next_total[1] == 1) std.math.maxInt(u64) else next_total[0];
}

/// Resets the current session counters (used when a budget is hit)
pub fn reset() void {
    current.assigns = 0;
    current.props = 0;
    current.confs = 0;
    current.ops = 0;
}

pub fn getConflicts() usize {
    return current.confs;
}

/// Prints statistics to stderr
pub fn report() void {
    // Because we implemented 'format' in Statistics,
    // we can just pass the struct to print.
    std.debug.print("{}", .{stats});
}
