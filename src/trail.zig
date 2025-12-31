const std = @import("std");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const Literal = Variables.Literal;
const bank = @import("Bank.zig");
const VSIDS = @import("VSIDS.zig");

const LiteralEpochDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;

const AssignmentSet = LiteralEpochDict(usize);
const PhaseSet = LiteralEpochDict(void);

pub const Reason = union(enum) {
    unit_propagation: *Clauses.ClauseMeta,
    assigned, // Represents a Decision
    unit,
};

pub const TrailFrame = struct {
    literal: Literal,
    reason: Reason,
    level: usize,
};

pub const Trail = struct {
    stack: std.ArrayList(TrailFrame),
    assignments: AssignmentSet,
    current_level: usize,
    gpa: std.mem.Allocator,
    vsids: *VSIDS, // Since VSIDS is closely related to the stack we have it here
    phase: PhaseSet,

    pub fn init(gpa: std.mem.Allocator, num_vars: usize, bump_summand: f64, decay_factor: f64) !Trail {
        return Trail{
            .stack = std.ArrayList(TrailFrame).empty,
            .assignments = try AssignmentSet.init(gpa, num_vars),
            .current_level = 0,
            .vsids = try VSIDS.init(gpa, num_vars, bump_summand, decay_factor),
            .phase = try PhaseSet.init(gpa, num_vars),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Trail) void {
        self.stack.deinit(self.gpa);
        self.assignments.deinit();
        self.vsids.deinit(self.gpa);
        self.phase.deinit();
    }

    pub fn assign(self: *Trail, literal: Literal, reason: Reason) !void {
        try bank.countAssign();

        switch (reason) {
            .unit_propagation => |cMeta| cMeta.locked = true,
            .assigned => self.current_level += 1,
            .unit => {},
        }

        try self.stack.append(self.gpa, TrailFrame{
            .literal = literal,
            .reason = reason,
            .level = self.current_level,
        });

        self.assignments.set(literal, self.current_level);
        // Save the assignment to the phase
        self.phase.set(literal, {});
        self.phase.unset(Variables.not(literal));
    }

    pub fn pop(self: *Trail) !TrailFrame {
        const frame = try self.pop();
        self.assignments.unset(frame.literal);
        return frame;
    }

    /// Fast O(1) check if a literal is currently on the trail
    pub inline fn contains(self: *Trail, lit: ?Literal) bool {
        return self.assignments.contains(lit);
    }

    pub inline fn items(self: *Trail) []TrailFrame {
        return self.stack.items;
    }

    /// Helper to get just the literals as a slice (caller owns memory)
    pub fn toLiteralArray(self: *Trail) ![]Literal {
        const res = try self.gpa.alloc(Literal, self.stack.items.len);
        for (self.stack.items, 0..) |frame, i| {
            res[i] = frame.literal;
        }
        return res;
    }

    pub fn backtrack(self: *Trail, decision_level: usize) !void {
        while (self.stack.items.len > 0) {
            const frame = self.stack.items[self.stack.items.len - 1];

            if (frame.level <= decision_level) {
                // Stop at the first frame at or below the target level
                break;
            }

            _ = self.stack.pop(); // We know it isn't empty
            switch (frame.reason) {
                .unit_propagation => |cMeta| cMeta.locked = false,
                .assigned => self.current_level -= 1,
                .unit => {},
            }

            self.assignments.unset(frame.literal);
            // Notify VSIDS
            try self.vsids.reinsert(Variables.varOf(frame.literal));
        }
    }

    pub fn isVarAssigned(self: *Trail, variable: Variables.Variable) bool {
        const lit = Variables.litOf(variable);
        return self.contains(lit) or self.contains(Variables.not(lit));
    }

    pub fn isVarOfLitAssigned(self: *Trail, lit: Variables.Literal) bool {
        return self.contains(lit) or self.contains(Variables.not(lit));
    }

    pub fn chooseLit(self: *Trail) ?Variables.Literal {
        while (self.vsids.selectVar()) |candidate| {
            const candidate_lit = Variables.litOf(candidate);
            if (!self.isVarAssigned(candidate)) {
                // Check phase saving
                if (self.phase.contains(candidate_lit)) return candidate_lit;
                return Variables.not(candidate_lit);
            }
        }
        return null;
    }
};
