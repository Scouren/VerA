//! The high-precision reference `diff-kernels` judges a disagreement by:
//! an `f64` in, the function's value in `f128` (113 bits) out, by series
//! with exact or Cody-Waite argument reduction, so its error (~2^-100
//! relative) is far below the half ulp of `f64` the libraries promise.
//! Zig's own `f128` builtins (`@exp`, `@sin`, ...) are `f64` arithmetic
//! widened, so none is used. A sin/cos/tan argument past 2^50 is reduced
//! by Payne-Hanek against 2/pi to `frac_bits` bits, computed once from
//! Machin's formula in big integers (`twoOverPi`), so the reduction is
//! exact to ~2^-270 for every finite double. Null where the function has
//! no real value.
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

/// Fraction bits of `twoOverPi`: a double's exponent is at most 971 past
/// its 53-bit integer mantissa, so 1300 leave ~270 bits below the point.
const frac_bits = 1300;
// ponytail: computed once and never freed (smp_allocator): the run's lifetime.
var two_over_pi_cache: ?std.math.big.int.Managed = null;

/// The reference value of `name` (a `math` function's name) at `x` (and
/// `y` for `pow`, `atan2`), or null.
pub fn of(comptime name: []const u8, x: f64, y: f64) ?f128 {
    if (std.math.isNan(x) or std.math.isInf(x)) return null;
    const q: f128 = x;
    const E = enum { exp, log, pow, sin, cos, tan, tanh, sinh, cosh, expm1, log1p, atan, log10, asinh, acosh, atanh, atan2, asin, acos, hypot };
    return switch (@field(E, name)) {
        .exp => expQ(q),
        .log => if (x > 0) logQ(q) else null,
        .log10 => if (x > 0) logQ(q) / ln10 else null,
        .pow => powQ(x, y),
        .sin => if (@abs(x) < 0x1p50) sinCosQ(q, false) else hugeSinCos(x, false),
        .cos => if (@abs(x) < 0x1p50) sinCosQ(q, true) else hugeSinCos(x, true),
        .tan => if (@abs(x) < 0x1p50) sinCosQ(q, false) / sinCosQ(q, true) else hugeSinCos(x, false).? / hugeSinCos(x, true).?,
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
        .asin => asinQ(q),
        .acos => if (asinQ(q)) |s| (pio2[0] + pio2[1] + pio2[2]) - s else null,
        // x² and y² are exact in f128 (106 bits), the sum and root round once.
        .hypot => if (std.math.isFinite(y)) @sqrt(q * q + @as(f128, y) * y) else null,
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

/// floor(2^frac_bits * 2/pi), from pi = 16 atan(1/5) - 4 atan(1/239) at
/// 64 guard bits, computed on first use.
fn twoOverPi() *const std.math.big.int.Managed {
    if (two_over_pi_cache) |*t| return t;
    const Big = std.math.big.int.Managed;
    const gpa = std.heap.smp_allocator;
    const p = frac_bits + 64;
    var pi = Big.initSet(gpa, 0) catch @panic("OOM");
    for ([_]struct { u32, i32 }{ .{ 5, 16 }, .{ 239, -4 } }) |nc| {
        var one = Big.initSet(gpa, 1) catch @panic("OOM");
        one.shiftLeft(&one, p) catch @panic("OOM");
        var pow = Big.initSet(gpa, nc[0]) catch @panic("OOM");
        const nn = Big.initSet(gpa, @as(u64, nc[0]) * nc[0]) catch @panic("OOM");
        var term = Big.init(gpa) catch @panic("OOM");
        var rem = Big.init(gpa) catch @panic("OOM");
        var den = Big.init(gpa) catch @panic("OOM");
        var sum = Big.initSet(gpa, 0) catch @panic("OOM");
        // atan(1/n) * 2^p = sum (-1)^k 2^p / ((2k+1) n^(2k+1)); each term
        // floored, so the sum is off by at most its term count (< 2^10).
        var k: u32 = 0;
        while (k < 4 * p) : (k += 1) {
            const odd = Big.initSet(gpa, 2 * k + 1) catch @panic("OOM");
            den.mul(&pow, &odd) catch @panic("OOM");
            term.divFloor(&rem, &one, &den) catch @panic("OOM");
            if (term.eqlZero()) break;
            if (k % 2 == 0) sum.add(&sum, &term) catch @panic("OOM") else sum.sub(&sum, &term) catch @panic("OOM");
            pow.mul(&pow, &nn) catch @panic("OOM");
        }
        const c = Big.initSet(gpa, nc[1]) catch @panic("OOM");
        sum.mul(&sum, &c) catch @panic("OOM");
        pi.add(&pi, &sum) catch @panic("OOM");
    }
    var num = Big.initSet(gpa, 1) catch @panic("OOM");
    num.shiftLeft(&num, frac_bits + 1 + p) catch @panic("OOM");
    var t = Big.init(gpa) catch @panic("OOM");
    var rem = Big.init(gpa) catch @panic("OOM");
    t.divFloor(&rem, &num, &pi) catch @panic("OOM");
    two_over_pi_cache = t;
    return &two_over_pi_cache.?;
}

/// sin(x) or cos(x) for a finite |x| >= 1 (`of` uses it past 2^50): x = m * 2^e exactly, x * 2/pi
/// = m * T / 2^(frac_bits - e); its integer part's low two bits are the
/// quadrant and its fraction, read to 128 bits, the reduced argument.
fn hugeSinCos(x: f64, comptime want_cos: bool) ?f128 {
    if (std.math.isNan(x) or std.math.isInf(x)) return null;
    assert(@abs(x) >= 1); // `of` calls it past 2^50; the test below from 1
    const Big = std.math.big.int.Managed;
    const gpa = std.heap.smp_allocator;
    const bits: u64 = @bitCast(@abs(x));
    const m: u64 = (bits & ((1 << 52) - 1)) | (1 << 52);
    const e: i32 = @as(i32, @intCast(bits >> 52)) - 1075;
    assert(e >= -52 and e < frac_bits - 200);
    const fb: usize = @intCast(frac_bits - e);
    var y = Big.initSet(gpa, m) catch @panic("OOM");
    defer y.deinit();
    y.mul(&y, twoOverPi()) catch @panic("OOM");
    var top = Big.init(gpa) catch @panic("OOM");
    defer top.deinit();
    top.shiftRight(&y, fb - 128) catch @panic("OOM");
    var low = Big.init(gpa) catch @panic("OOM");
    defer low.deinit();
    low.truncate(&top, .unsigned, 130) catch @panic("OOM");
    const w = low.toInt(u130) catch unreachable; // truncated to 130 bits
    var quad: u2 = @truncate(w >> 128);
    var f: f128 = @as(f128, @floatFromInt(@as(u128, @truncate(w)))) * 0x1p-128;
    if (f >= 0.5) {
        f -= 1;
        quad +%= 1;
    }
    const r = f * (pio2[0] + pio2[1] + pio2[2]);
    const q: u2 = if (want_cos) quad +% 1 else quad;
    const v = switch (q) {
        0 => sinSeries(r),
        1 => cosSeries(r),
        2 => -sinSeries(r),
        3 => -cosSeries(r),
    };
    return if (!want_cos and x < 0) -v else v;
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

/// asin(x) = atan(x / sqrt((1 - x)(1 + x))) for |x| < 1, ±pi/2 at ±1.
fn asinQ(x: f128) ?f128 {
    if (@abs(x) > 1) return null;
    if (@abs(x) == 1) return std.math.copysign(pio2[0] + pio2[1] + pio2[2], x);
    return atanQ(x / @sqrt((1 - x) * (1 + x)));
}

fn atan2Q(y: f64, x: f64) ?f128 {
    if (std.math.isNan(x) or std.math.isInf(x) or std.math.isInf(y)) return null;
    const pi: f128 = 2 * (pio2[0] + pio2[1] + pio2[2]);
    // On an axis (C99 F.10.1.4): ±pi/2 on the y axis, ±0 or ±pi on the
    // x axis by the sign of y; the origin's value is a convention.
    if (x == 0 and y != 0) return std.math.copysign(pi / 2, @as(f128, y));
    if (y == 0 and x != 0) return std.math.copysign(if (x > 0) 0 else pi, @as(f128, y));
    if (x == 0 or y == 0) return null;
    const a = atanQ(@as(f128, y) / @as(f128, x));
    if (x > 0) return a;
    return if (y > 0) a + pi else a - pi;
}

test "the big-integer reduction agrees with the four-part pi/2 one below 2^50" {
    // Two independent reductions (Machin's pi in big integers, the 224-bit
    // pio2 constant) must give the same f128 to far below an f64 ulp.
    var prng = std.Random.DefaultPrng.init(0x2f9);
    const r = prng.random();
    for (0..2000) |i| {
        const mag = std.math.ldexp(@as(f64, 1) + r.float(f64), @intCast(i % 49));
        const x = if (r.boolean()) mag else -mag;
        inline for (.{ false, true }) |want_cos| {
            const a = sinCosQ(x, want_cos);
            const b = hugeSinCos(x, want_cos).?;
            try std.testing.expect(@abs(a - b) <= 0x1p-100);
        }
    }
    // sin^2 + cos^2 = 1 past 2^50, where only the big-integer one reaches.
    for (0..200) |i| {
        const x = std.math.ldexp(@as(f64, 1) + r.float(f64), @intCast(50 + i * 4));
        const s = hugeSinCos(x, false).?;
        const c = hugeSinCos(x, true).?;
        try std.testing.expect(@abs(s * s + c * c - 1) <= 0x1p-100);
    }
}
