const std = @import("std");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const Literal = Variables.Literal;

const LiteralEpochDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;

const AssignmentSet = LiteralEpochDict(usize);

pub const Reason = union(enum) {
    unit_propagation: *Clauses.ClauseMeta,
    assigned, // Represents a Decision
    backtracked,
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

    pub fn init(gpa: std.mem.Allocator, num_vars: usize) !Trail {
        return Trail{
            .stack = std.ArrayList(TrailFrame).empty,
            .assignments = try AssignmentSet.init(gpa, num_vars),
            .current_level = 0,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Trail) void {
        self.stack.deinit(self.gpa);
        self.assignments.deinit();
    }

    pub fn assign(self: *Trail, literal: Literal, reason: Reason) !void {
        if (reason == .assigned) {
            self.current_level += 1;
        }

        try self.stack.append(self.gpa, TrailFrame{
            .literal = literal,
            .reason = reason,
            .level = self.current_level,
        });

        self.assignments.set(literal, self.current_level);
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

    /// Resets the trail completely (Level 0)
    pub fn reset(self: *Trail) void {
        self.stack.clearRetainingCapacity();
        self.assignments.reset();
        self.current_level = 0;
    }

    pub fn backtrack(self: *Trail, decision_level: usize) void {
        while (self.stack.items.len > 0) {
            const frame = self.stack.items[self.stack.items.len - 1];

            if (frame.level <= decision_level) {
                // Stop at the first frame at or below the target level
                break;
            }

            _ = self.stack.pop(); // We know it isn't empty
            if (frame.reason == .assigned) self.current_level -= 1;
            self.assignments.unset(frame.literal);
        }
    }
};
