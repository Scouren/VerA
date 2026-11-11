//! diff-codegen's distances between two devices' values: bits, ulps, and a
//! row's scale for the fast-math bound near zero (`codegen.zig`).
//! No LRM clause: IEEE 754 representation only.
//!
//! Contents:
//! - `pub fn apart(a: f64, b: f64) u64`
//! - `pub fn rowScale(out: []const f64, n: usize, i: usize) f64`
//! - `pub fn sameBits(a: f64, b: f64) bool`
//! - `pub fn extra(j: usize, n: usize) struct { []const u8, usize }`

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

/// What value `j` past the rows of `dyn.zig`'s output is, and its index in
/// its table (a (row, col) branch is row·n + col).
pub fn extra(j: usize, n: usize) struct { []const u8, usize } {
    const names = [_][]const u8{ "nextBreakpoint", "pendingBreakpoint", "bound_step" };
    if (j < names.len) return .{ names[j], 0 };
    const k = j - names.len;
    const tables = [_][]const u8{ "noise PSD at 1 Hz, branch", "noise PSD at 1 kHz, branch", "noise PSD at 1 MHz, branch", "AC stimulus re, branch", "AC stimulus im, branch" };
    return .{ tables[k / (n * n)], k % (n * n) };
}
