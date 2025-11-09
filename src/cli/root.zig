const std = @import("std");
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const zli = @import("zli");
const run = @import("run.zig").run;

pub fn build(writer: *Writer, reader: *Reader, allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(writer, reader, allocator, .{
        .name = "ZAT",
        .description = "Zig SAT",
        .version = .{ .major = 0, .minor = 0, .patch = 1, .pre = null, .build = null },
    }, run);

    try root.addPositionalArg(.{
        .name = "DIMACS_CNF",
        .description = "The formula to solve given in DIMACS CNF",
        .required = true,
        .variadic = false,
    });

    try root.addCommands(&.{});

    return root;
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}
