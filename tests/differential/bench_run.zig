//! `vera-next --run` end to end over benches whose transcript is derived by
//! hand (docs/rewrite/exe.md): a resistor `I(p,n) <+ V(p,n)/r` swept and
//! re-carded, every residual row and Jacobian entry checked against Ohm's
//! law. The device prints nothing of its own, so the check does not wait on
//! the device's §9.4 display phase, and a runner that drops, repeats or
//! reorders a point, or writes the wrong card, fails it.
//! Cites: VAMS-2023 §3.4 (the card), §5.6 (the residual), §8.2 (a swept
//! parameter is its own sub-task).
//!
//! Contents: tests only.

const std = @import("std");
const Io = std.Io;
const options = @import("comp_options");

const resistor =
    \\`include "disciplines.vams"
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
    \\
;

// ---- private ----

/// Runs `vera-next --run res.va` over `resistor` plus `directives` in a
/// fresh directory and returns its stderr (the transcript), in `arena`.
fn run(arena: std.mem.Allocator, directives: []const u8) ![]const u8 {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "res.va", .data = try std.mem.concat(arena, u8, &.{ resistor, directives }) });
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const exe = try Io.Dir.cwd().realPathFileAlloc(io, options.vera_next, arena);
    const r = try std.process.run(arena, io, .{ .argv = &.{ exe, "--run", "--allow=W0650", "res.va" }, .cwd = .{ .path = cwd } });
    if (!r.term.success()) {
        std.debug.print("vera-next --run failed ({any}):\n{s}\n", .{ r.term, r.stderr });
        return error.RunFailed;
    }
    return r.stderr;
}

/// One operating point's block, as the runner prints it: the bias `v` on
/// `p` (`n` is the reference), then `res[p] = v/r`, `res[n] = -v/r` and the
/// Jacobian `±1/r`, every number as `{e:.6}`.
fn point(arena: std.mem.Allocator, n: u32, v: f64, r: f64) ![]const u8 {
    const g = 1.0 / r;
    return std.fmt.allocPrint(arena,
        \\--- point {d} ---
        \\  x[p] = {e:.6}
        \\  x[n] = {e:.6}
        \\  res[p] = {e:.6}
        \\    d res[p]/d x[p] = {e:.6}
        \\    d res[p]/d x[n] = {e:.6}
        \\  res[n] = {e:.6}
        \\    d res[n]/d x[p] = {e:.6}
        \\    d res[n]/d x[n] = {e:.6}
        \\
    , .{ n, v, @as(f64, 0), v * g, g, -g, -v * g, -g, g });
}

test "a sweep runs every point in order, each residual Ohm's law" {
    // Oracle: Ohm's law by hand. r = 2 from the card, V(p) = 1, 2, 4 and
    // V(n) tied to 0, so I(p,n) = 0.5, 1, 2 leaves p and enters n.
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const got = try run(arena, "//! param r = 2\n//! sweep V(p) = 1, 2, 4\n");
    const want = try std.mem.concat(arena, u8, &.{ "=== res ===\n", try point(arena, 0, 1, 2), try point(arena, 1, 2, 2), try point(arena, 2, 4, 2) });
    try std.testing.expectEqualStrings(want, got);
}

test "a psweep gives each point its own card (§8.2)" {
    // Oracle: Ohm's law by hand at V(p) = 3 for r = 1, 3, 6.
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const got = try run(arena, "//! bias V(p) = 3\n//! psweep r = 1, 3, 6\n");
    const want = try std.mem.concat(arena, u8, &.{ "=== res ===\n", try point(arena, 0, 3, 1), try point(arena, 1, 3, 3), try point(arena, 2, 3, 6) });
    try std.testing.expectEqualStrings(want, got);
}
