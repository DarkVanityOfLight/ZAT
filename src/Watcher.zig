const std = @import("std");
const LiteralEpochDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;
const ClauseMeta = @import("clauses.zig").ClauseMeta;
const Literal = @import("variables.zig").Literal;

const Page = std.array_list.Managed(*ClauseMeta);

const LiteralDict = LiteralEpochDict(Page);

const Self = @This();
book: LiteralDict,

pub fn init(gpa: std.mem.Allocator, num_vars: usize) !Self {
    var book = try LiteralDict.init(gpa, num_vars);
    errdefer book.deinit();

    var initialized_count: usize = 0;
    errdefer {
        for (book.dict.arr[0..initialized_count]) |*entry| {
            entry.value.deinit();
        }
    }

    for (book.dict.arr) |*entry| {
        entry.value = Page.init(gpa);
        entry.epoch = book.dict.epoch;
        initialized_count += 1;
    }

    return Self{
        .book = book,
    };
}

pub fn deinit(self: *@This()) void {
    // 1. Free the memory of every Page (ArrayList)
    for (self.book.dict.arr) |*entry| {
        // We can assume all are initialized because we did so in init()
        entry.value.deinit();
    }
    // 2. Free the dictionary structure itself
    self.book.deinit();
}

pub fn addWatch(self: *@This(), to: Literal, clause: *ClauseMeta) !void {
    const to_list = self.book.get(to).?;
    try to_list.append(clause);
}

pub fn register(self: *@This(), clause: *ClauseMeta) !void {
    try self.addWatch(clause.watch1.?, clause);
    try self.addWatch(clause.watch2.?, clause);
}

// Keep this access directly, since iterator is not removal aware
// IF YOU ARE ITERATING OVER THIS CHECK THAT THE CLAUSES WATCH LITERAL ACTUALLY CONTAINS YOUR LITERAL
pub fn watched(self: *@This(), literal: Literal) *Page {
    return self.book.get(literal).?;
}
