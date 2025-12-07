const std = @import("std");
// Assuming variables.zig exists. If testing standalone, replace with: const Literal = i32;
const Literal = @import("variables.zig").Literal;

const Lemma = []Literal;

const Step = union(enum) {
    Add: Lemma,
    Del: Lemma,
};

pub const Proof = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(Step),

    pub fn init(allocator: std.mem.Allocator) Proof {
        return Proof{
            .allocator = allocator,
            .steps = std.ArrayList(Step).empty,
        };
    }

    pub fn deinit(self: *Proof) void {
        for (self.steps.items) |step| {
            switch (step) {
                .Add => |lemma| self.allocator.free(lemma),
                .Del => |lemma| self.allocator.free(lemma),
            }
        }
        self.steps.deinit(self.allocator);
    }

    pub fn addClause(self: *Proof, clause: Lemma) !void {
        const copy = try self.allocator.alloc(Literal, clause.len);
        @memcpy(copy, clause);
        try self.steps.append(self.allocator, .{ .Add = copy });
    }

    pub fn delClause(self: *Proof, clause: Lemma) !void {
        const copy = try self.allocator.alloc(Literal, clause.len);
        @memcpy(copy, clause);
        try self.steps.append(self.allocator, .{ .Del = copy });
    }

    fn writeClause(writer: anytype, prefix: ?[]const u8, clause: Lemma) !void {
        if (prefix) |p| {
            try writer.writeAll(p);
        }

        for (clause) |lit| {
            // Assumes Literal is an integer or has a formatter
            try writer.print("{d} ", .{lit});
        }
        try writer.writeAll("0\n");
    }

    pub fn writeToFile(
        self: *Proof,
        path: []const u8,
    ) !void {
        const fs = std.fs;
        var file = try fs.cwd().createFile(path, .{});
        defer file.close();

        var buffer: [4096]u8 = undefined;

        var buffered = file.writer(&buffer);

        const writer = &buffered.interface;

        for (self.steps.items) |s| {
            switch (s) {
                .Add => |cl| try writeClause(writer, null, cl),
                .Del => |cl| try writeClause(writer, "d ", cl),
            }
        }

        // Don't forget to flush the buffered writer!
        try writer.flush();
    }
};
