const std = @import("std");
const Literal = @import("variables.zig").Literal;

pub const Proof = struct {
    const Self = @This();
    writer: ?*std.Io.Writer,

    pub fn addClause(self: *Self, clause: []const Literal) !void {
        try self.writeClause(null, clause);
    }

    pub fn delClause(self: *Self, clause: []const Literal) !void {
        try self.writeClause("d ", clause);
    }

    fn writeClause(self: *Self, prefix: ?[]const u8, clause: []const Literal) !void {
        // Unwrap the writer. If null, just return.
        const w = self.writer orelse return;

        if (prefix) |p| try w.writeAll(p);
        for (clause) |lit| {
            try w.print("{} ", .{lit});
        }
        try w.writeAll("0\n");
    }
};
