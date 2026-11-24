//! The pack pass's premise, measured: three independent isomorphic chains in
//! one straight-line body (what a device's `eval` holds), written scalar and
//! written packed into vectors. Each body is `noinline` and called once per
//! point, so the loop over points cannot be vectorized for the scalar body:
//! only SLP inside the body could. Three shapes: plain f64 (the photo),
//! values carrying 3 derivative lanes (a device's `Of(m)`), and exp.
//! Oracle: the packed results equal the scalar ones bit for bit (checked).
//! Build: zig build-exe -O ReleaseFast -mcpu=x86_64_v3 --dep gm -Mroot=tools/bench/pack_microbench.zig -Mgm=lib/contract/gm.zig
//! Clauses: none (a measurement).
//!
//! Contents:
//! - `pub fn main() !void`

const std = @import("std");
const gm = @import("gm");

const n_points = 1 << 12;
const reps = 400;
const L = 3; // derivative lanes per value: a 3-unknown device row

const In = struct { a: [12]f64 };
const V4 = @Vector(4, f64);

// A value with derivative lanes, by `family.zig`'s numerics table.
const D = struct {
    v: f64,
    d: @Vector(L, f64),
    fn mul(x: D, y: D) D {
        return .{ .v = x.v * y.v, .d = @mulAdd(@Vector(L, f64), y.d, @splat(x.v), x.d * @as(@Vector(L, f64), @splat(y.v))) };
    }
    fn add(x: D, y: D) D {
        return .{ .v = x.v + y.v, .d = x.d + y.d };
    }
    fn div(x: D, y: D) D {
        const q = x.v / y.v;
        return .{ .v = q, .d = @mulAdd(@Vector(L, f64), y.d, @splat(-q), x.d) * @as(@Vector(L, f64), @splat(1.0 / y.v)) };
    }
};

// Four packed values: v lane k, d lanes [k*L .. k*L+L).
const P = struct {
    v: V4,
    d: @Vector(4 * L, f64),
    fn spread(v: V4) @Vector(4 * L, f64) {
        comptime var mask: [4 * L]i32 = undefined;
        inline for (0..4 * L) |i| mask[i] = @intCast(i / L);
        return @shuffle(f64, v, undefined, mask);
    }
    fn mul(x: P, y: P) P {
        return .{ .v = x.v * y.v, .d = @mulAdd(@Vector(4 * L, f64), y.d, spread(x.v), x.d * spread(y.v)) };
    }
    fn add(x: P, y: P) P {
        return .{ .v = x.v + y.v, .d = x.d + y.d };
    }
    fn div(x: P, y: P) P {
        const q = x.v / y.v;
        return .{ .v = q, .d = @mulAdd(@Vector(4 * L, f64), y.d, spread(-q), x.d) * spread(@as(V4, @splat(1.0)) / y.v) };
    }
    fn gather(xs: [4]D) P {
        var r: P = undefined;
        inline for (0..4) |k| {
            r.v[k] = xs[k].v;
            inline for (0..L) |j| r.d[k * L + j] = xs[k].d[j];
        }
        return r;
    }
    fn lane(x: P, comptime k: usize) D {
        var r: D = .{ .v = x.v[k], .d = undefined };
        inline for (0..L) |j| r.d[j] = x.d[k * L + j];
        return r;
    }
};

const InD = struct { a: [12]D };

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    const ins = try gpa.alloc(In, n_points);
    const insd = try gpa.alloc(InD, n_points);
    for (ins, insd) |*i, *id| for (&i.a, &id.a) |*x, *dx| {
        x.* = 0.5 + r.float(f64);
        dx.* = .{ .v = x.*, .d = .{ r.float(f64), r.float(f64), r.float(f64) } };
    };
    const o1 = try gpa.alloc([3]f64, n_points);
    const o2 = try gpa.alloc([3]f64, n_points);
    const d1 = try gpa.alloc([3]D, n_points);
    const d2 = try gpa.alloc([3]D, n_points);
    const calls: f64 = @floatFromInt(n_points * reps);

    const ps = timeIt(In, [3]f64, plainScalar, ins, o1);
    const pp = timeIt(In, [3]f64, plainPacked, ins, o2);
    for (o1, o2) |x, y| for (x, y) |u, w| if (@as(u64, @bitCast(u)) != @as(u64, @bitCast(w))) return error.PlainMismatch;
    const es = timeIt(In, [3]f64, expScalar, ins, o1);
    const ep = timeIt(In, [3]f64, expPacked, ins, o2);
    for (o1, o2) |x, y| for (x, y) |u, w| if (@as(u64, @bitCast(u)) != @as(u64, @bitCast(w))) return error.ExpMismatch;
    const ds = timeIt(InD, [3]D, derivScalar, insd, d1);
    const dp = timeIt(InD, [3]D, derivPacked, insd, d2);
    for (d1, d2) |x, y| for (x, y) |u, w| {
        if (@as(u64, @bitCast(u.v)) != @as(u64, @bitCast(w.v))) return error.DerivMismatch;
        inline for (0..L) |j| if (@as(u64, @bitCast(u.d[j])) != @as(u64, @bitCast(w.d[j]))) return error.DerivLaneMismatch;
    };
    std.debug.print("shape\tscalar_ns\tpacked_ns\tspeedup\n", .{});
    inline for (.{ .{ "plain f64 (photo)", ps, pp }, .{ "exp chain", es, ep }, .{ "3 derivative lanes", ds, dp } }) |row| {
        const s = @as(f64, @floatFromInt(row[1])) / calls;
        const p = @as(f64, @floatFromInt(row[2])) / calls;
        std.debug.print("{s}\t{d:.2}\t{d:.2}\t{d:.2}x\n", .{ row[0], s, p, s / p });
    }
}

// ---- private ----

noinline fn plainScalar(p: *const In, out: *[3]f64) void {
    const a = p.a;
    out[0] = (a[0] * a[1] + a[2]) / a[3];
    out[1] = (a[4] * a[5] + a[6]) / a[7];
    out[2] = (a[8] * a[9] + a[10]) / a[11];
}

noinline fn plainPacked(p: *const In, out: *[3]f64) void {
    const a = p.a;
    const m: V4 = V4{ a[0], a[4], a[8], a[8] } * V4{ a[1], a[5], a[9], a[9] };
    const q = (m + V4{ a[2], a[6], a[10], a[10] }) / V4{ a[3], a[7], a[11], a[11] };
    out.* = .{ q[0], q[1], q[2] };
}

noinline fn expScalar(p: *const In, out: *[3]f64) void {
    const a = p.a;
    out[0] = gm.exp(a[0] * a[1] + a[2]) / a[3];
    out[1] = gm.exp(a[4] * a[5] + a[6]) / a[7];
    out[2] = gm.exp(a[8] * a[9] + a[10]) / a[11];
}

noinline fn expPacked(p: *const In, out: *[3]f64) void {
    const a = p.a;
    const x = V4{ a[0], a[4], a[8], a[8] } * V4{ a[1], a[5], a[9], a[9] } + V4{ a[2], a[6], a[10], a[10] };
    const q = gm.exp(x) / V4{ a[3], a[7], a[11], a[11] };
    out.* = .{ q[0], q[1], q[2] };
}

noinline fn derivScalar(p: *const InD, out: *[3]D) void {
    const a = p.a;
    out[0] = a[0].mul(a[1]).add(a[2]).div(a[3]);
    out[1] = a[4].mul(a[5]).add(a[6]).div(a[7]);
    out[2] = a[8].mul(a[9]).add(a[10]).div(a[11]);
}

noinline fn derivPacked(p: *const InD, out: *[3]D) void {
    const a = p.a;
    const q = P.gather(.{ a[0], a[4], a[8], a[8] }).mul(P.gather(.{ a[1], a[5], a[9], a[9] }))
        .add(P.gather(.{ a[2], a[6], a[10], a[10] })).div(P.gather(.{ a[3], a[7], a[11], a[11] }));
    out.* = .{ q.lane(0), q.lane(1), q.lane(2) };
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn timeIt(comptime T: type, comptime O: type, f: *const fn (*const T, *O) void, ins: []const T, outs: []O) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t0 = now();
        for (0..reps) |_| for (ins, outs) |*i, *o| f(i, o);
        best = @min(best, now() - t0);
        std.mem.doNotOptimizeAway(outs[outs.len - 1]);
    }
    return best;
}
