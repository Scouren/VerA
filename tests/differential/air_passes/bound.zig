//! The `default_unknown_bound` measurement: the roots `Float` rates
//! `.optimized` at each candidate probe bound, over the generated programs
//! (`gen.zig`) and the hand-built devices (`devices.zig`), and the
//! metamorphic relation the table must obey: a box only shrinks as the
//! bound does, so a root proven at a bound is proven at every smaller one,
//! unless the smaller bound, passed as the host's, rejects the model (a
//! §4.3.2 error under the host's bound rates every root `.strict`).
//! Cites: VAMS-2023 §4.4.
//!
//! Contents:
//! - `pub const bounds: [5]f64`
//! - `pub const Table = struct`
//! - `pub fn measure(gpa: Allocator, n_programs: u32) !Table`
//! - `pub fn print(t: Table) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("air");
const InternPool = @import("intern_pool");
const Diag = @import("vams").Diag;
const gen = @import("gen.zig");
const devices = @import("devices.zig");
const falsify = @import("falsify.zig");
const Float = Air.Float;
const Inst = Air.Inst;

/// The candidate probe bounds, volts or amperes, ascending.
pub const bounds = [_]f64{ 1, 10, 100, 1e3, 1e4 };

/// Per bound, the roots rated `.optimized` and the models rejected; and the
/// roots proven at a bound but neither proven nor rejected at a smaller one
/// (the relation's breaks, which must be none).
pub const Table = struct {
    programs: u32 = 0,
    generated: [bounds.len]u32 = @splat(0),
    rejected: [bounds.len]u32 = @splat(0),
    devices: [bounds.len]std.EnumSet(devices.Kind) = @splat(.empty),
    breaks: u32 = 0,
};

/// One root at one bound.
const Rating = enum { optimized, strict, rejected };

/// Rates every generated program and every device at every bound.
pub fn measure(gpa: Allocator, n_programs: u32) !Table {
    var t: Table = .{};
    var ip = try InternPool.init(gpa);
    defer ip.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(falsify.seed);
    const r = prng.random();
    for (0..n_programs) |_| {
        var p = try gen.generate(gpa, &ip, r);
        defer p.deinit(gpa);
        var params: [gen.params_n]Float.Param = undefined;
        for (&params, p.shapes) |*q, s| q.* = .{ .ranges = gen.ranges(s) };
        var rated: [bounds.len]Rating = undefined;
        for (bounds, &rated, &t.rejected) |b, *o, *n| {
            o.* = try rate(gpa, &ip, p.air, &params, &.{}, p.root, b);
            n.* += @intFromBool(o.* == .rejected);
        }
        t.programs += 1;
        tally(&t, &rated, &t.generated);
    }
    for (std.enums.values(devices.Kind)) |kind| {
        var d = try devices.build(gpa, &ip, kind);
        defer d.deinit(gpa);
        var rated: [bounds.len]Rating = undefined;
        for (bounds, &rated, &t.devices) |b, *o, *set| {
            o.* = try rate(gpa, &ip, d.air, &d.params, d.calls, d.root, b);
            assert(o.* != .rejected);
            if (o.* == .optimized) set.insert(kind);
        }
        var counts: [bounds.len]u32 = @splat(0);
        tally(&t, &rated, &counts);
    }
    assert(t.programs == n_programs);
    return t;
}

/// Prints the table, one row per root family and the devices proven at
/// each bound by name.
pub fn print(t: Table) void {
    std.debug.print("air_passes bound-vs-proven (probe bound: 1, 10, 100, 1e3, 1e4):\n", .{});
    std.debug.print("  generated ({d}):", .{t.programs});
    for (t.generated) |n| std.debug.print(" {d} ({d:.1}%)", .{ n, 100 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(t.programs)) });
    std.debug.print("\n  rejected (an error under the host's bound):", .{});
    for (t.rejected) |n| std.debug.print(" {d}", .{n});
    std.debug.print("\n  devices ({d}):", .{std.enums.values(devices.Kind).len});
    for (t.devices) |set| std.debug.print(" {d}", .{set.count()});
    std.debug.print("\n", .{});
    for (bounds, t.devices) |b, set| {
        std.debug.print("  at {e}:", .{b});
        var it = set.iterator();
        while (it.next()) |k| std.debug.print(" {s}", .{@tagName(k)});
        std.debug.print("\n", .{});
    }
    std.debug.print("  breaks of the relation: {d}\n", .{t.breaks});
}

// ---- private ----

/// How `root` rates with every probe in `[-bound, bound]`, the bound passed
/// as the host's.
fn rate(gpa: Allocator, ip: *const InternPool, air: Air, params: []const Float.Param, calls: []const Air.CallFacts, root: Inst.Ref, bound: f64) !Rating {
    var wip: Diag.Wip = .init(gpa);
    defer wip.deinit();
    var f = try Float.analyze(gpa, air, ip, .{ .params = params, .roots = &.{.{ .refs = &.{root} }}, .calls = calls, .unknown_bound = bound }, &wip);
    defer f.deinit(gpa);
    if (f.error_count != 0) return .rejected;
    return if (f.verdict.modes[0] == .optimized) .optimized else .strict;
}

/// Counts one root's ratings and its breaks of the relation.
fn tally(t: *Table, rated: *const [bounds.len]Rating, counts: *[bounds.len]u32) void {
    for (rated, counts, 0..) |o, *c, k| {
        c.* += @intFromBool(o == .optimized);
        if (o == .optimized and k > 0 and rated[k - 1] == .strict) t.breaks += 1;
    }
}
