//! The `diff-kernels` oracle (docs/rewrite/kernels.md): `std_kernels`
//! against what it replaces. (1) Every kernel against its old self: each
//! function `lib/kernels` exposes to devices or folds, and each function of
//! the old kernel text (`device.kernel_text`, compiled by `kernels_text.zig`
//! as a device's `h.zig` is), called with the same arguments as its port,
//! over the specials and 10^5 seeded draws, compared bit for bit (string
//! kernels byte for byte). (2) Gompute against gm: every function `gm`
//! provides against `std_kernels.math`, each difference judged by an f128
//! reference so the log says which side is wrong. A name that differs
//! passes only when a line of `kernels.xfail` names it with a bound in ulps
//! that covers the largest difference seen; a line whose name never differs
//! fails the run (an unexpected pass).
//! Cites: none of its own (`kernels/*.zig` name theirs).
//!
//! Contents: none public; tests only.

const std = @import("std");
const g = @import("kernels/gen.zig");
const scalar = @import("kernels/scalar.zig");
const math = @import("kernels/math.zig");
const state = @import("kernels/state.zig");

/// One line of `kernels.xfail`: `<name> <ulps> <reason>`.
const Allowed = struct { name: []const u8, ulps: u64, line: u32 };

// ---- private ----

/// The lines of `text`: blank lines and `#` comments skipped. Caller owns
/// the slice; its names point into `text`.
fn parseXfail(gpa: std.mem.Allocator, text: []const u8) ![]Allowed {
    var out: std.ArrayList(Allowed) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |raw| {
        line += 1;
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, l, " \t");
        const name = f.next() orelse return error.BadXfail;
        const bound = f.next() orelse return error.BadXfail;
        const ulps = if (std.mem.eql(u8, bound, "any")) std.math.maxInt(u64) else try std.fmt.parseInt(u64, bound, 10);
        if (f.next() == null) return error.BadXfail; // every line gives its reason
        try out.append(gpa, .{ .name = name, .ulps = ulps, .line = line });
    }
    return out.toOwnedSlice(gpa);
}

test "diff-kernels: std_kernels against lib/kernels, the old kernel text and gm" {
    const gpa = std.testing.allocator;
    var rep: g.Report = .{ .gpa = gpa };
    defer rep.rows.deinit(gpa);
    scalar.run(&rep);
    math.run(&rep);
    try state.run(&rep, gpa);

    const allowed = try parseXfail(gpa, @embedFile("kernels.xfail"));
    defer gpa.free(allowed);
    var failures: u32 = 0;
    var compared: u64 = 0;
    var listed_differ: u32 = 0;
    for (rep.rows.keys(), rep.rows.values()) |name, row| {
        compared += row.compared;
        const a = for (allowed) |a| {
            if (std.mem.eql(u8, a.name, name)) break a;
        } else null;
        if (row.differ == 0) continue;
        std.debug.print("{s}: {d} of {d} differ, max {d} ulp; e.g. {s}", .{ name, row.differ, row.compared, row.max, row.example[0..row.example_len] });
        if (row.judged != 0) std.debug.print("; against f128 ({d} judged): old max {d:.3} ulp, closer {d}; new max {d:.3} ulp, closer {d}", .{ row.judged, row.old_err, row.old_closer, row.new_err, row.new_closer });
        std.debug.print("\n", .{});
        if (a) |line| {
            listed_differ += 1;
            if (row.max <= line.ulps) continue;
            std.debug.print("  FAIL: kernels.xfail:{d} allows {d} ulp\n", .{ line.line, line.ulps });
        } else std.debug.print("  FAIL: not in kernels.xfail\n", .{});
        failures += 1;
    }
    for (allowed) |a| {
        const row = rep.rows.get(a.name);
        if (row != null and row.?.differ != 0) continue;
        std.debug.print("kernels.xfail:{d}: `{s}` no longer differs ({s}): remove the line\n", .{ a.line, a.name, if (row == null) "never compared" else "agrees" });
        failures += 1;
    }
    std.debug.print("diff-kernels: {d} names, {d} comparisons, {d} listed differences, {d} failures\n", .{ rep.rows.count(), compared, listed_differ, failures });
    try std.testing.expect(rep.rows.count() > 300);
    try std.testing.expectEqual(@as(u32, 0), failures);
}
