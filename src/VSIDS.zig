const std = @import("std");
const Variable = @import("variables.zig").Variable;

const ActivityHeap = std.PriorityQueue(Variable, *Self, compare);

const Entry = struct {
    activity_value: f64,
    in_heap: bool,
};

const VarSet = @import("datastructures/EpochDict.zig").VariableEpochDict(Entry);

/// VSIDS needs to closely work together with the trail to maintain invariants
/// If the trail backtracks, each variable that is poped from the trail
/// NEEDS to be reinserted into the heap if it isn't in it for this use reinsert
///
/// When a variable is assigned on the trail we LAZILY remove it from the heap,
/// that is we don't
///
/// To get a new variable the caller, has to
///     1. Get the top variable using selectVar
///     2. Check if it is already assigned
///         - If yes try again
///         - If no we are done
///
const Self = @This();
var_set: *VarSet,
bump_summand: f64,
decay_factor: f64, // >= 1
activity_heap: ActivityHeap,

fn compare(self: *Self, v1: Variable, v2: Variable) std.math.Order {
    const a1 = self.var_set.get(v1).?.activity_value;
    const a2 = self.var_set.get(v2).?.activity_value;

    // max-heap by activity
    return std.math.order(a2, a1);
}

pub fn init(gpa: std.mem.Allocator, num_vars: usize, bump_summand: f64, decay_factor: f64) !*Self {
    const self = try gpa.create(Self);
    errdefer gpa.destroy(self);

    self.* = Self{
        .var_set = try VarSet.init(gpa, num_vars),
        .activity_heap = undefined, // We'll set this in a moment
        .bump_summand = bump_summand,
        .decay_factor = decay_factor,
    };

    self.activity_heap = ActivityHeap.init(gpa, self);

    for (1..num_vars + 1) |vi| {
        const v: Variable = @intCast(vi);
        self.var_set.set(v, Entry{
            .activity_value = 0.0,
            .in_heap = true,
        });
        try self.activity_heap.add(v);
    }

    return self;
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.activity_heap.deinit();
    self.var_set.deinit();
    gpa.destroy(self);
    self.* = undefined;
}

// TODO: Handle overflows

pub fn bumpActivity(self: *Self, v: Variable) void {
    self.var_set.get(v).?.activity_value += self.bump_summand;
}

pub fn decay(self: *Self) void {
    self.bump_summand *= self.decay_factor;
}

pub fn reinsert(self: *Self, v: Variable) !void {
    var info = self.var_set.get(v).?;
    if (!info.in_heap) {
        try self.activity_heap.add(v);
        info.in_heap = true;
    }
}

pub fn selectVar(self: *Self) ?Variable {
    if (self.activity_heap.count() == 0) return null;
    const removed = self.activity_heap.remove();
    self.var_set.get(removed).?.in_heap = false;
    return removed;
}
