//! The §4.3.2 domain obligations: a tag and its operands' intervals in, how
//! the obligation came out (`Check`) and the words its diagnostic uses out.
//! Three-way, because §4.3.2 ("Input values outside of the valid range for
//! the operator shall report an error") obliges reporting a value that is
//! out of range, not rejecting a program whose values might be:
//!
//!   provably outside the domain -> an error (E0601-E0607, E0609)
//!   provably inside             -> proven, may stay `.optimized`
//!   straddles or unprovable     -> open: accepted, the result is not
//!                                  finite and its root goes `.strict`
//!
//! An integer `/` whose divisor may be zero is open and warns (W0653).
//! Pure: `Float` records each check and reports the violations.
//! Cites: VAMS-2023 §4.2.4, §4.3.1 (Table 4-14), §4.3.2 (Table 4-15);
//! IEEE 1364-2005 §5.1.5.
//!
//! Contents:
//! - `pub const Why = enum`, `pub const Check = struct { state: Float.Domain, why: Why }`
//! - `pub const Text = struct`, `pub fn text(why: Why) Text`
//! - `pub fn check(tag: Air.Inst.Tag, x: Interval, y: Interval, int_y: bool) Check`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Diag = @import("vams").Diag;
const Air = @import("../../Air.zig");
const Interval = @import("../Interval.zig");
const Float = @import("../Float.zig");

/// Why a check is not proven, when the words matter: each violation, and
/// the open integer divisor W0653 names.
pub const Why = enum(u8) {
    none,
    zero_divisor,
    int_divisor,
    positive,
    gt_neg_one,
    non_negative,
    unit_closed,
    unit_open,
    ge_one,
    pow_zero_base,
    pow_neg_base,
};

/// One obligation's outcome.
pub const Check = struct { state: Float.Domain, why: Why = .none };

/// A diagnostic's code and words: which operand it describes (0 the first),
/// the text beside the caret and the way out.
pub const Text = struct { code: Diag.Code, operand: u1, requirement: []const u8, fix: []const u8 };

/// Returns the code and words of `why`. Asserts that `why` is not `.none`.
pub fn text(why: Why) Text {
    assert(why != .none);
    const t: Text = switch (why) {
        .none => unreachable,
        .zero_divisor => .{ .code = .E0601, .operand = 1, .requirement = "is provably zero", .fix = "a zero divisor is an error (§4.2.4); check the expression or the parameter's range" },
        .int_divisor => .{ .code = .W0653, .operand = 1, .requirement = "cannot be proven non-zero; if it is zero at run time the result is 0", .fix = "give the parameter `exclude 0` or `from [1:inf)`, guard the division with an `if` the prover can see, or pass `--allow=W0653`" },
        .positive => .{ .code = .E0602, .operand = 0, .requirement = "must be > 0", .fix = "add a range like `from (0:inf)` to the parameter, or guard the call with `if (x > 0)`" },
        .gt_neg_one => .{ .code = .E0603, .operand = 0, .requirement = "must be > -1", .fix = "add a range like `from (-1:inf)` to the parameter, or guard the call with `if (x > -1)`" },
        .non_negative => .{ .code = .E0604, .operand = 0, .requirement = "must be >= 0", .fix = "add a range like `from [0:inf)` to the parameter, or write `sqrt(abs(x))` if magnitude is what the model means" },
        .unit_closed => .{ .code = .E0605, .operand = 0, .requirement = "must satisfy -1 <= x <= 1", .fix = "add a range like `from [-1:1]` to the parameter, or clamp with `min`/`max` before the call" },
        .unit_open => .{ .code = .E0606, .operand = 0, .requirement = "must satisfy -1 < x < 1", .fix = "add a range like `from (-1:1)` to the parameter — round brackets exclude the poles" },
        .ge_one => .{ .code = .E0607, .operand = 0, .requirement = "must be >= 1", .fix = "add a range like `from [1:inf)` to the parameter, or guard the call" },
        .pow_zero_base => .{ .code = .E0609, .operand = 1, .requirement = "must be >= 0 — the base is provably zero", .fix = "constrain the exponent with `from [0:inf)`, or the base with `exclude 0`" },
        .pow_neg_base => .{ .code = .E0609, .operand = 1, .requirement = "must be an integer — the base is provably negative", .fix = "use `pow(abs(x), y)` with an explicit sign, or constrain the base with `from [0:inf)`" },
    };
    assert(t.requirement.len != 0);
    return t;
}

/// Returns how `tag`'s domain obligation (`Air.tag_info`'s `domain`) comes
/// out over operands `x` and `y` (`y` unused for a unary tag); `int_y`: the
/// exponent is provably integer-valued. An empty operand is unreachable and
/// proves every domain.
pub fn check(tag: Air.Inst.Tag, x: Interval, y: Interval, int_y: bool) Check {
    const dom = Air.tag_info.getPtrConst(tag).domain;
    const r: Check = switch (dom) {
        .all => .{ .state = .proven },
        .nonzero_divisor => divisor(tag, y),
        .pow_sign => powSign(x, y, int_y),
        .tan_poles => .{ .state = if (x.isEmpty() or tanSafe(x)) .proven else .open },
        .positive => unit(x, x.gt(0), x.le(0), .positive),
        .gt_neg_one => unit(x, x.gt(-1), x.le(-1), .gt_neg_one),
        .non_negative => unit(x, x.ge(0), x.lt(0), .non_negative),
        .unit_closed => unit(x, x.ge(-1) and x.le(1), x.gt(1) or x.lt(-1), .unit_closed),
        .unit_open => unit(x, x.gt(-1) and x.lt(1), x.ge(1) or x.le(-1), .unit_open),
        .ge_one => unit(x, x.ge(1), x.lt(1), .ge_one),
    };
    if (dom == .all) assert(r.state == .proven);
    if (r.state == .violated) assert(r.why != .none and r.why != .int_divisor);
    return r;
}

// ---- private ----

fn unit(x: Interval, inside: bool, outside: bool, why: Why) Check {
    if (x.isEmpty() or inside) return .{ .state = .proven };
    if (outside) return .{ .state = .violated, .why = why };
    return .{ .state = .open };
}

/// Integer `/`, and `%` of either type (§4.2.4): a provably zero divisor is
/// E0601; an unprovable one is accepted, and an integer `/` warns, since
/// the device's guarded division yields 0 where IEEE 1364 §5.1.5 has `x`.
fn divisor(tag: Air.Inst.Tag, y: Interval) Check {
    if (y.isEmpty() or y.excludesZero()) return .{ .state = .proven };
    if (y.lo == 0 and y.hi == 0) return .{ .state = .violated, .why = .zero_divisor };
    return .{ .state = .open, .why = if (tag == .idiv) .int_divisor else .none };
}

/// §4.3.1 Table 4-14 pow: x > 0 all y; x = 0, y > 0; x < 0, integer y. A
/// violation needs every admitted pair to violate.
fn powSign(x: Interval, y: Interval, int_y: bool) Check {
    if (x.isEmpty() or y.isEmpty()) return .{ .state = .proven };
    if (x.gt(0)) return .{ .state = .proven };
    if (x.ge(0) and y.gt(0)) return .{ .state = .proven };
    // x == 0 always, y < 0 always: +inf on every execution. Before the
    // integer-exponent accept, whose clause is the x < 0 row.
    if (x.lo == 0 and x.hi == 0 and !x.nonzero and y.lt(0)) return .{ .state = .violated, .why = .pow_zero_base };
    if (int_y) return .{ .state = .proven }; // x < 0, integer y
    // x < 0 always, y fractional always: NaN on every execution.
    const fractional = y.bounded() and @floor(y.lo) == @floor(y.hi) and y.lo != @floor(y.lo);
    if (x.lt(0) and fractional) return .{ .state = .violated, .why = .pow_neg_base };
    return .{ .state = .open };
}

/// §4.3.2 tan: x != n(pi/2), n odd. Never violated (every double is
/// rational, every pole irrational); proven when `x` sits strictly inside
/// one pole-free branch.
fn tanSafe(x: Interval) bool {
    if (!x.bounded()) return false;
    const k = @floor((x.lo + math.pi / 2.0) / math.pi);
    const lo_pole = k * math.pi - math.pi / 2.0;
    const hi_pole = k * math.pi + math.pi / 2.0;
    assert(lo_pole <= hi_pole); // `<=`: past ~1e16 both round alike
    return x.gt(lo_pole) and x.lt(hi_pole);
}

test check {
    // Table 4-15's three outcomes, one row each: inside, outside, straddling.
    const pos: Interval = .{ .lo = 0, .lo_open = true };
    try std.testing.expectEqual(Float.Domain.proven, check(.ln, pos, .top, false).state);
    try std.testing.expectEqual(Check{ .state = .violated, .why = .positive }, check(.ln, .{ .hi = 0 }, .top, false));
    try std.testing.expectEqual(Float.Domain.open, check(.ln, .top, .top, false).state);
    try std.testing.expectEqual(Check{ .state = .violated, .why = .unit_closed }, check(.asin, .{ .lo = 1, .lo_open = true }, .top, false));
    try std.testing.expectEqual(Float.Domain.proven, check(.atanh, .{ .lo = -1, .hi = 1, .lo_open = true, .hi_open = true }, .top, false).state);
    // §4.2.4: a provably zero divisor is an error, an open integer one warns.
    try std.testing.expectEqual(Check{ .state = .violated, .why = .zero_divisor }, check(.fmod, .top, .point(0), false));
    try std.testing.expectEqual(Check{ .state = .open, .why = .int_divisor }, check(.idiv, .top, .{ .lo = -1, .hi = 1 }, false));
    try std.testing.expectEqual(Float.Domain.proven, check(.imod, .top, .{ .nonzero = true }, false).state);
    // Table 4-14 pow: a zero base under a negative exponent, a negative base
    // under a fractional one; an integer exponent rescues a negative base.
    try std.testing.expectEqual(Check{ .state = .violated, .why = .pow_zero_base }, check(.pow, .point(0), .{ .hi = -1 }, false));
    try std.testing.expectEqual(Check{ .state = .violated, .why = .pow_neg_base }, check(.pow, .{ .hi = -1 }, .{ .lo = 0.25, .hi = 0.75 }, false));
    try std.testing.expectEqual(Float.Domain.proven, check(.pow, .{ .hi = -1 }, .point(3), true).state);
    // tan: no reject arm; proven strictly inside a pole-free branch.
    try std.testing.expectEqual(Float.Domain.proven, check(.tan, .{ .lo = -1, .hi = 1 }, .top, false).state);
    try std.testing.expectEqual(Float.Domain.open, check(.tan, .{ .lo = 1, .hi = 2 }, .top, false).state);
}

test "Air.Domain.admits is check over points: two implementations held to each other" {
    // Sema's constant fold asks `admits`, `Float` asks `check`: a point one
    // admits and the other rejects is a constant accepted or refused by
    // the wrong stage (an illegal program compiled to NaN).
    const inf = math.inf(f64);
    const grid = [_]f64{ 0, -0.0, 0.5, -0.5, 1, -1, 2, -2, -1 - 0x1p-52, inf, -inf, math.nan(f64), math.floatTrueMin(f64), -math.floatTrueMin(f64), math.floatMax(f64), -math.floatMax(f64) };
    var tags: u32 = 0;
    for (std.enums.values(Air.Inst.Tag)) |t| {
        const dom = Air.tag_info.getPtrConst(t).domain;
        if (dom == .all) continue;
        tags += 1;
        for (grid) |x| for (grid) |y| {
            // `y_int` as `Walk.integral` reads a constant.
            const y_int = math.isFinite(y) and y == @trunc(y);
            const violated = check(t, .point(x), .point(y), y_int).state == .violated;
            try std.testing.expectEqual(!violated, dom.admits(x, y, y_int));
        };
    }
    try std.testing.expectEqual(14, tags); // fmod idiv imod sqrt ln ln1p log10 pow ipow tan asin acos acosh atanh
}
