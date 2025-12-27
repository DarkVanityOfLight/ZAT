const std = @import("std");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const Trail = @import("trail.zig").Trail;
const Result = @import("Result.zig").Result;
const DRAT_Proof = @import("DRAT_proof.zig").Proof;
const CNF = @import("clauses.zig").CNF;
const bank = @import("Bank.zig");

const ClauseSet = @import("datastructures/EpochDict.zig").LiteralEpochDict(void);

const Literal = Variables.Literal;

pub const Engine = struct {
    const Self = @This();

    trail: Trail,
    learningClauseList: std.array_list.Managed(Literal),
    learningClauseSet: ClauseSet,

    pub fn init(gpa: std.mem.Allocator, cnf: *CNF) !Engine {
        const trail = try Trail.init(gpa, cnf.num_variables);
        const learningClauseSet = try ClauseSet.init(gpa, cnf.num_variables);

        var list = std.ArrayList(Literal).empty;

        // Return the initialized struct
        return Engine{
            .trail = trail,
            .learningClauseSet = learningClauseSet,
            .learningClauseList = list.toManaged(gpa),
        };
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.trail.deinit();
        self.learningClauseSet.deinit();
        self.learningClauseList.deinit();
        _ = gpa;
    }

    pub fn solve(self: *Self) !Result {
        _ = self;
        return .unknown;
    }
};
