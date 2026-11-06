//! `Air.interp`'s tangent: correctly rounded but for f128's own last bits,
//! for every finite double. An argument past pi/4 is reduced by Payne-Hanek
//! against 1280 bits of 2/pi, exact for every finite double (its exponent
//! is at most 971 past its 53-bit mantissa, which leaves ~250 bits below
//! the point); the reduced angle's tangent is the f128 quotient of sin and
//! cos, which compiler_rt computes to f128 accuracy there. compiler_rt's own
//! f128 reduction loses bits past ~2^120 (diff-air found it: up to 0.563 ulp
//! at 1e93 where the old fold is correctly rounded); `@tan` on f64 is within
//! 1 ulp only.
//! Cites: VAMS-2023 §4.3 (Table 4-14 `tan`); the 2/pi digits are Machin's
//! pi, checked by `tests/differential/kernels/reference.zig`, which computes
//! them independently in big integers.
//!
//! Contents:
//! - `pub fn tan(x: f64) f64`

const std = @import("std");
const assert = std.debug.assert;

/// floor(2^1280 * 2/pi), little-endian 64-bit limbs.
const two_over_pi = [20]u64{
    0xf0cfbc209af4361d, 0x56033046fc7b6bab, 0x6bfb5fb11f8d5d08, 0x3d0739f78a5292ea,
    0x7527bac7ebe5f17b, 0x4f463f669e5fea2d, 0x6d367ecf27cb09b7, 0xef2f118b5a0a6d1f,
    0x1ff897ffde05980f, 0x9c845f8bbdf9283b, 0x3991d639835339f4, 0xe99c7026b45f7e41,
    0xe88235f52ebb4484, 0xfe1deb1cb129a73e, 0x06492eea09d1921c, 0xb7246e3a424dd2e0,
    0xfe5163abdebbc561, 0xdb6295993c439041, 0xfc2757d1f534ddc0, 0xa2f9836e4e441529,
};
const frac_bits = 64 * two_over_pi.len;
/// pi/2 as an f128 head and tail (226 bits together).
const pio2_hi: f128 = 0x1921fb54442d18469898cc51701b8.0p-112;
const pio2_lo: f128 = 0x7344a4093822299f31d0082efa98.0p-225;

/// tan(x), one rounding from a value within f128's accuracy of the exact one.
pub fn tan(x: f64) f64 {
    if (!std.math.isFinite(x) or @abs(x) < 0.78) return @floatCast(@sin(@as(f128, x)) / @cos(@as(f128, x)));
    const bits: u64 = @bitCast(@abs(x));
    const m: u64 = (bits & ((1 << 52) - 1)) | (1 << 52);
    const e: i32 = @as(i32, @intCast(bits >> 52)) - 1075;
    assert(e >= -53 and e <= 971);
    // m * 2/pi * 2^1280, exact: 21 limbs.
    var p: [two_over_pi.len + 1]u64 = undefined;
    var carry: u64 = 0;
    for (two_over_pi, 0..) |t, k| {
        const w = @as(u128, m) * t + carry;
        p[k] = @truncate(w);
        carry = @intCast(w >> 64);
    }
    p[two_over_pi.len] = carry;
    // x * 2/pi = p * 2^(e - frac_bits): its binary point is at bit `pt`.
    const pt: usize = @intCast(@as(i32, frac_bits) - e);
    assert(pt >= 128 and pt + 2 <= 64 * p.len);
    const frac = @as(u128, wordAt(&p, pt - 128)) | @as(u128, wordAt(&p, pt - 64)) << 64;
    var quad: u2 = @truncate(wordAt(&p, pt));
    var f: f128 = @as(f128, @floatFromInt(frac)) * 0x1p-128;
    if (f >= 0.5) {
        f -= 1;
        quad +%= 1;
    }
    const r = f * pio2_hi + f * pio2_lo;
    const s = @sin(r);
    const c = @cos(r);
    const t: f128 = if (quad & 1 == 0) s / c else -c / s;
    return @floatCast(if (x < 0) -t else t);
}

// ---- private ----

/// The 64 bits of `p` from bit `at` up (past the top reads zeros).
fn wordAt(p: []const u64, at: usize) u64 {
    assert(at < 64 * p.len);
    const k = at / 64;
    const sh: u6 = @intCast(at % 64);
    const hi: u64 = if (k + 1 < p.len) p[k + 1] else 0;
    return if (sh == 0) p[k] else (p[k] >> sh) | (hi << @intCast(64 - @as(u7, sh)));
}

test "tan: the identities at quadrant edges and a huge argument" {
    // tan(pi/4) rounds to 1 within one ulp; tan(-x) = -tan(x).
    try std.testing.expectApproxEqAbs(@as(f64, 1), tan(std.math.pi / 4.0), 2e-16);
    try std.testing.expectEqual(-tan(1e300), tan(-1e300));
    try std.testing.expectEqual(@as(f64, 0), tan(0));
    try std.testing.expect(std.math.isNan(tan(std.math.inf(f64))));
}
