const std = @import("std");
const Literal = @import("../variables.zig").Literal;

const Entry = struct { epoch: usize, ptr: *anyopaque };

/// An set like structure to keep track of literals
/// arr contains `epoch` at positions where the literal is set
pub const LiteralEpochDict = struct {
    arr: []Entry,
    one_index: usize,
    epoch: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, numVars: usize) !*@This() {
        const total = (2 * numVars);
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
        const idx: usize = if (lit > 0) self.one_index + @as(usize, @intCast(lit)) - 1 else @as(usize, @intCast(@abs(lit) - 1));
        self.arr[idx].epoch = self.epoch;
        self.arr[idx].ptr = entry;
    }

    pub fn removeLiteral(self: *@This(), lit: Literal) void {
        const idx: usize = if (lit > 0) self.one_index + @as(usize, @intCast(lit)) - 1 else @as(usize, @intCast(@abs(lit) - 1));
        self.arr[idx].epoch = 0;
        // Get as much safety as possible
        self.arr[idx].ptr = undefined;
    }

    pub fn containsLiteral(self: *@This(), lit: Literal) bool {
        const idx: usize = if (lit > 0) self.one_index + @as(usize, @intCast(lit)) - 1 else @as(usize, @intCast(@abs(lit) - 1));
        return self.arr[idx].epoch == self.epoch;
    }

    pub fn getAt(self: *@This(), comptime T: type, lit: Literal) ?*T {
        const idx: usize = if (lit > 0) self.one_index + @as(usize, @intCast(lit)) - 1 else @as(usize, @intCast(@abs(lit) - 1));
        const frame = self.arr[idx];
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
