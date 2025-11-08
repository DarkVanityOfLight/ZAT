const std = @import("std");

fn read_dimacs(file: []u8) !void {
    const f = try std.fs.cwd().openFile(file, .{ .mode = .read_only });

    f.reader(buffer: []u8)
}
