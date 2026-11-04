//! `std_sim.mixed`'s spine against a fake solver over hand-built programs.
//!
//! Contents (test support, the fake solver's `run` interface):
//! - `Fake.setInputs`, `Fake.snapshot`, `Fake.latch`, `Fake.solveAt`, `Fake.probe`, `Fake.finish`

const std = @import("std");
const State = @import("../State.zig");
const Program = @import("../Program.zig");
const analog = @import("../analog.zig");
const time = @import("../time.zig");
const run = @import("../mixed.zig").run;

/// Test support: an analog side that reads one discrete slot (-1 for x)
/// and records every solve and every finished point.
const Fake = struct {
    slot: u32,
    input: i64 = -1,
    solves: std.ArrayList(Point) = .empty,
    points: std.ArrayList(Point) = .empty,
    gpa: std.mem.Allocator,
    const Point = struct { t: f64, dt: f64, v: i64, first: bool, last: bool };

    pub fn setInputs(f: *Fake, dig: *State, fired: u64) !void {
        _ = fired;
        const word = dig.p.slots.items(.word)[f.slot];
        f.input = if (dig.x[word] != 0) -1 else @intCast(dig.v[word]);
    }
    pub fn snapshot(_: *Fake, _: *State) !void {}
    pub fn latch(_: *Fake) !void {}
    pub fn solveAt(f: *Fake, t: f64, dt: f64, first: bool, last: bool) !void {
        try f.solves.append(f.gpa, .{ .t = t, .dt = dt, .v = f.input, .first = first, .last = last });
    }
    pub fn probe(_: *Fake, _: ?f64, _: []const u8, _: ?[]const u8) !f64 {
        return 0;
    }
    pub fn finish(f: *Fake) !void {
        try f.points.append(f.gpa, f.solves.items[f.solves.items.len - 1]);
    }
};

test "§7.3.6.5 the solve at t reads the greatest tick <= t; §8.4.7 an implicit D2A between points is a point" {
    // Oracle: the old spine's first test (lib/sim/mixed/run.zig), by hand:
    // `code = 1; #10 code = 5; #10 code = 9;` at 1 ns ticks, solved at
    // 5, 10, 15, 20, 25 ns, plus a write at 7 ns off the grid.
    const Builder = @import("../Builder.zig");
    const Ty = Program.Ty;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .init(a);
    try b.times.append(a, .{ .scale = try time.Scale.init(.s, .s, .s), .unit_exp = 0 });
    try b.scopes.append(a, .{ .parent = 0, .name = try b.string("m"), .index = null, .time = 0 });
    const ty = Ty.int(4, false);
    const code = try b.slot(ty, &.{0}, &.{0xf});
    const place = try b.extraOf(Program.Place{ .kind = .slot, .a = code });
    const d32 = Ty.int(32, true);
    _ = try b.inst(.assign, place, try b.int(ty, 1), 0);
    _ = try b.inst(.delay, try b.int(d32, 7), 0, 0);
    _ = try b.inst(.assign, place, try b.int(ty, 3), 0);
    _ = try b.inst(.delay, try b.int(d32, 3), 0, 0);
    _ = try b.inst(.assign, place, try b.int(ty, 5), 0);
    _ = try b.inst(.delay, try b.int(d32, 10), 0, 0);
    _ = try b.inst(.assign, place, try b.int(ty, 9), 0);
    _ = try b.inst(.stop, 0, 0, 0);
    try b.starts.append(a, .{ .pc = 0 });
    const p = b.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    var st: State = try .init(a, &p, &out.writer);
    try analog.watchAnalog(&st, code);
    var f: Fake = .{ .slot = code, .gpa = a };
    try run(Fake, &f, &st, .{ .times = &.{ 5e-9, 10e-9, 15e-9, 20e-9, 25e-9 }, .tick = 1e-9 });
    const want = [_][2]f64{ .{ 5e-9, 1 }, .{ 7e-9, 3 }, .{ 10e-9, 5 }, .{ 15e-9, 5 }, .{ 20e-9, 9 }, .{ 25e-9, 9 } };
    try std.testing.expectEqual(want.len, f.points.items.len);
    for (want, f.points.items) |w, pt| {
        try std.testing.expectApproxEqAbs(w[0], pt.t, 1e-18);
        try std.testing.expectEqual(@as(i64, @intFromFloat(w[1])), pt.v);
    }
    // The first point is the DC point and the last carries final_step.
    try std.testing.expect(f.points.items[0].first and f.points.items[0].dt == 0);
    try std.testing.expect(f.points.items[5].last and !f.points.items[4].last);
}
