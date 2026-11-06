//! `diff-air-passes`' transfer falsifier: each §4.3 library function's
//! `Interval.unary` / `Interval.binary` against the device's values
//! (`interp.deviceLib`, the `std_kernels` math diff-kernels holds to the
//! device bit for bit), at operand intervals drawn from the specials and
//! seeded random ends, every value at the ends, beside them and inside held
//! to the result. The generated programs (`falsify.zig`) rarely run a
//! library function at its operand's extreme member, where a margin is
//! decided; this sweep does on every interval.
//! Cites: VAMS-2023 §4.3.1 (Table 4-14), §4.3.2 (Table 4-15).
//!
//! Contents:
//! - `pub const Plant = enum { none, interp_ends }`
//! - `pub fn sweep(plant: Plant) u64`: the values outside their interval

const std = @import("std");
const math = std.math;
const Air = @import("air");
const interp = Air.interp;
const Interval = Air.Interval;
const Tag = Air.Inst.Tag;

/// What the sweep holds the device's values against.
pub const Plant = enum {
    /// `Interval`'s transfer.
    none,
    /// The interval the interpreter's own math gives at the operand's ends,
    /// no margin: what an Interval sound only for `interp` would draw.
    interp_ends,
};

const unary = [_]Tag{ .exp, .expm1, .ln, .ln1p, .log10, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh, .atan, .asin, .acos };
const binary = [_]Tag{ .pow, .hypot, .atan2 };

/// Intervals per function.
const intervals = 100_000;

/// Returns how many device values fell outside their interval (one example
/// printed per function).
pub fn sweep(plant: Plant) u64 {
    var prng = std.Random.DefaultPrng.init(0x7_2A45_FE12);
    const r = prng.random();
    var outside: u64 = 0;
    inline for (unary) |t| outside += unarySweep(t, plant, r);
    if (plant == .none) inline for (binary) |t| {
        outside += binarySweep(t, r);
    };
    return outside;
}

// ---- private ----

fn unarySweep(comptime t: Tag, plant: Plant, r: std.Random) u64 {
    var outside: u64 = 0;
    for (0..intervals) |_| {
        const a = draw(r);
        const b = draw(r);
        const iv: Interval = .{ .lo = @min(a, b), .hi = @max(a, b) };
        const claim = switch (plant) {
            .none => Interval.unary(t, .{ .iv = iv, .nan = false }),
            .interp_ends => ends(t, iv) orelse continue,
        };
        var pts: [8]f64 = undefined;
        for (points(iv, r, &pts)) |x| {
            const y = interp.deviceLib(t, x, 0).?;
            if (math.isNan(y) and claim.nan) continue;
            if (claim.iv.contains(y)) continue;
            if (outside == 0) std.debug.print("transfer {s}: {s} at {e} in [{e}, {e}]: device {e} outside [{e}, {e}]\n", .{ @tagName(plant), @tagName(t), x, iv.lo, iv.hi, y, claim.iv.lo, claim.iv.hi });
            outside += 1;
        }
    }
    return outside;
}

fn binarySweep(comptime t: Tag, r: std.Random) u64 {
    var outside: u64 = 0;
    for (0..intervals) |_| {
        const xa = draw(r);
        const xb = draw(r);
        const ya = draw(r);
        const yb = draw(r);
        const x: Interval = .{ .lo = @min(xa, xb), .hi = @max(xa, xb) };
        const y: Interval = .{ .lo = @min(ya, yb), .hi = @max(ya, yb) };
        const claim = Interval.binary(t, .{ .iv = x, .nan = false }, .{ .iv = y, .nan = false });
        var xp: [8]f64 = undefined;
        var yp: [8]f64 = undefined;
        for (points(x, r, &xp)) |u| for (points(y, r, &yp)) |v| {
            const z = interp.deviceLib(t, u, v).?;
            if (math.isNan(z) and claim.nan) continue;
            if (claim.iv.contains(z)) continue;
            if (outside == 0) std.debug.print("transfer: {s} at {e} {e}: device {e} outside [{e}, {e}]\n", .{ @tagName(t), u, v, z, claim.iv.lo, claim.iv.hi });
            outside += 1;
        };
    }
    return outside;
}

/// The interval `interp`'s own math gives at `iv`'s ends, no margin, or
/// null where the ends do not bound it (a NaN end, or cosh, acos: not
/// increasing).
fn ends(comptime t: Tag, iv: Interval) ?Interval.Abstract {
    if (t == .cosh or t == .acos) return null;
    const lo = (interp.unary(t, .{ .real = iv.lo }) catch unreachable).real; // a real unary tag has no error
    const hi = (interp.unary(t, .{ .real = iv.hi }) catch unreachable).real;
    if (math.isNan(lo) or math.isNan(hi)) return null;
    return .{ .iv = .{ .lo = lo, .hi = hi }, .nan = false };
}

/// An end: a special one time in six, else a real of
/// any magnitude near the functions' interesting ranges.
fn draw(r: std.Random) f64 {
    const specials = [_]f64{ 0, -0.0, 1, -1, 0.5, -0.5, 2, 709.78, -745.2, 1e-300, math.inf(f64), -math.inf(f64) };
    return switch (r.uintLessThan(u8, 6)) {
        0 => specials[r.uintLessThan(usize, specials.len)],
        1 => (r.float(f64) - 0.5) * 4,
        2 => (r.float(f64) - 0.5) * 60,
        3 => (r.float(f64) - 0.5) * 1500,
        4 => math.ldexp(r.float(f64) - 0.5, r.intRangeAtMost(i32, -60, 60)),
        else => @bitCast(r.int(u64) & 0x7fef_ffff_ffff_ffff | (r.int(u64) & 0x8000_0000_0000_0000)),
    };
}

/// `iv`'s ends, the doubles beside them inward, and random members.
fn points(iv: Interval, r: std.Random, buf: *[8]f64) []const f64 {
    buf[0] = iv.lo;
    buf[1] = iv.hi;
    buf[2] = math.nextAfter(f64, iv.lo, iv.hi);
    buf[3] = math.nextAfter(f64, iv.hi, iv.lo);
    for (buf[4..]) |*p| {
        const f = r.float(f64);
        p.* = if (math.isFinite(iv.lo) and math.isFinite(iv.hi)) iv.lo + (iv.hi - iv.lo) * f else buf[r.uintLessThan(usize, 4)];
        p.* = math.clamp(p.*, iv.lo, iv.hi);
    }
    return buf;
}
