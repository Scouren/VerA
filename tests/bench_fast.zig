//! The fast-math benchmark and its check (`zig build bench-fast`,
//! ReleaseFast): the new pipeline's devices of `tests/bench/*.va`, strict
//! and versioned (§11.9: the box check, then the fast body), evaluated
//! (`eval`, every lane carried) at the same seeded points, all inside the
//! box. The versioned device runs twice: on the reference family, whose
//! `Fast` twin carries the fast flags into every primitive, and on the same
//! family without `Fast`, where `.optimized` reaches only the body's own
//! operators. Prints the median and the least time per evaluation of each
//! over `reps` interleaved runs, the points whose bits the fast body moved,
//! the largest ulp distance between strict and fast values and lanes, and
//! the largest error relative to its row's scale (the largest magnitude of
//! the row's value and lanes at that point), which stays meaningful where
//! a lane cancels to near zero and its ulp count does not.
//! The check: no device is slower versioned (with `Fast`) than strict by
//! more than `noise` on the medians, since codegen versions only the
//! bodies where fast-math pays (DeclGen's `transcendental`).
//! No LRM clause: a measurement held to a rule of thumb, not to the LRM.
//!
//! Contents: `main` only; the family decls `NoFast(S)` re-exports (`V`,
//! `Of`, `con`, `probe`, `sel`) are pub for the device to read.

const std = @import("std");
const contract = @import("contract");
const math = @import("std_kernels").math;

const names = [_][]const u8{ "diode", "mosfet", "abs", "tanh_amp", "mos_exp" };
const devices = .{ @import("diode"), @import("mosfet"), @import("abs"), @import("tanh_amp"), @import("mos_exp") };
const versioned = .{ @import("diode_v"), @import("mosfet_v"), @import("abs_v"), @import("tanh_amp_v"), @import("mos_exp_v") };
const points = 4096;
const reps = 101;
/// How much slower than strict a versioned device's median may run: the
/// spread of the strict medians run to run on a quiet machine.
const noise = 0.03;

pub fn main(init: std.process.Init) !void {
    std.debug.print("ns per eval, median (least) of {d} runs x {d} points\n", .{ reps, points });
    std.debug.print("{s:<8} {s:>16} {s:>16} {s:>16} {s:>7} {s:>6} {s:>9} {s:>9}\n", .{ "device", "strict", "versioned", "versioned+Fast", "gain", "moved", "max ulps", "max rel" });
    var slower: u32 = 0;
    inline for (devices, versioned, names) |D, Dv, name| slower += @intFromBool(try bench(D, Dv, name, init.io));
    if (slower != 0) {
        std.debug.print("bench-fast: {d} device(s) slower versioned than strict past {d}%\n", .{ slower, noise * 100 });
        return error.VersionedSlower;
    }
}

// ---- private ----

/// Times device `D` and its versioned twin `Dv`; returns whether the
/// versioned one ran slower than `noise` allows.
fn bench(comptime D: type, comptime Dv: type, name: []const u8, io: std.Io) !bool {
    const n = contract.nU(D);
    const S = contract.RefFamily(f64, &std.simd.iota(u8, n), .{ .math = math });
    const S0 = NoFast(S);
    const Vf = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .math = math });
    var m: D.Model = .{};
    if (@hasDecl(D, "derive")) D.derive(Vf, &m);
    if (@hasDecl(D, "setup")) D.setup(Vf, &m);
    var inst: D.Instance = .{};
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, &inst);
    // The two devices come from one source: the same card.
    comptime std.debug.assert(@sizeOf(D.Model) == @sizeOf(Dv.Model));
    const mv: *const Dv.Model = @ptrCast(&m);
    var instv: Dv.Instance = .{};
    const sim: contract.SimState = .{};
    // Inside the box: every unknown in [-0.4, 1.2], the default card.
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    var xs: [points][n]f64 = undefined;
    for (&xs) |*x| for (x) |*e| {
        e.* = prng.random().float(f64) * 1.6 - 0.4;
    };
    var ulps: u64 = 0;
    var rel: f64 = 0;
    var moved: u32 = 0;
    for (&xs) |*x| {
        const a = D.eval(S, x, &m, &inst, sim);
        const b = Dv.eval(S, x, mv, &instv, sim);
        var apart: u64 = 0;
        inline for (0..n) |i| {
            var scale = @abs(a[i].val());
            inline for (0..n) |u| scale = @max(scale, @abs(a[i].ddxAt(u)));
            apart = @max(apart, ulp(a[i].val(), b[i].val()));
            if (scale > 0) rel = @max(rel, @abs(a[i].val() - b[i].val()) / scale);
            inline for (0..n) |u| {
                apart = @max(apart, ulp(a[i].ddxAt(u), b[i].ddxAt(u)));
                if (scale > 0) rel = @max(rel, @abs(a[i].ddxAt(u) - b[i].ddxAt(u)) / scale);
            }
        }
        ulps = @max(ulps, apart);
        moved += @intFromBool(apart != 0);
    }
    var t: [3][reps]u64 = undefined;
    for (0..reps) |r| {
        t[0][r] = try timeEval(D, S, &xs, &m, &inst, sim, io);
        t[1][r] = try timeEval(Dv, S0, &xs, mv, &instv, sim, io);
        t[2][r] = try timeEval(Dv, S, &xs, mv, &instv, sim, io);
    }
    var med: [3]f64 = undefined;
    var least: [3]f64 = undefined;
    for (&t, &med, &least) |*row, *md, *ls| {
        std.mem.sort(u64, row, {}, std.sort.asc(u64));
        md.* = @as(f64, @floatFromInt(row[reps / 2])) / points;
        ls.* = @as(f64, @floatFromInt(row[0])) / points;
    }
    std.debug.print("{s:<8} {d:>7.2} ({d:>6.2}) {d:>7.2} ({d:>6.2}) {d:>7.2} ({d:>6.2}) {d:>6.1}% {d:>6} {d:>9} {e:>9.2}\n", .{ name, med[0], least[0], med[1], least[1], med[2], least[2], (med[0] - med[2]) / med[0] * 100.0, moved, ulps, rel });
    return med[2] > med[0] * (1.0 + noise);
}

/// Family `S` without its `Fast` trait.
fn NoFast(comptime S: type) type {
    return struct {
        pub const V = S.V;
        pub const Of = S.Of;
        pub const con = S.con;
        pub const probe = S.probe;
        pub const sel = S.sel;
    };
}

/// Nanoseconds for one pass of `eval` over every point.
fn timeEval(comptime D: type, comptime S: type, xs: anytype, m: *const D.Model, inst: *D.Instance, sim: contract.SimState, io: std.Io) !u64 {
    const n = contract.nU(D);
    const t0 = std.Io.Clock.awake.now(io);
    for (xs) |*x| {
        const r = D.eval(S, x, m, inst, sim);
        inline for (0..n) |i| std.mem.doNotOptimizeAway(r[i]);
    }
    return @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
}

/// The distance in ulps between `a` and `b` (0 when both are the same bits
/// or both NaN).
fn ulp(a: f64, b: f64) u64 {
    if (std.math.isNan(a) and std.math.isNan(b)) return 0;
    const ia: i64 = @bitCast(a);
    const ib: i64 = @bitCast(b);
    const oa = if (ia < 0) std.math.minInt(i64) - ia else ia;
    const ob = if (ib < 0) std.math.minInt(i64) - ib else ib;
    return @intCast(@min(@abs(@as(i128, oa) - ob), std.math.maxInt(u64)));
}
