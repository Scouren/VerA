//! diff-rtlil's tiebreaker where the two RTLIL texts differ: Yosys reads
//! each, elaborates it from its top (`hierarchy -auto-top; proc;
//! flatten`), and proves the two tops equivalent (`equiv_make`,
//! `equiv_simple`, `equiv_induct`, `equiv_status -assert`). Yosys is the
//! oracle and is required: a run that cannot start it fails, never skips.
//! Clauses: none (an equivalence of two netlists).
//!
//! Contents:
//! - `pub fn equivalent(arena: Allocator, io: Io, yosys: []const u8, work: []const u8, gold: []const u8, gate: []const u8) !?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Null when Yosys proves RTLIL `gate` equivalent to `gold`, else why not
/// (the last lines of its log). Writes both into `work`, removed after.
/// `error.YosysMissing` when `yosys` cannot be run.
pub fn equivalent(arena: Allocator, io: Io, yosys: []const u8, work: []const u8, gold: []const u8, gate: []const u8) !?[]const u8 {
    assert(gold.len != 0 and gate.len != 0);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};
    const g = try std.fs.path.join(arena, &.{ work, "gold.il" });
    const n = try std.fs.path.join(arena, &.{ work, "gate.il" });
    try cwd.writeFile(io, .{ .sub_path = g, .data = gold });
    try cwd.writeFile(io, .{ .sub_path = n, .data = gate });
    const script = try std.fmt.allocPrint(arena,
        \\read_rtlil {s}; hierarchy -auto-top; proc; flatten; opt_clean; rename -top gold; design -stash gold;
        \\read_rtlil {s}; hierarchy -auto-top; proc; flatten; opt_clean; rename -top gate; design -stash gate;
        \\design -copy-from gold -as gold gold; design -copy-from gate -as gate gate;
        \\equiv_make gold gate equiv; hierarchy -top equiv; equiv_simple -seq 4; equiv_induct -seq 4; equiv_status -assert
    , .{ g, n });
    const r = std.process.run(arena, io, .{ .argv = &.{ yosys, "-q", "-p", script } }) catch |e| switch (e) {
        error.FileNotFound => return error.YosysMissing,
        else => return e,
    };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (ok) return null;
    const log = try std.mem.concat(arena, u8, &.{ r.stdout, r.stderr });
    return log[log.len -| 400..];
}
