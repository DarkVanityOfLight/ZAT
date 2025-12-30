/// Container for all solver metrics
const std = @import("std");
const BankStats = @import("Bank.zig").BankStats;
const bank = @import("Bank.zig");
const Self = @This();

conflicts: u64 = 0,
propagations: u64 = 0,
assignments: u64 = 0,
operations: u64 = 0,
restarts: u64 = 0,
start_time: i64 = 0,
max_learned_clauses: u64 = 0,
learned_clauses: u64 = 0,

pub fn init() Self {
    return .{
        .start_time = std.time.milliTimestamp(),
    };
}

pub fn syncWithBank(self: *Self) void {
    const bankStats = bank.current;
    self.conflicts += bankStats.confs;
    self.assignments += bankStats.assigns;
    self.propagations += bankStats.props;
}

/// Formats the statistics for human reading (standard SAT solver style)
pub fn format(
    self: *const Self,
    writer: anytype,
) !void {
    const now = std.time.milliTimestamp();
    const duration_ms = now - self.start_time;
    const duration_s = @as(f64, @floatFromInt(duration_ms)) / 1000.0;

    const c_per_s = if (duration_s > 0) @as(f64, @floatFromInt(self.conflicts)) / duration_s else 0;
    const p_per_s = if (duration_s > 0) @as(f64, @floatFromInt(self.propagations)) / duration_s else 0;

    try writer.print(
        \\c === Solver Statistics ===
        \\c Time         : {d:10.3} s
        \\c Conflicts    : {d:<10} ({d:>.1} /s)
        \\c Propagations : {d:<10} ({d:>.1} /s)
        \\c Assignments  : {d:<10}
        \\c L Clauses    : {d:<10} /{d:<10}
        \\
    , .{
        duration_s,
        self.conflicts,
        c_per_s,
        self.propagations,
        p_per_s,
        self.assignments,
        self.learned_clauses,
        self.max_learned_clauses,
    });
}
