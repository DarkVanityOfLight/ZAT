//! The bank is a global singelton, tracking execution costs
const std = @import("std");

pub const OutOfBudget = error{
    OutOfAssigns,
    OutOfPropagations,
    OutOfConflicts,
    OutOfOperations,
};

pub const CostTracker = struct {
    var assigns: usize = 0;
    var propagations: usize = 0;
    var conflicts: usize = 0;
    var operations: usize = 0;

    var assignBudget: usize = 0;
    var propagationBudget: usize = 0;
    var conflictBudget: usize = 0;
    var operationBudget: usize = 0;

    pub fn countAssign(self: *CostTracker) OutOfBudget.OutOfAssigns!void {
        if (self.assigns >= self.assignBudget) return OutOfBudget.OutOfAssigns;
        self.assigns += 1;
    }

    pub fn countPropagate(self: *CostTracker) OutOfBudget.OutOfPropagations!void {
        if (self.propagations >= self.propagationBudget) return OutOfBudget.OutOfPropagations;
        self.propagations += 1;
    }

    pub fn countConflict(self: *CostTracker) OutOfBudget.OutOfConflicts!void {
        if (self.conflicts >= self.conflictBudget) return OutOfBudget.OutOfConflicts;
        self.conflicts += 1;
    }

    pub fn countOperations(
        self: *CostTracker,
        ops: usize,
    ) OutOfBudget.OutOfConflicts!void {
        const r = @addWithOverflow(self.operations, ops);

        if (r[1] == 1)
            return OutOfBudget.OutOfOperations;

        if (r[0] >= self.operationBudget)
            return OutOfBudget.OutOfOperations;

        self.operations = r[0];
    }

    pub fn resetAssigns(self: *CostTracker) void {
        self.assigns = 0;
    }

    pub fn resetPropagations(self: *CostTracker) void {
        self.propagate = 0;
    }

    pub fn resetConflicts(self: *CostTracker) void {
        self.conflicts = 0;
    }

    pub fn resetOperations(self: *CostTracker) void {
        self.operations = 0;
    }

    pub fn reset(self: *CostTracker) void {
        self.resetAssigns();
        self.resetPropagations();
        self.resetConflicts();
        self.resetOperations();
    }
};

pub var tracker: CostTracker = CostTracker{};
