const std = @import("std");
const Bank = @import("bank.zig");
const Clauses = @import("clauses.zig");
const Variables = @import("variables.zig");
const LiteralDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;
const Result = @import("result.zig").Result;

const TrailStack = std.array_list.Managed(TrailFrame);
const Reason = enum { pure, unit_propagation, assigned, backtracked };
const TrailFrame = struct {
    literal: Variables.Literal,
    reason: Reason,
};

pub var literalSet: *LiteralDict = undefined;
pub var trailStack: TrailStack = undefined;

pub fn assign(literal: Variables.Literal, reason: Reason) !void {
    try trailStack.append(TrailFrame{
        .literal = literal,
        .reason = reason,
    });
    literalSet.addLiteral(literal, undefined);
}

pub fn pop() ?Variables.Literal {
    while (trailStack.pop()) |frame| {
        literalSet.removeLiteral(frame.literal);
        if (frame.reason == .assigned) {
            return frame.literal;
        }
    }
    return null;
}

pub fn toArr(gpa: std.mem.Allocator) ![]Variables.Literal {
    var res = try gpa.alloc(Variables.Literal, items().len);
    for (items(), 0..) |frame, i| {
        res[i] = frame.literal;
    }
    return res;
}

pub inline fn items() []TrailFrame {
    return trailStack.items;
}

pub inline fn containsLiteral(lit: ?Variables.Literal) bool {
    return literalSet.containsLiteral(lit);
}

pub fn init(gpa: std.mem.Allocator, num_vars: usize) !void {
    trailStack = TrailStack.init(gpa);
    literalSet = try LiteralDict.init(gpa, num_vars);
}

pub fn deinit() void {
    trailStack.deinit();
    trailStack = undefined;
    literalSet.deinit();
    literalSet = undefined;
}
