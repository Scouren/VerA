//! The high-precision reference `diff-kernels` judges a disagreement by:
//! an `f64` in, the function's value in `f128` (113 bits) out, by series
//! with exact or Cody-Waite argument reduction, so its error (~2^-100
//! relative) is far below the half ulp of `f64` the libraries promise.
//! Zig's own `f128` builtins (`@exp`, `@sin`, ...) are `f64` arithmetic
//! widened, so none is used. Null where the reference does not claim its
//! accuracy (a sin/cos argument past 2^50, where the reduction's pi runs
//! out) or the function has no real value.
//! Cites: C99 F.10 (the special cases are not judged here: a special both
//! libraries disagree on is read by eye from the run's log).
//!
//! Contents:
//! - `pub fn of(comptime name: []const u8, x: f64, y: f64) ?f128`
//! - `pub fn ulpErr(got: f64, ref: f128) f64`

const std = @import("std");
const assert = std.debug.assert;

const ln2: f128 = 0xb17217f7d1cf79abc9e3b39803f3.0p-112;
const ln10: f128 = 0x935d8dddaaa8ac16ea56d62b82d3.0p-110;
/// pi/2 in four 56-bit parts: k·Pi is exact for |k| < 2^57, so the
/// reduction keeps ~224 bits of pi/2.
const pio2 = [4]f128{
    0x6487ed5110b461.0p-54,
    0xd313198a2e037.0p-109,
    0x39a252049c1115.0p-168,
    -0x60ce2ff7d10567.0p-225,
};

/// The reference value of `name` (a `math` function's name) at `x` (and
/// `y` for `pow`, `atan2`), or null.
pub fn of(comptime name: []const u8, x: f64, y: f64) ?f128 {
    if (std.math.isNan(x) or std.math.isInf(x)) return null;
    const q: f128 = x;
    const E = enum { exp, log, pow, sin, cos, tan, tanh, sinh, cosh, expm1, log1p, atan, log10, asinh, acosh, atanh, atan2 };
    return switch (@field(E, name)) {
        .exp => expQ(q),
        .log => if (x > 0) logQ(q) else null,
        .log10 => if (x > 0) logQ(q) / ln10 else null,
        .pow => powQ(x, y),
        .sin => if (@abs(x) < 0x1p50) sinCosQ(q, false) else null,
        .cos => if (@abs(x) < 0x1p50) sinCosQ(q, true) else null,
        .tan => if (@abs(x) < 0x1p50) sinCosQ(q, false) / sinCosQ(q, true) else null,
        .sinh => sinhQ(q),
        .cosh => (expQ(@abs(q)) + expQ(-@abs(q))) / 2,
        .tanh => if (@abs(x) > 40) std.math.copysign(@as(f128, 1), q) else sinhQ(q) / ((expQ(@abs(q)) + expQ(-@abs(q))) / 2),
        .expm1 => expm1Q(q),
        .log1p => if (x > -1) log1pQ(q) else null,
        .atan => atanQ(q),
        .asinh => std.math.copysign(log1pQ(@abs(q) + q * q / (1 + @sqrt(1 + q * q))), q),
        .acosh => if (x >= 1) log1pQ((q - 1) + @sqrt((q - 1) * (q + 1))) else null,
        .atanh => if (@abs(x) < 1) log1pQ(2 * q / (1 - q)) / 2 else null,
        .atan2 => atan2Q(x, y),
    };
}

/// |got - ref| in units of the last place of the double nearest ref.
pub fn ulpErr(got: f64, ref: f128) f64 {
    const rd: f64 = @floatCast(ref);
    if (std.math.isInf(rd) or std.math.isNan(got)) return if (@as(f128, got) == ref) 0 else std.math.inf(f64);
    const e = @max(std.math.ilogb(if (rd == 0) std.math.floatMin(f64) else rd) - 52, -1074);
    return @floatCast(@abs(@as(f128, got) - ref) / std.math.ldexp(@as(f128, 1.0), e));
}

// ---- private ----

fn expQ(t: f128) f128 {
    if (t > 12000) return std.math.inf(f128);
    if (t < -12000) return 0;
    const k = @round(t / ln2);
    const r = t - k * ln2;
    var term: f128 = 1;
    var sum: f128 = 1;
    var n: f128 = 1;
    while (n < 40) : (n += 1) {
        term = term * r / n;
        sum += term;
    }
    return std.math.ldexp(sum, @intFromFloat(k));
}

fn expm1Q(t: f128) f128 {
    if (@abs(t) > 0.5) return expQ(t) - 1;
    var term: f128 = t;
    var sum: f128 = t;
    var n: f128 = 2;
    while (n < 45) : (n += 1) {
        term = term * t / n;
        sum += term;
    }
    return sum;
}

fn logQ(x: f128) f128 {
    assert(x > 0);
    const fr = std.math.frexp(x);
    var m = fr.significand;
    var e: f128 = @floatFromInt(fr.exponent);
    if (m < 0.70710678) {
        m *= 2;
        e -= 1;
    }
    return 2 * atanhSeries((m - 1) / (m + 1)) + e * ln2;
}

fn log1pQ(x: f128) f128 {
    // 1 + x is exact in f128 for an f64 x with |x| >= 2^-60; below, the
    // series in x itself.
    if (@abs(x) < 0x1p-20) {
        var term = x;
        var sum: f128 = 0;
        var k: f128 = 1;
        while (k < 12) : (k += 1) {
            sum += term / k;
            term *= -x;
        }
        return sum;
    }
    return logQ(1 + x);
}

/// atanh(u) = u + u^3/3 + ..., |u| <= 0.172.
fn atanhSeries(u: f128) f128 {
    const uu = u * u;
    var term = u;
    var sum: f128 = 0;
    var k: f128 = 1;
    while (k < 140) : (k += 2) {
        sum += term / k;
        term *= uu;
    }
    return sum;
}

fn powQ(x: f64, y: f64) ?f128 {
    if (std.math.isNan(y) or std.math.isInf(y) or x == 0) return null;
    if (x > 0) return expQ(@as(f128, y) * logQ(x));
    if (y != @trunc(y)) return null;
    const mag = expQ(@as(f128, y) * logQ(-@as(f128, x)));
    const odd = @abs(y) < 0x1p53 and @mod(y, 2) != 0;
    return if (odd) -mag else mag;
}

fn sinhQ(q: f128) f128 {
    if (@abs(q) > 0.5) return (expQ(q) - expQ(-q)) / 2;
    var term = q;
    var sum = q;
    var n: f128 = 1;
    while (n < 30) : (n += 1) {
        term = term * q * q / ((2 * n) * (2 * n + 1));
        sum += term;
    }
    return sum;
}

fn sinCosQ(x: f128, comptime want_cos: bool) f128 {
    const k = @round(x / pio2[0]);
    var r = x;
    for (pio2) |p| r -= k * p;
    const ki: i64 = @intFromFloat(@mod(k, 4));
    const quad: i64 = if (want_cos) @mod(ki + 1, 4) else ki;
    const v = switch (quad) {
        0 => sinSeries(r),
        1 => cosSeries(r),
        2 => -sinSeries(r),
        else => -cosSeries(r), // else: quad is 3
    };
    return v;
}

fn sinSeries(r: f128) f128 {
    var term = r;
    var sum = r;
    var n: f128 = 1;
    while (n < 30) : (n += 1) {
        term = -term * r * r / ((2 * n) * (2 * n + 1));
        sum += term;
    }
    return sum;
}

fn cosSeries(r: f128) f128 {
    var term: f128 = 1;
    var sum: f128 = 1;
    var n: f128 = 1;
    while (n < 30) : (n += 1) {
        term = -term * r * r / ((2 * n - 1) * (2 * n));
        sum += term;
    }
    return sum;
}

fn atanQ(x: f128) f128 {
    const pi_2: f128 = pio2[0] + pio2[1] + pio2[2];
    if (@abs(x) > 1) return std.math.copysign(pi_2, x) - atanQ(1 / x);
    // Halve the angle twice: atan(x) = 2·atan(x / (1 + sqrt(1 + x²))).
    var t = x;
    for (0..3) |_| t = t / (1 + @sqrt(1 + t * t));
    const tt = t * t;
    var term = t;
    var sum: f128 = 0;
    var k: f128 = 1;
    while (k < 80) : (k += 2) {
        sum += term / k;
        term *= -tt;
    }
    return 8 * sum;
}

fn atan2Q(y: f64, x: f64) ?f128 {
    if (std.math.isNan(x) or std.math.isInf(x) or std.math.isInf(y)) return null;
    if (x == 0 or y == 0) return null;
    const pi: f128 = 2 * (pio2[0] + pio2[1] + pio2[2]);
    const a = atanQ(@as(f128, y) / @as(f128, x));
    if (x > 0) return a;
    return if (y > 0) a + pi else a - pi;
}
