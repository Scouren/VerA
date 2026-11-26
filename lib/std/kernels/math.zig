//! The §4.3 math kernels: an `f64` (or a family value `S`) in, LRM Tables
//! 4-14/4-15's function of it out, on every target a device compiles for
//! (host, NVPTX, AMDGCN). Two layers. The `f64` transcendentals are
//! Gompute's `math` (no optional contraction: an explicit `@mulAdd` rounds
//! once on every target and at comptime, so host, GPU and comptime round
//! alike, which is what lets the compiler's folds (`fold.zig`) and the
//! prover give the bits a device computes), plus the four Table 4-15
//! functions Gompute lacks (`asinh`, `acosh`, `atanh`, `atan2`: musl's
//! algorithms over Gompute's `log`, `log1p` and `atan`).
//! Over them, the value form a device's body calls (`zLog10`, `zPow`,
//! `zHypot`, ...): a function the scalar family does not provide
//! (`contract.family_primitives`) composed from the ones it does, or the
//! `f64` value with the analytic derivative grafted on (`zGraft`), and the
//! §4.3.2 domain guard (`zDomain`), quiet or reporting by `Options`.
//! Cites: §3.2, §3.3.1, §4.2.4, §4.2.11, §4.3, §4.3.1, §4.3.2 (Tables 4-14,
//! 4-15), §9.14, §9.17.3, §9.21.2; IEEE 1364-2005 §17.11.1; C99 F.10
//! (special cases); docs/specification/Vague_Decisions.md VD-123.
//!
//! Helpers run in the default (strict) float mode, since `@setFloatMode`
//! does not cross a call: a `.optimized` unit loses fast-math inside a
//! helper and never gains unsound fast-math.
//!
//! Contents:
//! - `pub const Options = struct { report_domain: bool }`, `pub const options: Options`
//! - `pub const exp`, `log`, `pow`, `sin`, `cos`, `tan`, `tanh`, `sinh`, `cosh`, `expm1`, `log1p`, `log10`: Gompute's
//! - `pub fn atan(x: f64) f64`, `asinh`, `acosh`, `atanh`
//! - `pub fn atan2(y: f64, x: f64) f64`
//! - `pub fn zDomain(comptime code: []const u8, comptime name: []const u8, comptime rule: []const u8, x: f64, in_range: bool) void`
//! - `pub fn zModZero() noreturn`
//! - `pub fn zMin(comptime S: type, a: S, b: S) S`, `zMax`, `zMinF(a: f64, b: f64) f64`, `zMaxF`
//! - `pub fn zCmp(comptime S: type, comptime op: std.math.CompareOperator, a: anytype, b: anytype) bool`
//! - `pub fn zRoundI(comptime S: type, a: anytype) i64`, `zStrip`, `zMulP`, `zAddP`, `zSubP`, `zInst`, `zInstI`, `zInstA`, `zInstIA`, `zLeads`
//! - `pub fn zDevExp(x: f64) f64`, `zDevExpm1`, `zDevAtan`, `zDevLog`, `zDevPow`, `zDevSin`, `zDevCos`, `zDevTanh`, `zDevSinh`, `zDevCosh`
//! - `pub fn zTan(comptime S: type, a: S) S`, `zGraft`, `zLog10`, `zPick`, `zSqrtD`, `zLnD`, `zLn1pD`, `zLog10D`, `zPowOk`, `zPowK`, `zHypot`, `zAsin`, `zAcos`, `zAsinh`, `zAcosh`, `zAtanh`, `zAtan2`, `zFloor`, `zCeil`, `zFmod`, `zPow`, `zLimitUf`
//! - `pub fn zIabs(a: i64) i64`, `zShl`, `zShr`, `zClog2`, `zStrCmp`

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const contract = @import("contract");
const gmath = @import("gompute_math");
const root = @import("root");

/// What a program's root may declare to steer the kernels, as
/// `pub const vera_kernels: kernels.Options = .{ ... };` (`std.options`'
/// pattern): read once, at comptime, so a device carries no flag.
pub const Options = struct {
    /// §4.3.2 "Input values outside of the valid range for the operator
    /// shall report an error": the printing executable reports and stops
    /// (`zDomain`); a solver device, which has no transcript (it also
    /// compiles for NVPTX), leaves the guard empty and the prover's
    /// E0602-E0609 refuse what it can see.
    report_domain: bool = false,
};

/// The root's `vera_kernels`, or the defaults.
pub const options: Options = if (@hasDecl(root, "vera_kernels")) root.vera_kernels else .{};

/// e^x for `f64`, `f32` or a vector of either: ARM optimized-routines, <= 0.52 ulp.
pub const exp = gmath.exp;
/// ln x: ARM optimized-routines, <= 0.52 ulp; -inf at ±0, NaN below 0.
pub const log = gmath.log;
/// x^y: ARM optimized-routines, <= 0.55 ulp; C99 F.10.4.4's special cases.
pub const pow = gmath.pow;
/// musl's sin, one body on every target (= compiler_rt's `@sin` on the host).
pub const sin = gmath.sin;
/// musl's cos, as `sin`.
pub const cos = gmath.cos;
/// sin/cos, within 2 ulp of the exact tangent away from its poles (VD-123).
pub const tan = gmath.tan;
/// musl's tanh (std's `tanh64`), over the one-body `expm1`.
pub const tanh = gmath.tanh;
/// musl's sinh.
pub const sinh = gmath.sinh;
/// musl's cosh.
pub const cosh = gmath.cosh;
/// e^x - 1 without the cancellation near 0; every value is std's.
pub const expm1 = gmath.expm1;
/// ln(1 + x) without the cancellation near 0; every value is std's.
pub const log1p = gmath.log1p;
/// log10(x): -inf at ±0, NaN below 0.
pub const log10 = gmath.log10;

/// #81: a GPU target gets the branch-free core. A select whose arms are
/// costly runs both there (`render.zig`), and the checked kernels below
/// inline, so no outlined call splits the core. A host CPU keeps the lazy
/// arm and the call.
const z_spec = switch (builtin.target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false, // else: every other target is a host CPU
};
const z_spec_cc: std.builtin.CallingConvention = if (z_spec) .@"inline" else .auto;

/// asinh(x) = sign(x)·ln(|x| + sqrt(x² + 1)), without the cancellation
/// (x < 0) or the overflow (|x| > 1e154) of that formula; under 2 ulp (VD-123).
pub fn asinh(x: f64) f64 {
    const u: u64 = @bitCast(x);
    const e = (u >> 52) & 0x7FF;
    var rx: f64 = @bitCast(u & (std.math.maxInt(u64) >> 1));
    if (e >= 0x3FF + 26) {
        rx = log(rx) + 0.693147180559945309417232121458176568;
    } else if (e >= 0x3FF + 1) {
        rx = log(2 * rx + 1 / (@sqrt(rx * rx + 1) + rx));
    } else if (e >= 0x3FF - 26) {
        rx = log1p(rx + rx * rx / (@sqrt(rx * rx + 1) + 1));
    }
    const r = if (u >> 63 != 0) -rx else rx;
    assert(std.math.isNan(r) or std.math.signbit(r) == std.math.signbit(x)); // Odd.
    return r;
}

/// acosh(x) = ln(x + sqrt(x² − 1)) for x >= 1; NaN below (C99 F.10.2.1),
/// the far negative side included; under 2 ulp, 1.94 near 1 (VD-123).
pub fn acosh(x: f64) f64 {
    const r = acoshBody(x);
    assert(!(r < 0.0)); // ln of a value >= 1, or NaN below 1.
    assert(!(x < 1.0) or std.math.isNan(r));
    return r;
}

/// atanh(x) = ½·ln((1 + x)/(1 − x)) for |x| < 1, ±inf at ±1, NaN past.
pub fn atanh(x: f64) f64 {
    const u: u64 = @bitCast(x);
    const e = (u >> 52) & 0x7FF;
    var y: f64 = @bitCast(u & (std.math.maxInt(u64) >> 1));
    if (y == 1.0) return std.math.copysign(std.math.inf(f64), x);
    if (e < 0x3FF - 1) {
        if (e >= 0x3FF - 32) y = 0.5 * log1p(2 * y + 2 * y * y / (1 - y));
    } else {
        y = 0.5 * log1p(2 * (y / (1 - y)));
    }
    const r = if (u >> 63 != 0) -y else y;
    assert(std.math.isNan(r) or std.math.signbit(r) == std.math.signbit(x)); // Odd.
    return r;
}

/// arctangent: Gompute's (2.0.1: musl's scalar body, < 1 ulp, 0.741
/// measured against f128), with atan(±0) = ±0 (C99 F.10.1.1).
pub fn atan(x: f64) f64 {
    const r = gmath.atan(x);
    assert(std.math.isNan(x) or std.math.signbit(r) == std.math.signbit(x)); // Odd.
    assert(std.math.isNan(r) or @abs(r) <= std.math.pi / 2.0);
    return r;
}

/// atan2(y, x) in (-pi, pi], with C99 F.10.1.4's signed zeros and
/// infinities: atan2(±0, -0) = ±pi, atan2(±0, +0) = ±0. Table 4-15's
/// "atan2(0,0) = 0" is the +0, +0 case.
pub fn atan2(y: f64, x: f64) f64 {
    const r = atan2Body(y, x);
    assert(std.math.isNan(r) or @abs(r) <= std.math.pi);
    return r;
}

/// §4.3.2 the domain guard of Table 4-14's one-bound functions: nothing in
/// a solver device; with `options.report_domain`, an out-of-range (or NaN)
/// `x` prints `code`'s line and exits 1, on the §9.21.2 `E` precedent,
/// since libm's quiet NaN would look like a converged answer. The root's
/// `vera_domain_muted` (the testbench's self-checks) silences it at run
/// time. `code` is the prover's for the same argument.
pub fn zDomain(comptime code: []const u8, comptime name: []const u8, comptime rule: []const u8, x: f64, in_range: bool) void {
    if (comptime !options.report_domain) return;
    if (in_range) return;
    if (comptime @hasDecl(root, "vera_domain_muted")) {
        if (root.vera_domain_muted) return;
    }
    std.debug.print(
        "error[" ++ code ++ "]: LRM 4.3.2: " ++ name ++ "() input value is outside the valid range " ++ rule ++ ": {d}\n",
        .{x},
    );
    std.process.exit(1);
}

/// §4.2.4 "It shall be an error to pass zero (0) as the second argument to
/// the modulus operator", for a real `%`: traps in a solver device; reports
/// E0601 and exits 1 under `options.report_domain`.
pub fn zModZero() noreturn {
    if (comptime !options.report_domain) @trap();
    std.debug.print("error[E0601]: LRM 4.2.4: real modulus divisor is zero\n", .{});
    std.process.exit(1);
}

// §4.3.1 defines the derivative at equality using strict comparisons:
// min(a,b) = (a < b) ? a : b; max(a,b) = (a > b) ? a : b. The contract's
// masks and winner-derivative selection, not a host min/max primitive's
// possibly different tie rule.

/// §4.3.1 min, `(a < b) ? a : b`, carrying the winner's lanes.
pub fn zMin(comptime S: type, a: S, b: S) S {
    return a.lt(b).sel(a, b);
}
/// §4.3.1 max, `(a > b) ? a : b`.
pub fn zMax(comptime S: type, a: S, b: S) S {
    return b.lt(a).sel(a, b);
}
/// The plain-f64 min (`opcode_zig.host_f64`: derive, setup), the same strict
/// comparison: `@min`/`@max` drop a NaN and leave a zero's sign open.
pub fn zMinF(a: f64, b: f64) f64 {
    return if (a < b) a else b;
}
/// The plain-f64 max.
pub fn zMaxF(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

// ---- per-operating-point decisions (`batch_lead`, contract.zig) ----
// A real compared, rounded to an integer or stripped of its lanes is one
// decision per call. A scalar family has one operating point and these are
// the plain value forms. A batch family (`V` a vector of points) implements
// the lead protocol: the leader point decides, every other point that would
// have decided otherwise is marked diverged, and the entry points re-run
// until every point has run on its own path.

/// `a op b` as one decision (`S.decide` in a batch family).
pub fn zCmp(comptime S: type, comptime op: std.math.CompareOperator, a: anytype, b: anytype) bool {
    if (comptime @hasDecl(S, "decide")) return S.decide(op, a, b);
    return std.math.compare(a.val(), op, b.val());
}
/// `a` rounded to an integer, as one decision.
pub fn zRoundI(comptime S: type, a: anytype) i64 {
    if (comptime @hasDecl(S, "decideI")) return S.decideI(a);
    return std.math.lossyCast(i64, @round(a.val()));
}
/// `a` without its lanes, as one decision.
pub fn zStrip(comptime S: type, a: anytype) @TypeOf(S.con(0.0)) {
    if (comptime @hasDecl(S, "strip")) return S.strip(a);
    return S.con(a.val());
}
/// `a * k` for a derivative-free `k` that differs per point: `scale` of its
/// value in a one-point family, which is what the device always emitted; in
/// a batch, the same arithmetic per point.
pub fn zMulP(comptime S: type, a: anytype, k: anytype) @TypeOf(a) {
    if (comptime @typeInfo(S.V) == .vector) return a.mul(k);
    return a.scale(k.val());
}
/// `a + k`, as `zMulP` (`sub` of `-k` keeps a -0 lane that `add` of a zero
/// lane would not).
pub fn zAddP(comptime S: type, a: anytype, k: anytype) @TypeOf(a) {
    if (comptime @typeInfo(S.V) == .vector) return a.sub(k.neg());
    return a.addC(k.val());
}
/// `a - k`, as `zMulP`.
pub fn zSubP(comptime S: type, a: anytype, k: anytype) @TypeOf(a) {
    if (comptime @typeInfo(S.V) == .vector) return a.sub(k);
    return a.addC(-(k.val()));
}
/// Field `f` of the `Instance`, as a value: per point in a batch, whose
/// points each have their own instance (`S.instLane(T, w)`, contract.zig
/// `batch_inst`); a one-point family reads `inst`.
pub fn zInst(comptime S: type, inst: anytype, comptime f: []const u8) @TypeOf(S.con(0.0)) {
    if (comptime contract.instLanes(S)) {
        var ls: [S.lane_count]@TypeOf(S.Lane.con(0.0)) = undefined;
        inline for (0..S.lane_count) |w| ls[w] = S.Lane.con(@field(S.instLane(@TypeOf(inst.*), w), f));
        return S.fromLanes(0, ls);
    }
    return S.con(@field(inst, f));
}
/// Integer field `f` of the `Instance`: one value per call, so in a batch a
/// decision (the lead protocol) over each point's own instance.
pub fn zInstI(comptime S: type, inst: anytype, comptime f: []const u8) i64 {
    if (comptime contract.instLanes(S)) {
        var ls: [S.lane_count]@TypeOf(S.Lane.con(0.0)) = undefined;
        inline for (0..S.lane_count) |w| ls[w] = S.Lane.con(@floatFromInt(@field(S.instLane(@TypeOf(inst.*), w), f)));
        return S.decideI(S.fromLanes(0, ls));
    }
    if (comptime @hasDecl(S, "decideI")) return S.decideI(S.con(@floatFromInt(@field(inst, f)))); // `region` hashes it
    return @field(inst, f);
}
/// Element `k` of array field `f` of the `Instance`, as `zInst` (a §5.10
/// held array is one `[n]f64` field, indexed in a loop).
pub fn zInstA(comptime S: type, inst: anytype, comptime f: []const u8, k: usize) @TypeOf(S.con(0.0)) {
    if (comptime contract.instLanes(S)) {
        var ls: [S.lane_count]@TypeOf(S.Lane.con(0.0)) = undefined;
        inline for (0..S.lane_count) |w| ls[w] = S.Lane.con(@field(S.instLane(@TypeOf(inst.*), w), f)[k]);
        return S.fromLanes(0, ls);
    }
    return S.con(@field(inst, f)[k]);
}
/// Element `k` of integer array field `f` of the `Instance`, as `zInstI`.
pub fn zInstIA(comptime S: type, inst: anytype, comptime f: []const u8, k: usize) i64 {
    if (comptime contract.instLanes(S)) {
        var ls: [S.lane_count]@TypeOf(S.Lane.con(0.0)) = undefined;
        inline for (0..S.lane_count) |w| ls[w] = S.Lane.con(@floatFromInt(@field(S.instLane(@TypeOf(inst.*), w), f)[k]));
        return S.decideI(S.fromLanes(0, ls));
    }
    if (comptime @hasDecl(S, "decideI")) return S.decideI(S.con(@floatFromInt(@field(inst, f)[k]))); // `region` hashes it
    return @field(inst, f)[k];
}
/// Whether `S` runs the lead protocol; a vector family that cannot is
/// refused, since its points would follow point 0's branches.
pub fn zLeads(comptime S: type) bool {
    return contract.leads(S);
}

// The f64 transcendentals for a device's SCALAR paths (the §4.5.15
// limiters): a generated device also compiles for NVPTX/AMDGCN, which have
// no libm (`@exp` on an f64 dies at PTX assembly: "no libcall available for
// fexp"), and std's expm1/log1p/atan raise the underflow flag through an
// `asm volatile` AMDGPU cannot match. These are the one-body ports.

/// e^x for a scalar path.
pub inline fn zDevExp(x: f64) f64 {
    return exp(x);
}
/// e^x - 1 for a scalar path.
pub inline fn zDevExpm1(x: f64) f64 {
    return expm1(x);
}
/// atan for a scalar path.
pub inline fn zDevAtan(x: f64) f64 {
    return atan(x);
}
/// ln for a scalar path.
pub inline fn zDevLog(x: f64) f64 {
    return log(x);
}
/// x^y for a scalar path.
pub inline fn zDevPow(x: f64, y: f64) f64 {
    return pow(x, y);
}
/// sin for a scalar path.
pub inline fn zDevSin(x: f64) f64 {
    return sin(x);
}
/// cos for a scalar path.
pub inline fn zDevCos(x: f64) f64 {
    return cos(x);
}
/// tanh for a scalar path.
pub inline fn zDevTanh(x: f64) f64 {
    return tanh(x);
}
/// sinh for a scalar path.
pub inline fn zDevSinh(x: f64) f64 {
    return sinh(x);
}
/// cosh for a scalar path.
pub inline fn zDevCosh(x: f64) f64 {
    return cosh(x);
}

/// §4.3.2 tan = sin/cos, in the family.
pub fn zTan(comptime S: type, a: S) S {
    return a.sin().div(a.cos());
}

/// `val`, the value of f(a) at `v = a.val()`, with f's slope `g` grafted
/// onto a's derivative through a zero-valued carrier (`zHypot`'s idiom). A
/// non-finite slope (a pole, a branch point) has none worth propagating. At
/// v = ±0 with f(±0) = ±0 (asin, asinh, atanh) the value is `a.scale(g)`;
/// elsewhere the carrier goes in through `zCarry`, which keeps a -0.
pub fn zGraft(comptime S: type, a: S, v: f64, val: f64, g: f64) S {
    if (v == 0.0 and val == 0.0) return a.scale(g);
    var r = S.con(val);
    if (std.math.isFinite(g) and g != 0.0) r = zCarry(S, r, a.addC(-v).scale(g));
    return r;
}

// §4.3.1/§4.3.2 the functions Tables 4-14/4-15 name a C equivalent for and
// the family does not carry: the value is the one function the compiler
// folds with, the derivative the analytic one (#60; the ln/sqrt/atan
// compositions these replace lost up to every digit, VD-123).

/// §4.3.1 log() is base 10, C log10.
pub fn zLog10(comptime S: type, a: S) S {
    const v = a.val();
    return zGraft(S, a, v, log10(v), 0.4342944819032518 / v);
}

/// `a` when `c`, else `b`. Both are arguments, so both are evaluated. A GPU
/// picks with `S.sel`'s lane select: an `if` over two struct values joins
/// them through a pointer phi, which pins both arms' copies in local memory
/// (SROA cannot split them).
pub inline fn zPick(comptime S: type, c: bool, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (comptime z_spec) return S.sel(S.con(if (c) 1.0 else 0.0), a, b);
    return if (c) a else b;
}

// §4.3.2 "Input values outside of the valid range for the operator shall
// report an error", for Table 4-14's one-bound domains: each op with its
// check in front (`opcode_zig.Row.checked`; the unchecked spelling is for a
// value `setup` speculates outside its guard).

/// sqrt, checked (E0604).
pub fn zSqrtD(comptime _: type, a: anytype) callconv(z_spec_cc) @TypeOf(a) {
    const v = a.val();
    zDomain("E0604", "sqrt", "x >= 0", v, v >= 0.0);
    return a.sqrt();
}
/// ln, checked (E0602).
pub fn zLnD(comptime _: type, a: anytype) callconv(z_spec_cc) @TypeOf(a) {
    const v = a.val();
    zDomain("E0602", "ln", "x > 0", v, v > 0.0);
    return a.log();
}
/// ln1p, checked (E0603).
pub fn zLn1pD(comptime _: type, a: anytype) callconv(z_spec_cc) @TypeOf(a) {
    const v = a.val();
    zDomain("E0603", "ln1p", "x > -1", v, v > -1.0);
    return a.log1p();
}
/// log, checked (E0602).
pub fn zLog10D(comptime S: type, a: S) callconv(z_spec_cc) S {
    const v = a.val();
    zDomain("E0602", "log", "x > 0", v, v > 0.0);
    return zLog10(S, a);
}
/// §4.3.1 Table 4-14 pow's domain, "if x > 0, all y; if x = 0, y > 0; if
/// x < 0, all integer y", with the prover's E0609 leniency at x = 0, y = 0
/// (IEEE pow(0, 0) = 1).
pub fn zPowOk(x: f64, y: f64) bool {
    return x > 0.0 or (x == 0.0 and y >= 0.0) or (x < 0.0 and y == @trunc(y));
}
/// `a.pow(k)` for an exponent that does not move with the solve, checked.
pub fn zPowK(comptime _: type, a: anytype, k: f64) callconv(z_spec_cc) @TypeOf(a) {
    const v = a.val();
    zDomain("E0609", "pow", "x > 0, or x = 0 with y >= 0, or x < 0 with integer y", v, zPowOk(v, k));
    return a.pow(k);
}

/// §4.3.1 Table 4-14 hypot, the C library function, which is overflow-free
/// (a²+b² composed in S overflowed for legs ≳1e154). The derivative
/// (a/h)·da + (b/h)·db is grafted on through zero-valued carriers; at h = 0
/// (a cone tip) or a non-finite h there is none.
pub fn zHypot(comptime S: type, a: S, b: S) S {
    const av = a.val();
    const bv = b.val();
    const h = std.math.hypot(av, bv);
    var r = S.con(h);
    if (h != 0.0 and std.math.isFinite(h))
        r = zCarry(S, zCarry(S, r, a.addC(-av).scale(av / h)), b.addC(-bv).scale(bv / h));
    return r;
}

// d asin = dx/sqrt(1-x^2) and d acos its negation, with 1-x^2 as
// (1-x)(1+x): exact near ±1, where x*x rounds the gap away.

/// §4.3.2 asin, C asin, checked (E0605).
pub fn zAsin(comptime S: type, a: S) S {
    const v = a.val();
    zDomain("E0605", "asin", "-1 <= x <= 1", v, v >= -1.0 and v <= 1.0);
    return zGraft(S, a, v, std.math.asin(v), 1.0 / @sqrt((1.0 - v) * (1.0 + v)));
}
/// §4.3.2 acos, C acos, checked (E0605).
pub fn zAcos(comptime S: type, a: S) S {
    const v = a.val();
    zDomain("E0605", "acos", "-1 <= x <= 1", v, v >= -1.0 and v <= 1.0);
    return zGraft(S, a, v, std.math.acos(v), -1.0 / @sqrt((1.0 - v) * (1.0 + v)));
}
/// §4.3.2 asinh; d asinh = dx/sqrt(x^2+1), as dx/|x| past 1e150 where x^2
/// overflows.
pub fn zAsinh(comptime S: type, a: S) S {
    const v = a.val();
    const g = if (@abs(v) > 1e150) 1.0 / @abs(v) else 1.0 / @sqrt(v * v + 1.0);
    return zGraft(S, a, v, asinh(v), g);
}
/// §4.3.2 acosh, checked (E0607).
pub fn zAcosh(comptime S: type, a: S) S {
    const v = a.val();
    zDomain("E0607", "acosh", "x >= 1", v, v >= 1.0);
    return zGraft(S, a, v, acosh(v), 1.0 / (@sqrt(v - 1.0) * @sqrt(v + 1.0)));
}
/// §4.3.2 atanh, checked (E0606).
pub fn zAtanh(comptime S: type, a: S) S {
    const v = a.val();
    zDomain("E0606", "atanh", "-1 < x < 1", v, v > -1.0 and v < 1.0);
    return zGraft(S, a, v, atanh(v), 1.0 / ((1.0 - v) * (1.0 + v)));
}
/// §4.3.2 atan2(y, x), C atan2 (`atan2`'s signed zeros and quadrants).
/// d atan2 = (x dy - y dx)/(x^2 + y^2), on every axis, as (x/h)/h and
/// (y/h)/h with h = hypot(x, y), which does not overflow; none at the
/// origin. On the +x axis the value is y/x, which keeps y's signed zero and
/// carries the same slope (dy/x).
pub fn zAtan2(comptime S: type, y: S, x: S) S {
    const yv = y.val();
    const xv = x.val();
    if (yv == 0.0 and xv > 0.0) return y.div(x);
    const h = std.math.hypot(xv, yv);
    var r = S.con(atan2(yv, xv));
    if (h == 0.0 or !std.math.isFinite(h)) return r;
    // A slope that overflows (h subnormal) has none worth propagating, as
    // in `zGraft`: its zero-valued carrier times inf would make the value NaN.
    const gy = (xv / h) / h;
    const gx = (yv / h) / h;
    if (std.math.isFinite(gy)) r = zCarry(S, r, y.addC(-yv).scale(gy));
    if (std.math.isFinite(gx)) r = zCarry(S, r, x.addC(-xv).scale(-gx));
    return r;
}
/// §4.3.1 floor, derivative 0 almost everywhere.
pub fn zFloor(comptime S: type, a: S) S {
    return S.con(@floor(a.val()));
}
/// §4.3.1 ceil, derivative 0 almost everywhere.
pub fn zCeil(comptime S: type, a: S) S {
    return S.con(@ceil(a.val()));
}

/// §4.2.4 `%` keeps the sign of the first operand: C's fmod, which `@rem`
/// on f64 is, exactly. k = trunc(a/b) is constant almost everywhere, so
/// d = da − k·db, carried by zero-valued grafts so the exact value
/// survives (`zCarry`, a -0 included); a
/// non-finite k (b = 0, or a/b overflowed) or b degrades to da alone (an
/// infinite b's carrier is NaN: fmod(a, inf) = a). A zero `b` is §4.2.4's
/// error (`zModZero`), real operands included, rather than @rem's NaN.
pub fn zFmod(comptime S: type, a: S, b: S) S {
    const av = a.val();
    const bv = b.val();
    if (bv == 0.0) zModZero();
    const k = @trunc(av / bv);
    var r = zCarry(S, S.con(@rem(av, bv)), a.addC(-av));
    if (std.math.isFinite(k) and std.math.isFinite(bv)) r = zCarry(S, r, b.addC(-bv).scale(-k));
    return r;
}

/// §4.3.1 pow with a non-constant exponent, checked (E0609). The value is
/// S's own pow, which handles the negative-base integral-y sign itself; the
/// derivatives are grafted on zero-valued carriers:
///   ∂/∂x = y·x^(y−1), valid for x > 0 and for integral y of either sign;
///   ∂/∂y = x^y·ln(x), only for x > 0 (for x ≤ 0 the legal y move in
///   integer steps, so 0 is the honest slope).
/// Non-finite slopes are dropped the way `zHypot` drops its cone tip.
pub fn zPow(comptime S: type, a: S, b: S, comptime varying_exponent: bool) S {
    const x = a.val();
    const y = b.val();
    zDomain("E0609", "pow", "x > 0, or x = 0 with y >= 0, or x < 0 with integer y", x, zPowOk(x, y));
    const v = S.con(x).pow(y).val();
    // y·x^(y−1) = y·v/x: algebraically exact for x != 0 and ONE pow instead
    // of two (every junction exponent in a SPICE model is a parameter, so
    // codegen sends all of them here: half of mos6_inverter's pow calls,
    // callgrind 2026-09-07). x == 0 keeps the second pow: at y == 1 the true
    // slope is 1 but v/x is 0/0, and dropping it would flatten the row
    // (bjt.va's `1 - mjs` at v == ps).
    const gx = if (x != 0.0) y * v / x else y * S.con(x).pow(y - 1.0).val();
    const gy: f64 = if (varying_exponent and x > 0.0) v * S.con(x).log().val() else 0.0;
    var r = S.con(v);
    if (std.math.isFinite(gx) and gx != 0.0) r = zCarry(S, r, a.addC(-x).scale(gx));
    if (std.math.isFinite(gy) and gy != 0.0) r = zCarry(S, r, b.addC(-y).scale(gy));
    return r;
}

/// §9.17.3 `$limit(access, user_function, args…)`: the value is what the
/// user limiter returned, the DERIVATIVE the access function's. SPICE
/// stamps `I(vlim) + g(vlim)·(v − vlim)`, so the probe is shifted by the
/// constant the clamp moved it rather than replaced: a limiter's own
/// dv_lim/dv = 0 would leave a floating node's row singular.
pub fn zLimitUf(comptime S: type, vnew: S, vlim: S) S {
    return vnew.addC(vlim.val() - vnew.val());
}

/// §4.3.1 integer abs, §3.2's 32-bit result.
pub fn zIabs(a: i64) i64 {
    return @as(i32, @truncate(if (a < 0) -%a else a));
}
/// §4.2.11 `a << n`. The count reads as unsigned: a negative i64 count is a
/// value ≥ 2^63, which vacates every one of §3.2.1's 32 bits, so 0 (std's
/// shl takes a negative count as "shift the other way").
pub fn zShl(a: i64, n: i64) i64 {
    return if (n < 0) 0 else std.math.shl(i64, a, n);
}
/// §4.2.11 `a >> n`, logical on §3.2's 32 bits; a negative count is 0, as `zShl`.
pub fn zShr(a: i64, n: i64) i64 {
    if (n == 0) return a; // preserve signed/unsigned operand identity
    const bits: u32 = @bitCast(@as(i32, @truncate(a)));
    return if (n < 0) 0 else std.math.shr(u32, bits, n);
}
/// §9.14 / IEEE 1364-2005 §17.11.1 `$clog2` of `a` read at `width` bits.
pub fn zClog2(a: i64, width: i64) i64 {
    if (width > 64 and a < 0) return width;
    const mask: u64 = if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
    const bits = @as(u64, @bitCast(a)) & mask;
    return if (bits <= 1) 0 else 64 - @as(i64, @clz(bits - 1));
}
/// §3.3.1 string relations: -1, 0 or 1.
pub fn zStrCmp(a: []const u8, b: []const u8) i64 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// ---- private ----

/// `r` with the lanes of `c`, a zero-valued derivative carrier
/// (`a.addC(-v)` scaled), added, and `r`'s value kept bit for bit, -0
/// included: `r.add(c)` rounds a -0 value to +0 (+0 + -0 is +0 in
/// round-to-nearest), while `r.sub(z)` with z = +0 is `r`. So the carrier
/// goes in negated as `0 - c`, whose value is +0 whatever `c`'s zero's sign.
/// The lanes are `r`'s plus `c`'s, as `r.add(c)` gives them (but for a
/// zero lane's sign).
inline fn zCarry(comptime S: type, r: S, c: S) S {
    return r.sub(S.con(0.0).sub(c));
}

fn acoshBody(x: f64) f64 {
    const e = (@as(u64, @bitCast(x)) >> 52) & 0x7FF;
    // musl reads |x|'s exponent and leaves the sign to the formulas, which
    // give NaN for x in (-2, 1) but a finite value at x <= -2: C99 F.10.2.1
    // and Table 4-14 make every x < 1 a domain error.
    if (x < 0 and e >= 0x3FF + 1) return std.math.nan(f64);
    if (e < 0x3FF + 1) return log1p(x - 1 + @sqrt((x - 1) * (x - 1) + 2 * (x - 1)));
    if (e < 0x3FF + 26) return log(2 * x - 1 / (x + @sqrt(x * x - 1)));
    return log(x) + 0.693147180559945309417232121458176568;
}

fn atan2Body(y: f64, x: f64) f64 {
    const pi: f64 = 3.1415926535897931160E+00;
    const pi_lo: f64 = 1.2246467991473531772E-16;
    if (std.math.isNan(x) or std.math.isNan(y)) return x + y;
    const ux: u64 = @bitCast(x);
    var ix: u32 = @intCast(ux >> 32);
    const lx: u32 = @intCast(ux & 0xFFFFFFFF);
    const uy: u64 = @bitCast(y);
    var iy: u32 = @intCast(uy >> 32);
    const ly: u32 = @intCast(uy & 0xFFFFFFFF);
    if ((ix -% 0x3FF00000) | lx == 0) return atan(y); // x = 1.0
    // 2 * sign(x) + sign(y)
    const m = ((iy >> 31) & 1) | ((ix >> 30) & 2);
    ix &= 0x7FFFFFFF;
    iy &= 0x7FFFFFFF;
    if (iy | ly == 0) return switch (m) {
        0, 1 => y, // atan(+-0, +...)
        2 => pi, // atan(+0, -...)
        else => -pi, // else: m is 3, atan(-0, -...)
    };
    if (ix | lx == 0) return if (m & 1 != 0) -pi / 2.0 else pi / 2.0;
    if (ix == 0x7FF00000) {
        if (iy == 0x7FF00000) return switch (m) {
            0 => pi / 4.0,
            1 => -pi / 4.0,
            2 => 3.0 * pi / 4.0,
            else => -3.0 * pi / 4.0, // else: m is 3
        };
        return switch (m) {
            0 => 0.0,
            1 => -0.0,
            2 => pi,
            else => -pi, // else: m is 3
        };
    }
    // |y / x| > 0x1p64
    if (ix +% (64 << 20) < iy or iy == 0x7FF00000) return if (m & 1 != 0) -pi / 2.0 else pi / 2.0;
    // z = atan(|y / x|) with correct underflow
    const z = if ((m & 2) != 0 and iy +% (64 << 20) < ix) 0.0 else atan(@abs(y / x));
    return switch (m) {
        0 => z,
        1 => -z,
        2 => pi - (z - pi_lo),
        else => (z - pi_lo) - pi, // else: m is 3
    };
}

test "exp/log/pow fold at comptime to the bits they run to" {
    // One fma-free body: Zig's comptime evaluates plain IEEE f64 arithmetic
    // target-independently, so a run that matches the fold matches every
    // target the same code compiles for.
    const xs = [_]f64{ -744.9, -20.5, -1e-9, 0.0, 0.693, 1.0, 22.0, 709.7 };
    inline for (xs) |x| {
        const folded = comptime blk: {
            @setEvalBranchQuota(1_000_000);
            break :blk exp(x);
        };
        var v = x;
        std.mem.doNotOptimizeAway(&v);
        try std.testing.expectEqual(@as(u64, @bitCast(folded)), @as(u64, @bitCast(exp(v))));
    }
}

test "acosh is NaN for every x below 1; atan2 keeps C99's signed zeros" {
    for ([_]f64{ 0.5, 0.0, -1.0, -2.0, -12345.678, -1e300, -std.math.inf(f64) }) |x|
        try std.testing.expect(std.math.isNan(acosh(x)));
    try std.testing.expectEqual(@as(f64, 0.0), acosh(1.0));
    try std.testing.expectEqual(std.math.pi, atan2(0.0, -0.0));
    try std.testing.expectEqual(-std.math.pi, atan2(-0.0, -1.0));
    try std.testing.expectEqual(@as(u64, 1 << 63), @as(u64, @bitCast(atan2(-0.0, 1.0))));
}

test "log10 is exact at every power of ten a double holds exactly; atan keeps -0" {
    // VD-123's claim for the old musl log10, kept across the swap.
    var p: f64 = 1;
    for (0..23) |k| {
        try std.testing.expectEqual(@as(f64, @floatFromInt(k)), log10(p));
        p *= 10;
    }
    try std.testing.expectEqual(@as(u64, 1 << 63), @as(u64, @bitCast(atan(-0.0))));
}
