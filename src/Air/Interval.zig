//! The Air passes' abstract value: a real interval with open or closed ends
//! and the one hole a divisor proof needs, plus a transfer per value tag (an
//! operand's `Abstract` in, the result's out). Pure arithmetic: no Air walk,
//! no allocation, no diagnostics. Every transfer is sound for
//! `Air/interp.zig`'s semantics: its bound is the value `interp` computes
//! at the operand's bound (`interp.unary`/`binary`), and the falsification
//! oracle (tests/differential/air_passes.zig) holds every interval against
//! every value a run defines. An integer's interval holds `@floatFromInt`
//! of it, which is monotone, so an integer fact closes its ends.
//! Cites: VAMS-2023 §3.2, §3.4.2, §4.2.1.1, §4.2.1.2, §4.2.4, §4.3.1
//! (Table 4-14), §4.3.2 (Table 4-15); IEEE 1364-2005 §5.1.5.
//!
//! Contents:
//! - `pub const Interval = @This()` (fields `lo`, `hi`, `lo_open`, `hi_open`, `nonzero`)
//! - `pub const top: Interval`, `pub const i32_range: Interval`, `pub const i64_range: Interval`
//! - `pub const Abstract = struct { iv: Interval, finite: bool }`
//! - `pub const Range = struct`
//! - `pub fn point(x: f64) Interval`
//! - `pub fn bounded(i: Interval) bool`, `pub fn isEmpty(i: Interval) bool`, `pub fn excludesInf(i: Interval) bool`
//! - `pub fn gt(i: Interval, k: f64) bool`, `ge`, `lt`, `le`, `pub fn excludesZero(i: Interval) bool`
//! - `pub fn meet(a: Interval, b: Interval) Interval`, `pub fn join(a: Interval, b: Interval) Interval`
//! - `pub fn widen(old: Interval, new: Interval) Interval`
//! - `pub fn contains(i: Interval, x: f64) bool`
//! - `pub fn fromRanges(ranges: []const Range, integer: bool) Interval`
//! - `pub fn unary(tag: Air.Inst.Tag, a: Abstract) Abstract`
//! - `pub fn binary(tag: Air.Inst.Tag, x: Abstract, y: Abstract) Abstract`
//! - `pub fn integer(tag: Air.Inst.Tag, x: Interval, y: Interval) Interval`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Air = @import("../Air.zig");
const interp = @import("interp.zig");
const Tag = Air.Inst.Tag;

/// File-as-struct. `top` is `[-inf, inf]`, the "no evidence" element. NaN
/// never is a bound: a NaN constant is `top`, and a transfer answers `top`
/// for a NaN endpoint. Empty (`lo > hi`) is unreachable and satisfies every
/// domain vacuously. A predicate is sound, not exact: `true` is a proof
/// about every member, `false` only the absence of one. An interval says
/// nothing about NaN: that is `Abstract.finite`'s.
pub const Interval = @This();

lo: f64 = -math.inf(f64),
hi: f64 = math.inf(f64),
/// The bound itself is excluded (§3.4.2 `(`/`)`); likewise `hi_open`.
lo_open: bool = false,
hi_open: bool = false,
/// §3.4.2 `exclude 0` on an otherwise unbounded range: the one hole a
/// §4.2.4 divisor proof needs.
nonzero: bool = false,

/// `[-inf, inf]`: no evidence.
pub const top: Interval = .{};
/// §3.2's 32-bit integers.
pub const i32_range: Interval = .{ .lo = -2147483648.0, .hi = 2147483647.0 };
/// An `i64`, as the interpreter and the device carry an integer.
pub const i64_range: Interval = .{ .lo = -0x1p63, .hi = 0x1p63 };

/// A value's abstract state: its interval for the domain proofs, and the
/// separate fact "is a finite double" that sets the float mode.
pub const Abstract = struct { iv: Interval, finite: bool };

/// One §3.4.2 value range of a parameter, its bounds folded literally
/// (null: a bound that does not fold, which proves nothing).
pub const Range = struct {
    kind: enum { from, exclude },
    lo: ?f64,
    hi: ?f64,
    lo_inclusive: bool = true,
    hi_inclusive: bool = true,
};

comptime {
    assert(@sizeOf(Interval) == 24);
}

/// Returns `[x, x]`, or `top` for NaN.
pub fn point(x: f64) Interval {
    if (math.isNan(x)) return top;
    const r: Interval = .{ .lo = x, .hi = x };
    assert(r.contains(x));
    assert(r.bounded() == math.isFinite(x));
    return r;
}

/// Returns whether both bounds are finite.
pub fn bounded(i: Interval) bool {
    const r = math.isFinite(i.lo) and math.isFinite(i.hi);
    if (r) assert(i.excludesInf());
    return r;
}

/// Returns whether no value satisfies the bounds. A `nonzero` `[0, 0]`
/// has no member either but reads non-empty.
pub fn isEmpty(i: Interval) bool {
    const r = i.lo > i.hi or (i.lo == i.hi and (i.lo_open or i.hi_open));
    if (r) assert(!(i.lo < i.hi));
    return r;
}

/// Returns whether ±inf is no member; an open infinite bound excludes it.
pub fn excludesInf(i: Interval) bool {
    const lo_ok = math.isFinite(i.lo) or (i.lo == -math.inf(f64) and i.lo_open);
    const hi_ok = math.isFinite(i.hi) or (i.hi == math.inf(f64) and i.hi_open);
    if (lo_ok) assert(i.lo != math.inf(f64));
    return lo_ok and hi_ok;
}

/// Returns whether every member x satisfies x > k.
pub fn gt(i: Interval, k: f64) bool {
    const r = i.lo > k or (i.lo == k and i.lo_open);
    if (r) assert(i.ge(k));
    return r;
}

/// Returns whether every member x satisfies x >= k.
pub fn ge(i: Interval, k: f64) bool {
    const r = i.lo >= k;
    if (!r) assert(!(i.lo > k));
    return r;
}

/// Returns whether every member x satisfies x < k.
pub fn lt(i: Interval, k: f64) bool {
    const r = i.hi < k or (i.hi == k and i.hi_open);
    if (r) assert(i.le(k));
    return r;
}

/// Returns whether every member x satisfies x <= k.
pub fn le(i: Interval, k: f64) bool {
    const r = i.hi <= k;
    if (!r) assert(!(i.hi < k));
    return r;
}

/// Returns whether 0 is no member (a sign, or the `exclude 0` hole).
pub fn excludesZero(i: Interval) bool {
    const r = i.nonzero or i.gt(0) or i.lt(0);
    if (r) assert(!i.contains(0));
    return r;
}

/// Returns the intersection, exactly: guard facts apply this way.
pub fn meet(a: Interval, b: Interval) Interval {
    var r = a;
    if (b.lo > r.lo) {
        r.lo = b.lo;
        r.lo_open = b.lo_open;
    } else if (b.lo == r.lo) r.lo_open = r.lo_open or b.lo_open;
    if (b.hi < r.hi) {
        r.hi = b.hi;
        r.hi_open = b.hi_open;
    } else if (b.hi == r.hi) r.hi_open = r.hi_open or b.hi_open;
    r.nonzero = r.nonzero or b.nonzero;
    assert(!(r.lo < a.lo)); // negated: a NaN range literal must not trip it
    assert(!(r.hi > b.hi));
    return r;
}

/// Returns the convex hull: a block result, a slot's merge and a `from`
/// range list combine this way.
pub fn join(a: Interval, b: Interval) Interval {
    if (a.isEmpty()) return b;
    if (b.isEmpty()) return a;
    var r = a;
    if (b.lo < r.lo) {
        r.lo = b.lo;
        r.lo_open = b.lo_open;
    } else if (b.lo == r.lo) r.lo_open = r.lo_open and b.lo_open;
    if (b.hi > r.hi) {
        r.hi = b.hi;
        r.hi_open = b.hi_open;
    } else if (b.hi == r.hi) r.hi_open = r.hi_open and b.hi_open;
    r.nonzero = r.nonzero and b.nonzero;
    assert(!(r.lo > a.lo));
    assert(!(r.hi < b.hi));
    return r;
}

/// Returns `old ∇ new` for a loop head: `new` (which covers `old`), with
/// every end that moved pushed to infinity, so a chain of widenings
/// stabilises after each end moved once.
pub fn widen(old: Interval, new: Interval) Interval {
    if (old.isEmpty()) return new;
    var r = new;
    if (new.lo < old.lo or (new.lo == old.lo and old.lo_open and !new.lo_open)) r = .{ .lo = -math.inf(f64), .hi = r.hi, .hi_open = r.hi_open, .nonzero = r.nonzero };
    if (new.hi > old.hi or (new.hi == old.hi and old.hi_open and !new.hi_open)) r = .{ .lo = r.lo, .lo_open = r.lo_open, .hi = math.inf(f64), .nonzero = r.nonzero };
    assert(!(r.lo > new.lo));
    assert(!(r.hi < new.hi));
    return r;
}

/// Returns whether `x` is a member: the definition every predicate and
/// transfer is tested against.
pub fn contains(i: Interval, x: f64) bool {
    if (i.nonzero and x == 0) return false;
    const above = x > i.lo or (x == i.lo and !i.lo_open);
    const below = x < i.hi or (x == i.hi and !i.hi_open);
    if (above) assert(!math.isNan(x));
    return above and below;
}

/// Returns a §3.4.2 parameter's ranges as one interval: the hull of its
/// `from` ranges, with an `exclude` range subtracted only where it clips an
/// end, and the `nonzero` hole when it removes 0. A `from` bound that does
/// not fold proves nothing (`top`); an `integer` parameter is met with §3.2's
/// 32 bits.
pub fn fromRanges(ranges: []const Range, integer_param: bool) Interval {
    var iv: Interval = from: {
        var acc: ?Interval = null;
        for (ranges) |r| {
            if (r.kind != .from) continue;
            const one: Interval = .{ .lo = r.lo orelse break :from top, .hi = r.hi orelse break :from top, .lo_open = !r.lo_inclusive, .hi_open = !r.hi_inclusive };
            acc = if (acc) |a| a.join(one) else one;
        }
        break :from acc orelse top;
    };
    for (ranges) |r| {
        if (r.kind != .exclude) continue;
        const lo = r.lo orelse continue;
        const hi = r.hi orelse continue;
        // §3.4.2: "Parentheses, ( and ), indicate exclusion of the end
        // points from the value range": `exclude (0:5)` still admits 0.
        if ((lo < 0 and hi > 0) or (lo == 0 and r.lo_inclusive) or (hi == 0 and r.hi_inclusive)) iv.nonzero = true;
        // An exclusion clips an end only if it removes that end itself.
        const covers_lo = lo < iv.lo or (lo == iv.lo and (r.lo_inclusive or iv.lo_open));
        const covers_hi = hi > iv.hi or (hi == iv.hi and (r.hi_inclusive or iv.hi_open));
        if (covers_lo and hi >= iv.lo and hi <= iv.hi) {
            iv.lo_open = r.hi_inclusive or (hi == iv.lo and iv.lo_open);
            iv.lo = hi;
        } else if (covers_hi and lo <= iv.hi and lo >= iv.lo) {
            iv.hi_open = r.lo_inclusive or (lo == iv.hi and iv.hi_open);
            iv.hi = lo;
        }
    }
    if (integer_param) iv = iv.meet(i32_range);
    if (integer_param) assert(iv.excludesInf() or iv.isEmpty() or math.isNan(iv.lo) or math.isNan(iv.hi));
    return iv;
}

/// Returns real unary `tag` over `a`. A tag the interpreter computes as a
/// non-decreasing function maps the ends; an operand straddling the
/// function's domain edge gives `top`. Finite needs a finite operand, and a
/// bounded result for the tags that overflow.
pub fn unary(tag: Tag, a: Abstract) Abstract {
    const out = unaryRaw(tag, a.iv, a.finite);
    if (out.finite) assert(a.finite);
    if (out.iv.nonzero) assert(a.iv.nonzero); // only `fabs` passes the hole on
    return out;
}

/// Returns real binary `tag` over `x` and `y`. `+ - * /`, `%` and `hypot`
/// on finite operands stay finite, a divisor that may be zero aside: the
/// old prover's rule 3, an axiom the oracle states as a host contract (a
/// sample where one overflows is dropped).
pub fn binary(tag: Tag, x: Abstract, y: Abstract) Abstract {
    const f = x.finite and y.finite;
    const out = binaryRaw(tag, x.iv, y.iv, f, x.finite);
    if (out.finite) assert(f);
    if (out.iv.nonzero) assert(x.iv.nonzero or y.iv.nonzero); // only a hull (or an empty operand) keeps the hole
    return out;
}

/// Returns the interval of integer-valued `tag` (`y` unused for a unary
/// tag). The 32-bit tags wrap into `i32_range`; the rest stay in an `i64`.
pub fn integer(tag: Tag, x: Interval, y: Interval) Interval {
    const info = Air.tag_info.getPtrConst(tag);
    assert(info.int);
    if (info.bool01) return .{ .lo = 0, .hi = 1 };
    const raw: Interval = switch (tag) {
        .iadd => wrap32(addLo(x.lo, y.lo), addHi(x.hi, y.hi), x, y),
        .isub => wrap32(addLo(x.lo, -y.hi), addHi(x.hi, -y.lo), x, y),
        .imul => blk: {
            const c = combine(x, y, mulOp);
            break :blk wrap32(c.lo, c.hi, x, y);
        },
        .ineg => wrap32(-x.hi, -x.lo, x, x),
        .iabs => blk: {
            const m = absIv(x);
            break :blk wrap32(m.lo, m.hi, x, x);
        },
        // |x / y| <= |x| for an integer y != 0; minInt / -1 wraps to minInt.
        .idiv => blk: {
            const m = @max(@abs(x.lo), @abs(x.hi));
            break :blk (Interval{ .lo = -m, .hi = m }).meet(i32_range);
        },
        // §4.2.4: |x % y| < |y| and <= |x|, with the dividend's sign.
        .imod => blk: {
            const m = @min(@max(@abs(x.lo), @abs(x.hi)), @max(@abs(y.lo), @abs(y.hi)));
            break :blk (Interval{ .lo = if (x.ge(0)) 0 else -m, .hi = if (x.le(0)) 0 else m }).meet(i64_range);
        },
        .imin => .{ .lo = @min(x.lo, y.lo), .hi = @min(x.hi, y.hi) },
        .imax => .{ .lo = @max(x.lo, y.lo), .hi = @max(x.hi, y.hi) },
        .shl, .ipow => i32_range,
        // A count of 0 keeps `x` whole; any other is a logical shift of 32 bits.
        .shr => x.join(.{ .lo = 0, .hi = 4294967295.0 }),
        .fi_cast => .{ .lo = roundInt(x.lo), .hi = roundInt(x.hi) },
        .bitand, .bitor, .bitxor, .bitxnor, .bitnot, .iload => i64_range,
        else => unreachable, // else: `integer` is called for the integer value tags; the 0/1 ones returned above
    };
    const r = raw.meet(i64_range);
    assert(r.le(0x1p63));
    assert(r.ge(-0x1p63));
    return r;
}

// ---- private ----

fn unaryRaw(tag: Tag, a: Interval, af: bool) Abstract {
    if (a.isEmpty()) return .{ .iv = a, .finite = af };
    if (monotone(tag)) {
        const lo = f1(tag, a.lo);
        const hi = f1(tag, a.hi);
        // A NaN end means the operand straddles the domain edge (ln(-1),
        // acosh(0.5)), and the ends then do not span the range.
        if (math.isNan(lo) or math.isNan(hi)) return .{ .iv = top, .finite = false };
        // An open end stays open only where rounding keeps it open: every
        // double past an open end maps past f(end) when the next one does.
        // ponytail: trusts the computed f to be monotone; the oracle checks.
        const iv: Interval = .{
            .lo = @min(lo, hi),
            .hi = @max(lo, hi),
            .lo_open = a.lo_open and f1(tag, math.nextAfter(f64, a.lo, math.inf(f64))) > lo,
            .hi_open = a.hi_open and f1(tag, math.nextAfter(f64, a.hi, -math.inf(f64))) < hi,
        };
        const overflows = tag == .exp or tag == .expm1 or tag == .sinh;
        return .{ .iv = iv, .finite = af and (!overflows or iv.bounded()) };
    }
    return switch (tag) {
        .fneg => .{ .iv = .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open }, .finite = af },
        .fabs => .{ .iv = absIv(a), .finite = af },
        // §4.3.2 acos decreases on [-1, 1].
        .acos => blk: {
            const lo = f1(.acos, a.hi);
            const hi = f1(.acos, a.lo);
            if (math.isNan(lo) or math.isNan(hi)) break :blk .{ .iv = top, .finite = false };
            break :blk .{ .iv = .{ .lo = lo, .hi = hi }, .finite = af };
        },
        // cosh is even and grows with |x|.
        .cosh => blk: {
            const iv: Interval = .{ .lo = 1, .hi = f1(.cosh, absIv(a).hi) };
            break :blk .{ .iv = iv, .finite = af and iv.bounded() };
        },
        .sin, .cos => .{ .iv = .{ .lo = -1, .hi = 1 }, .finite = af },
        // §5.6.1.2: a latch holds an earlier solve's value, which no guard here bounds.
        .tan, .path_prev, .path_acc => .{ .iv = top, .finite = false },
        else => unreachable, // else: `unary` is called for the real unary value tags; the monotone ones returned above
    };
}

fn binaryRaw(tag: Tag, x: Interval, y: Interval, f: bool, xf: bool) Abstract {
    if (x.isEmpty()) return .{ .iv = x, .finite = f };
    if (y.isEmpty()) return .{ .iv = y, .finite = f };
    return switch (tag) {
        // A sum's end is open only if the sum just inside the open ends
        // still rounds past it: (0:1] + 1e20 is [1e20, 1e20].
        .fadd => .{ .iv = .{
            .lo = addLo(x.lo, y.lo),
            .hi = addHi(x.hi, y.hi),
            .lo_open = (x.lo_open or y.lo_open) and addLo(inLo(x), inLo(y)) > addLo(x.lo, y.lo),
            .hi_open = (x.hi_open or y.hi_open) and addHi(inHi(x), inHi(y)) < addHi(x.hi, y.hi),
        }, .finite = f },
        .fsub => .{ .iv = .{
            .lo = addLo(x.lo, -y.hi),
            .hi = addHi(x.hi, -y.lo),
            .lo_open = (x.lo_open or y.hi_open) and addLo(inLo(x), -inHi(y)) > addLo(x.lo, -y.hi),
            .hi_open = (x.hi_open or y.lo_open) and addHi(inHi(x), -inLo(y)) < addHi(x.hi, -y.lo),
        }, .finite = f },
        .fmul => .{ .iv = combine(x, y, mulOp), .finite = f },
        .fdiv => blk: {
            // A divisor that may be zero gives ±inf (§4.2.4 permits it).
            if (!y.excludesZero()) break :blk .{ .iv = top, .finite = false };
            // Corners are sound for `/` only over a one-signed divisor; an
            // open end at 0 divides by the zero of its own side.
            var yd = y;
            if (y.lt(0) and y.hi == 0) yd.hi = -0.0;
            if (y.gt(0) and y.lo == 0) yd.lo = 0.0;
            break :blk .{ .iv = if (y.gt(0) or y.lt(0)) combine(x, yd, divOp) else top, .finite = f };
        },
        // §4.2.4: |x % y| < |y|, with the dividend's sign; `% 0` has no value.
        .fmod => blk: {
            const m = absIv(y).hi;
            const iv: Interval = if (math.isFinite(m)) .{ .lo = if (x.ge(0)) 0 else -m, .hi = if (x.le(0)) 0 else m } else top;
            break :blk .{ .iv = iv, .finite = f };
        },
        .pow => blk: {
            const iv = powIv(x, y);
            break :blk .{ .iv = iv, .finite = f and iv.bounded() };
        },
        .hypot => .{ .iv = .{ .lo = 0, .hi = addHi(absIv(x).hi, absIv(y).hi) }, .finite = f },
        .atan2 => .{ .iv = .{ .lo = -math.pi, .hi = math.pi }, .finite = f },
        // §4.3.1 `(x < y) ? x : y`: a NaN `x` picks `y`, so a maybe-NaN
        // `x` (not finite) bounds the result only by the hull.
        .fmin => .{ .iv = if (xf) .{ .lo = @min(x.lo, y.lo), .hi = @min(x.hi, y.hi) } else x.join(y), .finite = f },
        .fmax => .{ .iv = if (xf) .{ .lo = @max(x.lo, y.lo), .hi = @max(x.hi, y.hi) } else x.join(y), .finite = f },
        else => unreachable, // else: `binary` is called for the real binary value tags
    };
}

/// The tags the interpreter computes as a non-decreasing function.
fn monotone(tag: Tag) bool {
    return switch (tag) {
        .exp, .expm1, .ln, .ln1p, .log10, .sqrt, .sinh, .tanh, .asinh, .atan, .asin, .atanh, .acosh, .floor, .ceil => true,
        else => false, // else: not monotone; `unaryRaw`'s switch has its rule
    };
}

/// `interp`'s value of real unary `tag` at `x`.
fn f1(tag: Tag, x: f64) f64 {
    return (interp.unary(tag, .{ .real = x }) catch unreachable).real; // a real unary tag has no error
}

fn powOp(a: f64, b: f64) f64 {
    return (interp.binary(.pow, .{ .real = a }, .{ .real = b }) catch unreachable).real; // pow has no error
}
fn mulOp(a: f64, b: f64) f64 {
    return a * b;
}
fn divOp(a: f64, b: f64) f64 {
    return a / b;
}

/// The hull of `f` at the box's four corners, closed. A NaN corner (0*inf,
/// inf/inf) gives `top`. Sound when `f` is monotone in each argument over
/// the box: `*` always, `/` over a one-signed divisor, `pow` for x >= 0.
fn combine(x: Interval, y: Interval, f: *const fn (f64, f64) f64) Interval {
    const c: @Vector(4, f64) = .{ f(x.lo, y.lo), f(x.lo, y.hi), f(x.hi, y.lo), f(x.hi, y.hi) };
    if (@reduce(.Or, c != c)) return top;
    const r: Interval = .{ .lo = @reduce(.Min, c), .hi = @reduce(.Max, c) };
    assert(r.lo <= r.hi);
    return r;
}

/// §4.3.1 pow over a box. Corners hold only where pow is monotone in each
/// argument: x >= 0. A base that may be negative needs one known integer
/// exponent (an even one has its interior minimum at 0; a negative one a
/// pole at 0, sound only for a strictly negative base).
fn powIv(x: Interval, y: Interval) Interval {
    if (x.ge(0)) {
        // A zero end may hold -0.0 (0 * -1): its corners use +0, where pow
        // is monotone, and pow(-0, -odd) = -inf joins the sign it flips.
        var xp = x;
        if (xp.lo == 0) xp.lo = 0.0;
        if (xp.hi == 0) xp.hi = 0.0;
        var r = combine(xp, y, powOp);
        if (x.contains(0) and !y.ge(0)) r.lo = -math.inf(f64);
        return r;
    }
    const k = y.lo;
    if (!(y.lo == y.hi and math.isFinite(k) and k == @trunc(k))) return top;
    if (k >= 0) {
        if (@mod(k, 2) == 0) {
            const m = absIv(x);
            return .{ .lo = powOp(m.lo, k), .hi = powOp(m.hi, k) };
        }
        return .{ .lo = powOp(x.lo, k), .hi = powOp(x.hi, k) };
    }
    if (!(x.hi < 0)) return top;
    const a = powOp(x.lo, k);
    const b = powOp(x.hi, k);
    return .{ .lo = @min(a, b), .hi = @max(a, b) };
}

fn absIv(a: Interval) Interval {
    if (a.ge(0)) return a;
    if (a.le(0)) return .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open };
    return .{ .lo = 0, .hi = @max(@abs(a.lo), @abs(a.hi)) };
}

/// `[lo, hi]` when both operands and the result fit §3.2's 32 bits (no
/// wrap: every bound is exact in f64), else every 32-bit integer.
fn wrap32(lo: f64, hi: f64, x: Interval, y: Interval) Interval {
    const fits = x.ge(i32_range.lo) and x.le(i32_range.hi) and y.ge(i32_range.lo) and y.le(i32_range.hi);
    if (fits and lo >= i32_range.lo and hi <= i32_range.hi) return .{ .lo = lo, .hi = hi };
    return i32_range;
}

/// §4.2.1.1 as the interpreter rounds: nearest, ties away, saturating.
fn roundInt(x: f64) f64 {
    if (math.isNan(x)) return 0;
    return @floatFromInt((interp.unary(.fi_cast, .{ .real = x }) catch unreachable).int); // fi_cast has no error
}

// Endpoint sums: a NaN sum (inf - inf) folds to the wide side.
fn addLo(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) -math.inf(f64) else r;
}
fn addHi(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) math.inf(f64) else r;
}

/// The least member of `i` as a double; `inHi` the greatest.
fn inLo(i: Interval) f64 {
    return if (i.lo_open) math.nextAfter(f64, i.lo, math.inf(f64)) else i.lo;
}
fn inHi(i: Interval) f64 {
    return if (i.hi_open) math.nextAfter(f64, i.hi, -math.inf(f64)) else i.hi;
}

test "Interval: predicates, meet and join against contains" {
    // Exhaustive over a small domain (the old prover's oracle): every
    // interval with ends in `ends`, each openness and the hole, at each end,
    // the doubles beside it and points between.
    const inf = math.inf(f64);
    const ends = [_]f64{ -inf, -1, 0, 1, inf };
    var pts: [ends.len * 3 + 4]f64 = undefined;
    for (ends, 0..) |e, i| pts[3 * i ..][0..3].* = .{ e, math.nextAfter(f64, e, -inf), math.nextAfter(f64, e, inf) };
    pts[ends.len * 3 ..][0..4].* = .{ -2, -0.5, 0.5, 2 };
    var all: [ends.len * ends.len * 8]Interval = undefined;
    var n: usize = 0;
    for (ends) |lo| for (ends) |hi| for (0..8) |bits| {
        all[n] = .{ .lo = lo, .hi = hi, .lo_open = bits & 1 != 0, .hi_open = bits & 2 != 0, .nonzero = bits & 4 != 0 };
        n += 1;
    };
    for (all) |a| {
        for (pts) |x| if (a.contains(x)) {
            if (a.bounded()) try std.testing.expect(math.isFinite(x));
            if (a.excludesInf()) try std.testing.expect(!math.isInf(x));
            if (a.excludesZero()) try std.testing.expect(x != 0);
            for ([_]f64{ -1, 0, 1 }) |k| {
                if (a.gt(k)) try std.testing.expect(x > k);
                if (a.ge(k)) try std.testing.expect(x >= k);
                if (a.lt(k)) try std.testing.expect(x < k);
                if (a.le(k)) try std.testing.expect(x <= k);
            }
            try std.testing.expect(!a.isEmpty());
        };
        for (all) |b| {
            const m = a.meet(b);
            const u = a.join(b);
            const w = a.widen(u);
            for (pts) |x| {
                try std.testing.expectEqual(a.contains(x) and b.contains(x), m.contains(x));
                if (a.contains(x) or b.contains(x)) try std.testing.expect(u.contains(x));
                if (u.contains(x)) try std.testing.expect(w.contains(x));
            }
        }
    }
}

test "fromRanges: §3.4.2 brackets decide the hole and the clipped ends" {
    // `exclude 0` on an unbounded range is the hole; `exclude (0:5)` admits 0.
    try std.testing.expect(fromRanges(&.{.{ .kind = .exclude, .lo = 0, .hi = 0 }}, false).excludesZero());
    try std.testing.expect(!fromRanges(&.{.{ .kind = .exclude, .lo = 0, .hi = 5, .lo_inclusive = false, .hi_inclusive = false }}, false).excludesZero());
    // [0:10] minus [0:2] is (2:10]; minus (0:5) is {0} ∪ [5:10], hull [0:10].
    const clipped = fromRanges(&.{ .{ .kind = .from, .lo = 0, .hi = 10 }, .{ .kind = .exclude, .lo = 0, .hi = 2 } }, false);
    try std.testing.expect(clipped.gt(2) and clipped.le(10));
    const kept = fromRanges(&.{ .{ .kind = .from, .lo = 0, .hi = 10 }, .{ .kind = .exclude, .lo = 0, .hi = 5, .lo_inclusive = false, .hi_inclusive = false } }, false);
    try std.testing.expect(kept.contains(0));
    // An integer never holds an infinity; a bound that does not fold is no evidence.
    try std.testing.expect(fromRanges(&.{}, true).bounded());
    try std.testing.expectEqual(top, fromRanges(&.{.{ .kind = .from, .lo = null, .hi = 1 }}, false));
}
