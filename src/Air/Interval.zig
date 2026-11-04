//! The Air passes' abstract value: a real interval with open or closed ends
//! and the one hole a divisor proof needs, a may-be-NaN bit beside it, and a
//! transfer per value tag (an operand's `Abstract` in, the result's out).
//! Pure arithmetic: no Air walk, no allocation, no diagnostics.
//!
//! Every transfer is sound for IEEE 754 round-to-nearest as the device
//! computes it (`interp.deviceLib` for the §4.3 library functions, which
//! diff-kernels holds to the device bit for bit), with no overflow
//! contract: an interval's
//! members are the extended reals, so a sum that can pass `floatMax` reaches
//! `inf` and is not finite, and every way an operation can make NaN from
//! numbers (`inf - inf`, `0 * inf`, `0 / 0`, `sin(inf)`, a negative base
//! under a fraction, an operand outside the domain) sets `nan`. A bound is
//! the value the device computes at the operand's extreme member: rounding
//! is monotone, so for `+ - * /`, `sqrt`, `floor` and `ceil` (correctly
//! rounded) that bound is exact; the library functions are not correctly
//! rounded and need not be monotone (`tanh` drops 1 ulp between neighbours
//! near 0.337), so their bounds move `libUlps(tag)` outward, derived from
//! the device function's error bound (`libErr`), and are clamped to the
//! function's range. The falsification oracle
//! (tests/differential/air_passes.zig) holds every interval and every NaN
//! bit against every value a run defines. An integer's interval holds
//! `@floatFromInt` of it, which is monotone, so an integer fact closes its
//! ends.
//! Cites: VAMS-2023 §3.2, §3.4.2, §4.2.1.1, §4.2.1.2, §4.2.4, §4.3.1
//! (Table 4-14), §4.3.2 (Table 4-15); IEEE 754-2019 §4.3, §6.1, §7.2;
//! IEEE 1364-2005 §5.1.5.
//!
//! Contents:
//! - `pub const Interval = @This()` (fields `lo`, `hi`, `lo_open`, `hi_open`, `nonzero`)
//! - `pub const top: Interval`, `pub const i32_range: Interval`, `pub const i64_range: Interval`
//! - `pub const Abstract = struct { iv: Interval, nan: bool }` (`finite`)
//! - `pub const Range = struct`
//! - `pub fn libErr(tag: Tag) f64`, `pub fn libUlps(tag: Tag) u32`
//! - `pub fn point(x: f64) Interval`
//! - `pub fn bounded(i: Interval) bool`, `pub fn isEmpty(i: Interval) bool`, `pub fn excludesInf(i: Interval) bool`
//! - `pub fn whole(i: Interval) bool`
//! - `pub fn gt(i: Interval, k: f64) bool`, `ge`, `lt`, `le`, `pub fn excludesZero(i: Interval) bool`
//! - `pub fn meet(a: Interval, b: Interval) Interval`, `pub fn join(a: Interval, b: Interval) Interval`
//! - `pub fn widen(old: Interval, new: Interval) Interval`
//! - `pub fn contains(i: Interval, x: f64) bool`
//! - `pub fn fromRanges(ranges: []const Range, integer: bool) Interval`
//! - `pub fn unary(tag: Air.Inst.Tag, a: Abstract) Abstract`
//! - `pub fn binary(tag: Air.Inst.Tag, x: Abstract, y: Abstract) Abstract`
//! - `pub fn call(range: Air.CallFacts.Range, arg: Abstract) Abstract`
//! - `pub fn compare(rel: Air.Relation, x: Interval, y: Interval, nan_free: bool, int: bool) Interval`
//! - `pub fn integer(tag: Air.Inst.Tag, x: Interval, y: Interval) Interval`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Air = @import("../Air.zig");
const interp = @import("interp.zig");
const Tag = Air.Inst.Tag;

/// File-as-struct. The members are extended reals: a closed infinite end
/// admits that infinity, an open one only the finite doubles before it.
/// `top` is `[-inf, inf]`, the "no evidence" element. NaN never is a bound:
/// a NaN constant is `top`, and a transfer answers `top` for a NaN
/// endpoint. Empty (`lo > hi`) is unreachable and satisfies every domain
/// vacuously. A predicate is sound, not exact: `true` is a proof about
/// every member, `false` only the absence of one. An interval says nothing
/// about NaN: that is `Abstract.nan`'s.
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

/// A value's abstract state: the interval holding every non-NaN value it
/// takes, and whether it may be NaN.
pub const Abstract = struct {
    iv: Interval,
    nan: bool,

    /// Returns whether every value is a finite double: never NaN, never
    /// ±inf. An empty interval (an unreached value) is vacuously finite.
    pub fn finite(a: Abstract) bool {
        const r = !a.nan and (a.iv.isEmpty() or a.iv.excludesInf());
        if (r) assert(!a.iv.contains(math.inf(f64)));
        return r;
    }
};

/// One §3.4.2 value range of a parameter, its bounds folded literally
/// (null: a bound that does not fold, which proves nothing).
pub const Range = struct {
    kind: enum { from, exclude },
    lo: ?f64,
    hi: ?f64,
    lo_inclusive: bool = true,
    hi_inclusive: bool = true,
};

/// The device's error bound for library tag `tag`, in ulps of the exact
/// value: the documented accuracy of the function `interp.deviceLib` calls
/// (contract/gm.zig, Gompute's math header, VD-123), which diff-kernels
/// checks against the f128 reference over the specials and 10^5 draws.
pub fn libErr(tag: Tag) f64 {
    return switch (tag) {
        // gm (ARM optimized-routines): <= 0.52, pow <= 0.55.
        .exp, .ln => 0.52,
        .pow => 0.55,
        // musl's, std's bodies; acos and asin `std.math`'s.
        .expm1, .ln1p, .atan, .asin, .acos => 1,
        // gm's cosh and `std.math.hypot`: 1.145 and 1.163 measured against
        // f128 (diff-kernels' lib-err), no documented bound.
        .cosh, .hypot => 1.25,
        // Gompute's log10 "<= 2 ulp"; VD-123's asinh, acosh, atanh, atan2
        // "under 2 ulp"; musl's sinh 1.75.
        .log10, .asinh, .acosh, .atanh, .atan2, .sinh => 2,
        // musl's tanh: 2.05.
        .tanh => 2.1,
        else => 0, // else: not a library function; computed exactly
    };
}

/// The doubles a library function's computed bound moves outward. For a
/// monotone f with x <= e, device(x) <= f(x) + E·u(f(x)) <= f(e) + E·u(f(e))
/// and device(e) >= f(e) - E·u(f(e)), where E = `libErr(tag)`; u(f(e)) is
/// at most twice the ulp at device(e) (one binade down), so device(x) is
/// within 4E ulps of device(e) above it: ceil(4E). Non-monotonicity of the
/// device's rounding is inside that (it is f's monotonicity the bound uses).
/// The move never crosses zero: near its zero no function's computed sign
/// was wrong (2·10^6 samples each), so `ln` over `[1, x]` stays `>= 0`.
pub fn libUlps(tag: Tag) u32 {
    return @intFromFloat(@ceil(4 * libErr(tag)));
}

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

/// Returns whether `i` admits every double and NaN, so an input in it needs
/// no entry check: `[-inf, inf]` closed, with no hole. Any other interval's
/// check (`contains`) refuses NaN.
pub fn whole(i: Interval) bool {
    const r = i.lo == -math.inf(f64) and i.hi == math.inf(f64) and !i.lo_open and !i.hi_open and !i.nonzero;
    if (r) assert(i.contains(math.inf(f64)));
    if (!r) assert(!i.contains(math.nan(f64)));
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

/// Returns real unary `tag` over `a`: the bounds are `interp`'s values at
/// `a`'s extreme members (moved `libUlps` outward for a library
/// function), closed; an operand straddling the function's domain edge
/// gives `top` and may be NaN, as does `sin`, `cos` or `tan` of ±inf.
pub fn unary(tag: Tag, a: Abstract) Abstract {
    const out = unaryRaw(tag, a.iv);
    const r: Abstract = .{ .iv = out.iv, .nan = a.nan or out.nan };
    if (a.nan) assert(r.nan);
    if (r.iv.nonzero) assert(a.iv.nonzero); // only `fabs` passes the hole on
    return r;
}

/// Returns real binary `tag` over `x` and `y`, with no overflow contract:
/// a bound past `floatMax` is ±inf, so `1e200 * 1e200` is not finite.
/// `min`/`max` pass on only their second operand's NaN (§4.3.1: a NaN
/// first operand picks the second).
pub fn binary(tag: Tag, x: Abstract, y: Abstract) Abstract {
    const out = binaryRaw(tag, x.iv, y.iv, x.nan);
    const nan = out.nan or y.nan or (x.nan and tag != .fmin and tag != .fmax);
    if (y.nan) assert(nan);
    if (out.iv.nonzero) assert(x.iv.nonzero or y.iv.nonzero); // only a hull (or an empty operand) keeps the hole
    return .{ .iv = out.iv, .nan = nan };
}

/// Returns a call's abstract value from its callee's range
/// (`Air.CallFacts.Range`); `arg` is its one argument's, read by `limexp`
/// and `$vt`. An unknown call is top and may be NaN: it costs `.strict`,
/// never a wrong `.optimized`.
pub fn call(range: Air.CallFacts.Range, arg: Abstract) Abstract {
    const inf = math.inf(f64);
    const r: Abstract = switch (range) {
        .unknown => .{ .iv = top, .nan = true },
        .finite => .{ .iv = .{ .lo = -inf, .hi = inf, .lo_open = true, .hi_open = true }, .nan = false },
        .int, .param_given => .{ .iv = i64_range, .nan = false },
        .unit => .{ .iv = .{ .lo = 0, .hi = 1 }, .nan = false },
        .positive => .{ .iv = .{ .lo = 0, .lo_open = true, .hi_open = true, .nonzero = true }, .nan = false },
        .non_negative => .{ .iv = .{ .lo = 0, .hi_open = true }, .nan = false },
        // §4.5.13: "not distinguishable from exp()".
        .limexp => unary(.exp, arg),
        // §9.15 kT/q.
        .vt => binary(.fmul, arg, .{ .iv = .point(8.617333262145179e-5), .nan = false }),
    };
    if (range == .unknown) assert(!r.finite());
    if (r.finite() and (range == .limexp or range == .vt)) assert(!arg.nan);
    return r;
}

/// Returns `x REL y` as `[1, 1]`, `[0, 0]` or `[0, 1]`: decided only where
/// every member pair agrees. A NaN operand makes every relation false but
/// `!=`, so "always true" needs `nan_free`; an integer's interval holds a
/// rounding past 2^53, so it decides only below that.
pub fn compare(rel: Air.Relation, x: Interval, y: Interval, nan_free: bool, int: bool) Interval {
    const unknown: Interval = .{ .lo = 0, .hi = 1 };
    if (x.isEmpty() or y.isEmpty()) return unknown;
    if (int and !(x.ge(-0x1p53) and x.le(0x1p53) and y.ge(-0x1p53) and y.le(0x1p53))) return unknown;
    const xy = allBelow(x, y);
    const yx = allBelow(y, x);
    const x_le = x.hi <= y.lo;
    const x_ge = y.hi <= x.lo;
    const same = x.lo == x.hi and y.lo == y.hi and x.lo == y.lo;
    const truth: ?bool = switch (rel) {
        .lt => if (xy and nan_free) true else if (x_ge) false else null,
        .le => if (x_le and nan_free) true else if (yx) false else null,
        .gt => if (yx and nan_free) true else if (x_le) false else null,
        .ge => if (x_ge and nan_free) true else if (xy) false else null,
        .eq => if (xy or yx) false else if (same and nan_free) true else null,
        .ne => if (xy or yx) true else if (same and nan_free) false else null,
    };
    const t = truth orelse return unknown;
    return .point(@floatFromInt(@intFromBool(t)));
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

fn unaryRaw(tag: Tag, a: Interval) Abstract {
    if (a.isEmpty()) return .{ .iv = a, .nan = false };
    const may_inf = !a.excludesInf();
    if (monotone(tag) or tag == .acos) {
        // `acos` decreases on [-1, 1]: its bounds swap ends.
        const rising = tag != .acos;
        const lo = f1(tag, if (rising) inLo(a) else inHi(a));
        const hi = f1(tag, if (rising) inHi(a) else inLo(a));
        // A NaN end: the operand straddles the domain edge (ln(-1),
        // acosh(0.5)), and the ends then do not span the range.
        if (math.isNan(lo) or math.isNan(hi)) return .{ .iv = top, .nan = true };
        const m = ulps(tag);
        var iv: Interval = .{ .lo = down(@min(lo, hi), m), .hi = up(@max(lo, hi), m) };
        // exp(0) = 1 exactly, and a faithfully rounded value never crosses
        // a double its true value does not cross: exp of x >= 0 stays >= 1
        // (the zeros of the rest are `down`'s and `up`'s).
        if (tag == .exp and inLo(a) >= 0) iv.lo = @max(iv.lo, 1);
        if (tag == .exp and inHi(a) <= 0) iv.hi = @min(iv.hi, 1);
        return .{ .iv = iv.meet(codomain(tag)), .nan = false };
    }
    return switch (tag) {
        .fneg => .{ .iv = .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open }, .nan = false },
        .fabs => .{ .iv = absIv(a), .nan = false },
        // cosh is even and grows with |x|.
        .cosh => .{ .iv = .{ .lo = 1, .hi = up(f1(.cosh, absIv(a).hi), libUlps(.cosh)) }, .nan = false },
        // sin(±inf) and cos(±inf) are NaN.
        .sin, .cos => .{ .iv = .{ .lo = -1, .hi = 1 }, .nan = may_inf },
        // tan of a finite double is finite (no double is a pole), but no
        // bound short of the poles' neighbourhood holds.
        .tan => .{ .iv = top, .nan = may_inf },
        // §5.6.1.2: a latch holds an earlier solve's value, which no guard here bounds.
        .path_prev, .path_acc => .{ .iv = top, .nan = true },
        else => unreachable, // else: `unary` is called for the real unary value tags; the monotone ones returned above
    };
}

fn binaryRaw(tag: Tag, x: Interval, y: Interval, x_nan: bool) Abstract {
    if (x.isEmpty()) return .{ .iv = x, .nan = false };
    if (y.isEmpty()) return .{ .iv = y, .nan = false };
    const inf = math.inf(f64);
    const x_inf = !x.excludesInf();
    const y_inf = !y.excludesInf();
    return switch (tag) {
        // Rounding is monotone, so the sum of the extreme members bounds
        // every sum; inf - inf is NaN.
        .fadd => .{
            .iv = .{ .lo = addLo(inLo(x), inLo(y)), .hi = addHi(inHi(x), inHi(y)) },
            .nan = (x.contains(-inf) and y.contains(inf)) or (x.contains(inf) and y.contains(-inf)),
        },
        .fsub => .{
            .iv = .{ .lo = addLo(inLo(x), -inHi(y)), .hi = addHi(inHi(x), -inLo(y)) },
            .nan = (x.contains(inf) and y.contains(inf)) or (x.contains(-inf) and y.contains(-inf)),
        },
        .fmul => .{ .iv = combine(x, y, mulOp), .nan = (x.contains(0) and y_inf) or (x_inf and y.contains(0)) },
        // A divisor that may be zero gives ±inf (§4.2.4 permits it).
        // Corners are sound for `/` only over a one-signed divisor; its
        // extreme members exclude 0 itself.
        .fdiv => .{
            .iv = if (y.gt(0) or y.lt(0)) combine(x, y, divOp) else top,
            .nan = (x.contains(0) and y.contains(0)) or (x_inf and y_inf),
        },
        // §4.2.4: |x % y| < |y| and <= |x|, with the dividend's sign; `% 0`
        // has no value, and a non-NaN result is finite.
        .fmod => blk: {
            const b = @min(absIv(y).hi, absIv(x).hi, math.floatMax(f64));
            break :blk .{ .iv = .{ .lo = if (x.ge(0)) 0 else -b, .hi = if (x.le(0)) 0 else b }, .nan = x_inf };
        },
        .pow => .{ .iv = powIv(x, y), .nan = !x.ge(0) and !integerPoint(y) },
        .hypot => .{ .iv = .{ .lo = 0, .hi = up(addHi(absIv(x).hi, absIv(y).hi), libUlps(.hypot)) }, .nan = false },
        .atan2 => .{ .iv = .{ .lo = down(-math.pi, libUlps(.atan2)), .hi = up(math.pi, libUlps(.atan2)) }, .nan = false },
        // §4.3.1 `(x < y) ? x : y`: a NaN `x` picks `y`, so a maybe-NaN
        // `x` bounds the result only by the hull.
        .fmin => .{ .iv = if (!x_nan) .{ .lo = @min(x.lo, y.lo), .hi = @min(x.hi, y.hi) } else x.join(y), .nan = false },
        .fmax => .{ .iv = if (!x_nan) .{ .lo = @max(x.lo, y.lo), .hi = @max(x.hi, y.hi) } else x.join(y), .nan = false },
        else => unreachable, // else: `binary` is called for the real binary value tags
    };
}

/// Whether every member of `x` is below every member of `y`.
fn allBelow(x: Interval, y: Interval) bool {
    return x.hi < y.lo or (x.hi == y.lo and (x.hi_open or y.lo_open));
}

/// The tags the interpreter computes as a non-decreasing function (up to
/// `ulps`).
fn monotone(tag: Tag) bool {
    return switch (tag) {
        .exp, .expm1, .ln, .ln1p, .log10, .sqrt, .sinh, .tanh, .asinh, .atan, .asin, .atanh, .acosh, .floor, .ceil => true,
        else => false, // else: not monotone; `unaryRaw`'s switch has its rule
    };
}

/// The ulps a monotone tag's computed bound moves outward: none for the
/// correctly rounded ones, `libUlps` for a library function.
fn ulps(tag: Tag) u32 {
    return switch (tag) {
        .sqrt, .floor, .ceil => 0,
        else => libUlps(tag), // else: every other tag is a library function
    };
}

/// The range a computed function never leaves, met after `ulps` moved a
/// bound outward past it (exp(-inf) is 0, not one ulp below).
fn codomain(tag: Tag) Interval {
    return switch (tag) {
        .exp, .acosh, .acos => .{ .lo = 0 },
        .expm1 => .{ .lo = -1 },
        .tanh => .{ .lo = -1, .hi = 1 },
        else => top, // else: no range the bounds need clamping to
    };
}

/// `x` moved `n` doubles toward -inf, never below 0 from a value at or
/// above it; an infinity stays put.
fn down(x: f64, n: u32) f64 {
    var r = x;
    for (0..n) |_| r = if (math.isFinite(r)) math.nextAfter(f64, r, -math.inf(f64)) else r;
    if (x >= 0) r = @max(r, 0);
    assert(!(r > x));
    return r;
}

/// `x` moved `n` doubles toward +inf, never above 0 from a value at or
/// below it; an infinity stays put.
fn up(x: f64, n: u32) f64 {
    var r = x;
    for (0..n) |_| r = if (math.isFinite(r)) math.nextAfter(f64, r, math.inf(f64)) else r;
    if (x <= 0) r = @min(r, 0);
    assert(!(r < x));
    return r;
}

/// The device's value of real unary `tag` at `x`.
fn f1(tag: Tag, x: f64) f64 {
    if (interp.deviceLib(tag, x, 0)) |v| return v;
    return (interp.unary(tag, .{ .real = x }) catch unreachable).real; // a real unary tag has no error
}

fn powOp(a: f64, b: f64) f64 {
    return interp.deviceLib(.pow, a, b).?;
}
fn mulOp(a: f64, b: f64) f64 {
    return a * b;
}
fn divOp(a: f64, b: f64) f64 {
    return a / b;
}

/// The hull of `f` at the corners of the box's extreme members, closed. A
/// NaN corner (0*inf, inf/inf) gives `top`. Sound when `f` is monotone in
/// each argument over the box, as computed: `*` always, `/` over a
/// one-signed divisor, `pow` for x >= 0 (up to `libUlps(.pow)`, which the
/// caller adds).
fn combine(x: Interval, y: Interval, f: *const fn (f64, f64) f64) Interval {
    const xl = inLo(x);
    const xh = inHi(x);
    const yl = inLo(y);
    const yh = inHi(y);
    const c: @Vector(4, f64) = .{ f(xl, yl), f(xl, yh), f(xh, yl), f(xh, yh) };
    if (@reduce(.Or, c != c)) return top;
    const r: Interval = .{ .lo = @reduce(.Min, c), .hi = @reduce(.Max, c) };
    assert(r.lo <= r.hi);
    return r;
}

/// §4.3.1 pow over a box, its bounds `libUlps(.pow)` outward. Corners hold only
/// where pow is monotone in each argument: x >= 0. A base that may be
/// negative needs one known integer exponent (an even one has its interior
/// minimum at 0; a negative one a pole at 0, sound only for a strictly
/// negative base).
fn powIv(x: Interval, y: Interval) Interval {
    // C99 F.10.4.4: pow(x, ±0) and pow(1, y) are exactly 1, NaN operands
    // included: no ulps to add.
    const one = (y.lo == 0 and y.hi == 0) or (x.lo == 1 and x.hi == 1);
    const r: Interval = if (one) .point(1) else if (x.ge(0)) nonneg: {
        // A zero end may hold -0.0 (0 * -1): its corners use +0, where pow
        // is monotone, and pow(-0, -odd) = -inf joins the sign it flips.
        var xp: Interval = .{ .lo = inLo(x), .hi = inHi(x) };
        if (xp.lo == 0) xp.lo = 0.0;
        if (xp.hi == 0) xp.hi = 0.0;
        var c = outward(combine(xp, y, powOp)).meet(.{ .lo = 0 });
        if (x.contains(0) and !y.ge(0)) c.lo = -math.inf(f64);
        break :nonneg c;
    } else if (!integerPoint(y))
        top
    else if (y.lo >= 0 and @mod(y.lo, 2) == 0) even: {
        const m = absIv(x);
        break :even outward(.{ .lo = powOp(m.lo, y.lo), .hi = powOp(m.hi, y.lo) });
    } else if (y.lo >= 0)
        outward(.{ .lo = powOp(inLo(x), y.lo), .hi = powOp(inHi(x), y.lo) })
    else if (x.lt(0)) neg: {
        const a = powOp(inLo(x), y.lo);
        const b = powOp(inHi(x), y.lo);
        break :neg outward(.{ .lo = @min(a, b), .hi = @max(a, b) });
    } else top;
    assert(!(r.lo > r.hi));
    return r;
}

/// `i` with each end `libUlps(.pow)` outward, closed.
fn outward(i: Interval) Interval {
    const r: Interval = .{ .lo = down(i.lo, libUlps(.pow)), .hi = up(i.hi, libUlps(.pow)) };
    assert(!(r.lo > i.lo));
    assert(!(r.hi < i.hi));
    return r;
}

/// Whether every member of `y` is one integer: the exponent that rescues
/// a negative base.
fn integerPoint(y: Interval) bool {
    return y.lo == y.hi and math.isFinite(y.lo) and y.lo == @trunc(y.lo);
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

/// Test support: every interval with ends in `ends` (lo <= hi) and each
/// openness in `opens`.
fn intervals(ends: []const f64, opens: []const [2]bool, buf: []Interval) []const Interval {
    var n: usize = 0;
    for (ends) |lo| for (ends) |hi| {
        if (lo > hi) continue;
        for (opens) |o| {
            buf[n] = .{ .lo = lo, .hi = hi, .lo_open = o[0], .hi_open = o[1] };
            n += 1;
        }
    };
    return buf[0..n];
}

/// Test support: the points of `a` a test runs at, each closed end, the
/// double just inside each end, the midpoint, and those of `extra` inside.
fn samplePoints(a: Interval, extra: []const f64, buf: []f64) []const f64 {
    var n: usize = 0;
    const inf = math.inf(f64);
    const ends = [_]f64{ a.lo, a.hi, math.nextAfter(f64, a.lo, inf), math.nextAfter(f64, a.hi, -inf), a.lo / 2 + a.hi / 2 };
    for ([_][]const f64{ &ends, extra }) |xs| for (xs) |x| if (!math.isNan(x) and a.contains(x) and n < buf.len) {
        buf[n] = x;
        n += 1;
    };
    return buf[0..n];
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

test "unary: every value interp computes inside the operand is in the result, or the result may be NaN" {
    // The old prover's transfer oracle, with the device's math and no
    // excuse for NaN or ±inf: ends where rounding collapses an open bound
    // (exp underflows below about -745, tanh saturates past about ±19.1,
    // floor and ceil are flat), the infinities themselves, and the doubles
    // beside each end.
    const inf = math.inf(f64);
    const ops = [_]Tag{ .exp, .expm1, .ln, .ln1p, .log10, .sqrt, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh, .asin, .acos, .atan, .sin, .cos, .tan, .floor, .ceil, .fneg, .fabs };
    const ends = [_]f64{ -inf, -800, -20, -2, -1, -0.5, 0, 0.5, 1, 2, 20, 709.7, 800, inf };
    const extra = [_]f64{ -799, -19.9, -0.7, 0.7, 1.5, 2.5, 19.9, 799 };
    const opens = [_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } };
    var ivs: [ends.len * ends.len * opens.len]Interval = undefined;
    var buf: [16]f64 = undefined;
    for (ops) |op| for (intervals(&ends, &opens, &ivs)) |a| {
        const out = unary(op, .{ .iv = a, .nan = false });
        for (samplePoints(a, &extra, &buf)) |x| {
            const y = f1(op, x);
            if (math.isNan(y)) try std.testing.expect(out.nan) else try std.testing.expect(out.iv.contains(y));
            if (out.finite()) try std.testing.expect(math.isFinite(y));
        }
    };
}

test "unary: tanh's computed drop between neighbours stays inside the bound" {
    // Measured: tanh as the device computes it is not monotone; it drops 1
    // ulp between two neighbours near 0.33717500785869. A bound read off
    // the ends alone misses the low one (the merged transfer did).
    var x: f64 = 0.3371750078586919;
    var pts: [5]f64 = undefined;
    for (&pts) |*p| {
        p.* = x;
        x = math.nextAfter(f64, x, math.inf(f64));
    }
    const out = unary(.tanh, .{ .iv = .{ .lo = pts[0], .hi = pts[4] }, .nan = false });
    for (pts) |p| try std.testing.expect(out.iv.contains(f1(.tanh, p)));
}

test "binary: every value interp computes inside the operands is in the result, or the result may be NaN" {
    // 1e20 absorbs every operand below 2^14 in a sum, so an open end next to
    // it is not open after rounding; 1e300 and floatMax overflow a product
    // or a sum, and nothing promises them finite.
    const inf = math.inf(f64);
    const max = math.floatMax(f64);
    const ops = [_]Tag{ .fadd, .fsub, .fmul, .fdiv, .fmod, .pow, .hypot, .atan2, .fmin, .fmax };
    const ends = [_]f64{ -inf, -max, -1, 0, 0.5, 2, 1e20, 1e300, inf };
    const opens = [_][2]bool{ .{ false, false }, .{ true, true } };
    const extra = [_]f64{ -0.7, 0.7, -0.0, 3 };
    var ivs: [ends.len * ends.len * opens.len]Interval = undefined;
    const all = intervals(&ends, &opens, &ivs);
    var xb: [10]f64 = undefined;
    var yb: [10]f64 = undefined;
    for (ops) |op| for (all) |a| for (all) |b| {
        const out = binary(op, .{ .iv = a, .nan = false }, .{ .iv = b, .nan = false });
        for (samplePoints(a, &extra, &xb)) |x| for (samplePoints(b, &extra, &yb)) |y| {
            const z = interp.deviceLib(op, x, y) orelse (interp.binary(op, .{ .real = x }, .{ .real = y }) catch continue).real;
            if (math.isNan(z)) try std.testing.expect(out.nan) else try std.testing.expect(out.iv.contains(z));
            if (out.finite()) try std.testing.expect(math.isFinite(z));
        };
    };
}

test "integer: a 32-bit sum that fits is exact, one that may wrap is every 32-bit integer" {
    const small: Interval = .{ .lo = -5, .hi = 5 };
    try std.testing.expectEqual(Interval{ .lo = -10, .hi = 10 }, integer(.iadd, small, small));
    try std.testing.expectEqual(i32_range, integer(.iadd, .{ .lo = 0, .hi = 2147483647.0 }, .point(1)));
    try std.testing.expectEqual(Interval{ .lo = 0, .hi = 1 }, integer(.ilt, small, small));
    // §4.2.4: |x % y| < |y|, with the dividend's sign.
    const m = integer(.imod, .{ .lo = 0, .hi = 100 }, .{ .lo = 1, .hi = 7 });
    try std.testing.expect(m.ge(0));
    try std.testing.expect(m.le(7));
}
