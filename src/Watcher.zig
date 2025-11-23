const std = @import("std");
const LiteralDict = @import("datastructures/EpochDict.zig").LiteralEpochDict;
const ClauseMeta = @import("clauses.zig").ClauseMeta;
const Literal = @import("variables.zig").Literal;

const Page = std.array_list.Managed(*ClauseMeta);

pub const Watcher = struct {
    book: *LiteralDict,
    gpaa: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, num_vars: usize) !@This() {
        const me = @This(){
            .book = try LiteralDict.init(gpa, num_vars),
            .gpaa = std.heap.ArenaAllocator.init(gpa),
        };

        for (me.book.dict.arr) |*e| {
            const page_ptr = try gpa.create(Page);
            page_ptr.* = Page.init(gpa);
            e.ptr = page_ptr;
            e.epoch = 1;
        }

        return me;
    }

    // TODO:
    pub fn deinit() void {}

    pub fn modifyWatch(self: *@This(), lit: ?Literal, clause: *ClauseMeta, add: bool) !void {
        if (lit) |l| {
            if (self.book.getAt(Page, l)) |watch| {
                if (add) {
                    try watch.append(clause);
                } else {
                    for (watch.items, 0..) |entry, i| {
                        if (entry == clause) {
                            _ = watch.swapRemove(i);
                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn register(self: *@This(), clause: *ClauseMeta) !void {
        try self.modifyWatch(clause.watch1, clause, true);
        try self.modifyWatch(clause.watch2, clause, true);
    }

    pub fn unregister(self: *@This(), clause: *ClauseMeta) void {
        self.modifyWatch(clause.watch1, clause, false);
        self.modifyWatch(clause.watch2, clause, false);
    }

    pub fn watched(self: *@This(), literal: Literal) *Page {
        return self.book.getAt(Page, literal).?;
    }
};
