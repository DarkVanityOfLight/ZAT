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

pub fn modifyWatch(self: *@This(), lit: ?Literal, clause: *ClauseMeta, add: bool) !void {
    if (lit) |l| {
        // get(l) returns ?*Page. Since we pre-filled them, we can safely unwrap .?
        const watch_list = self.book.get(l).?;

        if (add) {
            try watch_list.append(clause);
        } else {
            // Find and remove (O(N) for the length of the watch list)
            for (watch_list.items, 0..) |entry, i| {
                if (entry == clause) {
                    _ = watch_list.swapRemove(i);
                    break;
                }
            }
        }
    }
}

pub fn register(self: *@This(), clause: *ClauseMeta) !void {
    try self.modifyWatch(clause.watch1, clause, true);
    try self.modifyWatch(clause.watch2, clause, true);
}

pub fn unregister(self: *@This(), clause: *ClauseMeta) !void {
    try self.modifyWatch(clause.watch1, clause, false);
    try self.modifyWatch(clause.watch2, clause, false);
}

pub fn watched(self: *@This(), literal: Literal) *Page {
    return self.book.get(literal).?;
}

pub fn moveWatch(self: *@This(), from: Literal, to: Literal, clause: *ClauseMeta) !void {
    const to_list = self.book.get(to).?;
    try to_list.append(clause);

    // Remove from old list
    const from_list = self.book.get(from).?;
    for (from_list.items, 0..) |entry, i| {
        if (entry == clause) {
            _ = from_list.swapRemove(i);
            return;
        }
    }
    // Should not be reachable if logic is correct
    std.debug.assert(false);
}
