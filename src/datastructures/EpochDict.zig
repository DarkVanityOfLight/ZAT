const std = @import("std");
const Literal = @import("../variables.zig").Literal;
const Variable = @import("../variables.zig").Variable;

/// A generic sparse-set/epoch-based array.
pub fn EpochArray(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The internal storage slot
        pub const Entry = struct { epoch: usize, value: T };

        arr: []Entry,
        epoch: usize,

        /// Sets the value at a specific raw index.
        pub fn set(self: *Self, idx: usize, value: T) void {
            // No bounds check here for performance, wrappers guarantee bounds
            self.arr[idx].epoch = self.epoch;
            self.arr[idx].value = value;
        }

        /// Marks the index as empty/invalid.
        pub fn unset(self: *Self, idx: usize) void {
            self.arr[idx].epoch = 0;
            // We don't need to clear .value, it will be treated as garbage
            // until overwritten because the epoch mismatches.
            self.arr[idx].value = undefined;
        }

        pub fn contains(self: *Self, idx: usize) bool {
            return self.arr[idx].epoch == self.epoch;
        }

        /// Returns a pointer to the value if present, so it can be mutated in place.
        pub fn get(self: *Self, idx: usize) ?*T {
            // We capture the pointer to the entry to avoid copying T
            const entry = &self.arr[idx];
            if (entry.epoch == self.epoch) {
                return &entry.value;
            } else {
                return null;
            }
        }

        /// Returns the value by copy.
        pub fn getValue(self: *Self, idx: usize) ?T {
            if (self.arr[idx].epoch == self.epoch) {
                return self.arr[idx].value;
            }
            return null;
        }

        /// Invalidates all current entries in O(1)
        pub fn reset(self: *Self) void {
            self.epoch += 1;
            // Handle overflow: rare, but if usize wraps, we must clear the array
            if (self.epoch == 0) {
                @memset(self.arr, Entry{ .epoch = 0, .value = undefined });
                self.epoch = 1;
            }
        }
    };
}

pub fn LiteralEpochDict(comptime T: type) type {
    return struct {
        const Self = @This();
        const InternalDict = EpochArray(T);

        dict: InternalDict,
        one_index: usize,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator, num_vars: usize) !*Self {
            // Logic for indexing literals: 2 slots per variable (pos and neg)
            const total = (2 * num_vars);
            const arr = try gpa.alloc(InternalDict.Entry, total);
            errdefer gpa.free(arr);

            // Initialize epochs to 0
            @memset(arr, InternalDict.Entry{ .epoch = 0, .value = undefined });

            const sett = try gpa.create(Self);
            errdefer gpa.destroy(set);

            sett.* = Self{
                .dict = InternalDict{
                    .arr = arr,
                    .epoch = 1,
                },
                .one_index = num_vars,
                .gpa = gpa,
            };

            return sett;
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.dict.arr);
            self.gpa.destroy(self);
        }

        inline fn indexOf(self: *Self, literal: Literal) usize {
            // Ensure literal is not 0 (if 0 is invalid in your logic)
            const idx: usize = if (literal > 0)
                self.one_index + @as(usize, @intCast(literal)) - 1
            else
                @as(usize, @intCast(@abs(literal) - 1));
            return idx;
        }

        pub fn literalOf(self: *Self, index: usize) Literal {
            if (index >= self.one_index) {
                return @intCast((index - self.one_index) + 1);
            } else {
                const l: Literal = @intCast(index + 1);
                return -l;
            }
        }

        pub fn set(self: *Self, lit: Literal, val: T) void {
            const idx = self.indexOf(lit);
            self.dict.set(idx, val);
        }

        pub fn unset(self: *Self, lit: Literal) void {
            const idx = self.indexOf(lit);
            self.dict.unset(idx);
        }

        pub fn contains(self: *Self, lit: ?Literal) bool {
            if (lit) |l| {
                const idx = self.indexOf(l);
                return self.dict.contains(idx);
            }
            return false;
        }

        pub fn get(self: *Self, lit: Literal) ?*T {
            const idx = self.indexOf(lit);
            return self.dict.get(idx);
        }

        pub fn getValue(self: *Self, lit: Literal) ?T {
            const idx = self.indexOf(lit);
            return self.dict.getValue(idx);
        }

        pub fn reset(self: *Self) void {
            self.dict.reset();
        }
    };
}

pub fn VariableEpochDict(comptime T: type) type {
    return struct {
        const Self = @This();
        const InternalDict = EpochArray(T);

        dict: InternalDict,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator, num_vars: usize) !*Self {
            const total = num_vars;
            const arr = try gpa.alloc(InternalDict.Entry, total);
            errdefer gpa.free(arr);

            @memset(arr, InternalDict.Entry{ .epoch = 0, .value = undefined });

            const sett = try gpa.create(Self);
            errdefer gpa.destroy(set);

            sett.* = Self{
                .dict = InternalDict{
                    .arr = arr,
                    .epoch = 1,
                },
                .gpa = gpa,
            };

            return sett;
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.dict.arr);
            self.gpa.destroy(self);
        }

        inline fn indexOf(_: *Self, variable: Variable) usize {
            return @intCast(variable);
        }

        // Renamed from addLiteral to set for clarity, assumes key is Variable
        pub fn set(self: *Self, v: Variable, val: T) void {
            const idx = self.indexOf(v);
            self.dict.set(idx, val);
        }

        pub fn unset(self: *Self, v: Variable) void {
            const idx = self.indexOf(v);
            self.dict.unset(idx);
        }

        pub fn contains(self: *Self, v: Variable) bool {
            const idx = self.indexOf(v);
            return self.dict.contains(idx);
        }

        pub fn get(self: *Self, v: Variable) ?*T {
            const idx = self.indexOf(v);
            return self.dict.get(idx);
        }

        pub fn getValue(self: *Self, v: Variable) ?T {
            const idx = self.indexOf(v);
            return self.dict.getValue(idx);
        }

        pub fn reset(self: *Self) void {
            self.dict.reset();
        }
    };
}
