//! `bench`'s public API: the runners it writes.
//! Cites: docs/rewrite/exe.md (a runner's imports).
//!
//! Contents: tests only.

const std = @import("std");
const Air = @import("air");
const InternPool = @import("intern_pool");
const std_sim = @import("std_sim");
const bench = @import("../bench.zig");

/// Every module a runner may import: Zig's own, itself, and what
/// docs/rewrite/exe.md allows; no `frontend`, `base`, `diag`, old
/// `kernels` or old `sim`.
const allowed = [_][]const u8{ "std", "root", "contract", "std_kernels", "std_sim", "device" };

// ---- private ----

/// A program of one `probe` row per `(a, b)` terminal pair; `b` empty is `V(a)`.
fn probeProgram(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std_sim.Program {
    var b: std_sim.Builder = .init(arena);
    for (pairs) |t| {
        const probe: std_sim.Program.Probe = .{ .a = try b.string(t[0]), .b = if (t[1].len == 0) .empty else try b.string(t[1]) };
        _ = try b.expr(.probe, std_sim.Program.Ty.real_ty, try b.extraOf(probe), 0);
    }
    return b.finish();
}

test "a runner imports only contract, std_kernels, std_sim and the device" {
    // Oracle: the rule of docs/rewrite/exe.md, read off the rendered text.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = [_][]const u8{
        "//! bias V(p) = 1\n",
        "//! param r = 2\n//! sweep V(p) = 1, 2\n//! time 0, 1n, 2n\n//! noise none\n//! acstim none\n//! limit V(p) = 0 -> V(p) = 0.1\n",
        "//! psweep r = 1, 2\n//! seed none\n//! meta none\n//! qsite none\n//! abstol V(p) = 1e-6\n",
    };
    // The fixed-grid runner for each source, and the §8 mixed one for the first.
    const mixed: bench.Digital = .{ .program = "\x00", .names = &.{.{ .path = "clk", .slot = 0, .real = false }} };
    for (sources, 0..) |src, k| for ([_]?bench.Digital{ null, if (k == 0) mixed else null }) |m| {
        const s = try bench.Spec.parse(arena, src, null);
        var aw: std.Io.Writer.Allocating = .init(arena);
        try bench.writeRunner(&aw.writer, "t", &s.bench, .{ .title = "", .mixed = m });
        var it = std.mem.splitSequence(u8, aw.written(), "@import(\"");
        _ = it.next();
        var n: u32 = 0;
        while (it.next()) |rest| : (n += 1) {
            const name = rest[0 .. std.mem.findScalar(u8, rest, '"') orelse rest.len];
            const ok = for (allowed) |a| {
                if (std.mem.eql(u8, a, name)) break true;
            } else false;
            if (!ok) std.debug.print("a runner imports `{s}`\n", .{name});
            try std.testing.expect(ok);
        }
        // `std`, `std_sim` and `device` at least.
        try std.testing.expect(n >= 3);
    };
}

test "bench.digital resolves each probe terminal: a named branch, a net with ground, an unknown hierarchical name refused" {
    // Oracle: the device rows below, by construction. VAMS §7.3.6.3 `V(b)`
    // of a named branch is `x[hi] - x[lo]`; `V(n1, n2)` is two nets, each
    // against ground; §6.7.1 a hierarchical name naming neither is E0901.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ip: InternPool = try .init(gpa);
    defer ip.deinit(gpa);
    var device: Air.Device = .{};
    defer device.deinit(gpa);
    for ([_][]const u8{ "p", "u.n", "u.m" }) |name| {
        try device.nodes.append(gpa, .{ .name = try ip.getString(gpa, name), .kind = .net, .of = .none, .discipline = .empty, .instance = .none });
    }
    try device.branches.append(gpa, .{ .name = try ip.getString(gpa, "u.sense"), .hi = @fromBackingInt(1), .lo = @fromBackingInt(2), .instance = .none });

    const good = try probeProgram(arena, &.{ .{ "u.sense", "" }, .{ "u.n", "p" }, .{ "u.sense", "" }, .{ "g", "" } });
    var unresolved: []const u8 = "";
    const d = try bench.digital(arena, &good, &.{}, &device, &ip, &unresolved);
    const want = [_]bench.Digital.Probe{
        .{ .name = "u.sense", .hi = 1, .lo = 2 },
        .{ .name = "u.n", .hi = 1, .lo = null },
        .{ .name = "p", .hi = 0, .lo = null },
        // A simple name the device lacks is ground, as the old runner read it.
        .{ .name = "g", .hi = null, .lo = null },
    };
    try std.testing.expectEqualDeep(@as([]const bench.Digital.Probe, &want), d.probes);

    const bad = try probeProgram(arena, &.{ .{ "p", "" }, .{ "u.nosuch", "" } });
    try std.testing.expectError(error.UnknownProbe, bench.digital(arena, &bad, &.{}, &device, &ip, &unresolved));
    try std.testing.expectEqualStrings("u.nosuch", unresolved);
}
