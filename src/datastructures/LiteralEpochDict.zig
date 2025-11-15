const std = @import("std");
const Literal = @import("ZAT").Variables.Literal;

const Entry = struct { epoch: usize, ptr: *anyopaque };

/// An set like structure to keep track of literals
/// arr contains `epoch` at positions where the literal is set
pub const LiteralEpochDict = struct {
    arr: []*Entry,
    one_index: usize,
    epoch: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, numVars: usize) !*@This() {
        const total = 2 * numVars;
        const arr = try gpa.alloc(Entry, total);
        errdefer gpa.free(arr);

        // Initialize all entries to epoch = 0
        for (arr) |*e| {
            e.* = Entry{ .epoch = 0, .ptr = undefined };
        }

        const set = try gpa.create(@This());
        errdefer gpa.destroy(set);
        set.* = @This(){
            .arr = arr,
            .gpa = gpa,
            .one_index = numVars,
            .epoch = 1,
        };

        return set;
    }

    pub fn deinit(self: *@This()) void {
        self.gpa.free(self.arr);
        self.gpa.destroy(self);
    }

    pub fn addLiteral(self: *@This(), lit: Literal, entry: *anyopaque) void {
        self.arr[self.one_index + lit].epoch = self.epoch;
        self.arr[self.one_index + lit].ptr = entry;
    }

    pub fn removeLiteral(self: *@This(), lit: Literal) void {
        self.arr[self.one_index + lit].epoch -= 1;
        // Get as much safety as possible
        self.arr[self.one_index + lit].ptr = undefined;
    }

    pub fn containsLiteral(self: *@This(), lit: Literal) bool {
        return self.arr[self.one_index + lit].epoch == self.epoch;
    }

    pub fn getAt(self: *@This(), comptime T: type, lit: Literal) ?*T {
        const frame = self.arr[self.one_index + lit];
        if (frame.epoch == self.epoch) {
            return @ptrCast(frame.ptr);
        } else {
            return null;
        }
    }

    pub fn reset(self: *@This()) void {
        self.epoch += 1;
    }
};
