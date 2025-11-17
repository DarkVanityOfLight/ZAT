const std = @import("std");
const Literal = @import("../variables.zig").Literal;
const Variable = @import("../variables.zig").Variable;

const Entry = struct { epoch: usize, ptr: *anyopaque };

/// An set like structure to keep track of literals
/// arr contains `epoch` at positions where the literal is set
const EpochDict = struct {
    arr: []Entry,
    epoch: usize,

    pub fn addLiteral(self: *@This(), idx: usize, entry: *anyopaque) void {
        self.arr[idx].epoch = self.epoch;
        self.arr[idx].ptr = entry;
    }

    pub fn removeLiteral(self: *@This(), idx: usize) void {
        self.arr[idx].epoch = 0;
        // Get as much safety as possible
        self.arr[idx].ptr = undefined;
    }

    pub fn containsLiteral(self: *@This(), idx: usize) bool {
        return self.arr[idx].epoch == self.epoch;
    }

    pub fn getAt(self: *@This(), comptime T: type, idx: usize) ?*T {
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

pub const LiteralEpochDict = struct {
    dict: EpochDict,
    one_index: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, num_vars: usize) !*@This() {
        const total = (2 * num_vars);
        const arr = try gpa.alloc(Entry, total);
        errdefer gpa.free(arr);

        // Initialize all entries to epoch = 0
        @memset(arr, Entry{ .epoch = 0, .ptr = undefined });

        const set = try gpa.create(@This());
        errdefer gpa.destroy(set);

        set.* = @This(){
            .dict = EpochDict{
                .arr = arr,
                .epoch = 1,
            },
            .one_index = num_vars,
            .gpa = gpa,
        };

        return set;
    }

    pub fn deinit(self: *@This()) void {
        self.gpa.free(self.dict.arr);
        self.gpa.destroy(self);
    }

    inline fn indexOf(self: *@This(), literal: Literal) usize {
        const idx: usize = if (literal > 0) self.one_index + @as(usize, @intCast(literal)) - 1 else @as(usize, @intCast(@abs(literal) - 1));
        return idx;
    }

    pub fn addLiteral(self: *@This(), lit: Literal, entry: *anyopaque) void {
        const idx = self.indexOf(lit);
        self.dict.addLiteral(idx, entry);
    }

    pub fn removeLiteral(self: *@This(), lit: Literal) void {
        const idx = self.indexOf(lit);
        self.dict.removeLiteral(idx);
    }

    pub fn containsLiteral(self: *@This(), lit: Literal) bool {
        const idx = self.indexOf(lit);
        return self.dict.containsLiteral(idx);
    }

    pub fn getAt(self: *@This(), comptime T: type, lit: Literal) ?*T {
        const idx = self.indexOf(lit);
        return self.dict.getAt(T, idx);
    }

    pub fn reset(self: *@This()) void {
        self.dict.reset();
    }
};

pub const VariableEpochDict = struct {
    dict: EpochDict,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, num_vars: usize) !*@This() {
        const total = (num_vars);
        const arr = try gpa.alloc(Entry, total);
        errdefer gpa.free(arr);

        // Initialize all entries to epoch = 0
        @memset(arr, Entry{ .epoch = 0, .ptr = undefined });

        const set = try gpa.create(@This());
        errdefer gpa.destroy(set);

        set.* = @This(){
            .dict = EpochDict{
                .arr = arr,
                .epoch = 0,
            },
            .gpa = gpa,
        };

        return set;
    }

    pub fn deinit(self: *@This()) void {
        self.gpa.free(self.dict.arr);
        self.gpa.destroy(self);
    }

    inline fn indexOf(_: *@This(), variable: Variable) usize {
        return @intCast(variable);
    }

    pub fn addLiteral(self: *@This(), lit: Literal, entry: *anyopaque) void {
        const idx = self.indexOf(lit);
        self.dict.addLiteral(idx, entry);
    }

    pub fn removeLiteral(self: *@This(), lit: Literal) void {
        const idx = self.indexOf(lit);
        self.dict.removeLiteral(idx);
    }

    pub fn containsLiteral(self: *@This(), lit: Literal) bool {
        const idx = self.indexOf(lit);
        return self.dict.containsLiteral(idx);
    }

    pub fn getAt(self: *@This(), comptime T: type, lit: Literal) ?*T {
        const idx = self.indexOf(lit);
        return self.dict.getAt(T, idx);
    }

    pub fn reset(self: *@This()) void {
        self.dict.reset();
    }
};
