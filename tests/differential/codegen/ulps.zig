//! diff-codegen's distances between two devices' values: bits, ulps, and a
//! row's scale for the fast-math bound near zero (`codegen.zig`).
//! No LRM clause: IEEE 754 representation only.
//!
//! Contents:
//! - `pub fn apart(a: f64, b: f64) u64`
//! - `pub fn rowScale(out: []const f64, n: usize, i: usize) f64`
//! - `pub fn sameBits(a: f64, b: f64) bool`

const std = @import("std");

/// How many representable doubles lie between `a` and `b`; max for a NaN
/// against a number or a sign change.
pub fn apart(a: f64, b: f64) u64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.maxInt(u64);
    if ((a < 0) != (b < 0)) return if (a == 0 and b == 0) 0 else std.math.maxInt(u64);
    const x: i64 = @bitCast(@abs(a));
    const y: i64 = @bitCast(@abs(b));
    return @abs(x - y);
}

/// The scale of output `i`'s row in `out` (`dyn.zig`'s layout: `n` rows,
/// their `n x n` Jacobian, `n` reactive rows, theirs): the largest
/// magnitude of the row's value and lanes.
pub fn rowScale(out: []const f64, n: usize, i: usize) f64 {
    const half = n + n * n;
    const base = if (i < half) 0 else half;
    const j = i - base;
    const row = if (j < n) j else (j - n) / n;
    var scale = @abs(out[base + row]);
    for (out[base + n + row * n ..][0..n]) |d| scale = @max(scale, @abs(d));
    return scale;
}

/// Whether `a` and `b` are the same bits, NaN as NaN.
pub fn sameBits(a: f64, b: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}
