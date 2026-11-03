//! `diff-kernels` part 1, the pure kernels: every function of the old
//! kernel text (`old_text`: math, ops, family, ac, storage) and of
//! `lib/kernels` (limit, timer, rng, filter, wide) against its
//! `std_kernels` port, on the same arguments, over the specials and
//! `g.random_per_fn` seeded draws each. A kernel generic over a scalar
//! runs at one shared kernel scalar `K` (the new `zL` over the contract's
//! `RefFamily`), so the two bodies see the same operations.
//! Cites: none (test tooling; the kernels' own clauses are theirs).
//!
//! Contents:
//! - `pub const Ref`, `pub const K`: the family and the kernel scalar the comparisons share
//! - `pub fn run(rep: *g.Report) void`
//! - argument specs: each a struct with `pub const T` (the argument's type) and `pub fn gen`

const std = @import("std");
const g = @import("gen.zig");
const contract = @import("contract");
const sk = @import("std_kernels");
const old = @import("old_text");
const ok = @import("kernels");

const cmp = g.cmp;
const R = g.AnyReal;

/// Two unknowns, both carried: every value has both lanes.
pub const Ref = contract.RefFamily(f64, &[2]u8{ 0, 1 }, .{});
/// The kernel scalar every generic kernel runs at.
pub const K = Fam.zL(Ref, 3);

const I64 = g.Of(i64);
const Fam = sk.family.Family(2, ~@as(u64, 0));
const OldL = old.zL(Ref, 3);
const RefV = Ref.Of(3);

/// A family value: a real value and two lanes, mostly moderate.
const RefSpec = struct {
    pub const T = RefV;
    pub fn gen(r: g.Rng, i: usize) RefV {
        const lane = g.Real(-10, 10);
        return .{ .v = R.gen(r, i), .d = .{ lane.gen(r, i +% 7), lane.gen(r, i +% 13) } };
    }
};
const KSpec = struct {
    pub const T = K;
    pub fn gen(r: g.Rng, i: usize) K {
        return .{ .v = RefSpec.gen(r, i) };
    }
};
/// `KSpec` with a nonzero value: `zFmod`'s divisor (§4.2.4's zero traps).
const KNonZero = struct {
    pub const T = K;
    pub fn gen(r: g.Rng, i: usize) K {
        var k = KSpec.gen(r, i);
        if (k.v.v == 0 or std.math.isNan(k.v.v)) k.v.v = 1.5;
        return k;
    }
};

/// A `SimState` with any analysis, flags and time.
const SimSpec = struct {
    pub const T = contract.SimState;
    pub fn gen(r: g.Rng, i: usize) T {
        return .{
            .t = R.gen(r, i),
            .dt = R.gen(r, i +% 5),
            .kind = g.Of(contract.AnalysisKind).gen(r, i),
            .initial_step = r.boolean(),
            .final_step = r.boolean(),
            .analog_initial = r.boolean(),
            .iteration = r.int(u32),
        };
    }
};

pub fn run(rep: *g.Report) void {
    mathText(rep);
    familyText(rep);
    opsText(rep);
    lib(rep);
    wide(rep);
}

// ---- private ----

fn mathText(rep: *g.Report) void {
    cmp(rep, "math.zMinF", old.zMinF, sk.math.zMinF, .{}, .{ R, R });
    cmp(rep, "math.zMaxF", old.zMaxF, sk.math.zMaxF, .{}, .{ R, R });
    cmp(rep, "math.zPowOk", old.zPowOk, sk.math.zPowOk, .{}, .{ R, R });
    cmp(rep, "math.zIabs", old.zIabs, sk.math.zIabs, .{}, .{I64});
    cmp(rep, "math.zShl", old.zShl, sk.math.zShl, .{}, .{ I64, g.Int(i64, -70, 70) });
    cmp(rep, "math.zShr", old.zShr, sk.math.zShr, .{}, .{ I64, g.Int(i64, -70, 70) });
    cmp(rep, "math.zClog2", old.zClog2, sk.math.zClog2, .{}, .{ I64, g.Int(i64, 0, 200) });
    inline for (.{ "Exp", "Expm1", "Atan", "Log", "Sin", "Cos", "Tanh", "Sinh", "Cosh" }) |f|
        cmp(rep, "math.zDev" ++ f, @field(old, "zDev" ++ f), @field(sk.math, "zDev" ++ f), .{}, .{R});
    cmp(rep, "math.zDevPow", old.zDevPow, sk.math.zDevPow, .{}, .{ R, g.Real(-30, 30) });
    inline for (.{ "zMin", "zMax", "zHypot", "zAtan2" }) |f|
        cmp(rep, "math." ++ f, @field(old, f), @field(sk.math, f), .{K}, .{ KSpec, KSpec });
    inline for (.{ "zTan", "zLog10", "zSqrtD", "zLnD", "zLn1pD", "zLog10D", "zAsin", "zAcos", "zAsinh", "zAcosh", "zAtanh", "zFloor", "zCeil" }) |f|
        cmp(rep, "math." ++ f, @field(old, f), @field(sk.math, f), .{K}, .{KSpec});
    cmp(rep, "math.zFmod", old.zFmod, sk.math.zFmod, .{K}, .{ KSpec, KNonZero });
    inline for (.{ true, false }) |ve| {
        const pw = struct {
            fn o(a: K, b: K) K {
                return old.zPow(K, a, b, ve);
            }
            fn n(a: K, b: K) K {
                return sk.math.zPow(K, a, b, ve);
            }
        };
        cmp(rep, if (ve) "math.zPow.varying" else "math.zPow.fixed", pw.o, pw.n, .{}, .{ KSpec, KSpec });
    }
    cmp(rep, "math.zPowK", old.zPowK, sk.math.zPowK, .{K}, .{ KSpec, g.Real(-30, 30) });
    cmp(rep, "math.zLimitUf", old.zLimitUf, sk.math.zLimitUf, .{K}, .{ KSpec, KSpec });
    cmp(rep, "math.zGraft", old.zGraft, sk.math.zGraft, .{K}, .{ KSpec, R, R, R });
    inline for (comptime std.enums.values(std.math.CompareOperator)) |op|
        cmp(rep, "math.zCmp." ++ @tagName(op), old.zCmp, sk.math.zCmp, .{ Ref, op }, .{ RefSpec, RefSpec });
    cmp(rep, "math.zRoundI", old.zRoundI, sk.math.zRoundI, .{Ref}, .{RefSpec});
    cmp(rep, "math.zStrip", old.zStrip, sk.math.zStrip, .{Ref}, .{RefSpec});
    inline for (.{ "zMulP", "zAddP", "zSubP" }) |f|
        cmp(rep, "math." ++ f, @field(old, f), @field(sk.math, f), .{Ref}, .{ RefSpec, RefSpec });
    const Inst = struct { f: f64, n: i64 };
    const inst = struct {
        fn val(x: f64) Inst {
            return .{ .f = x, .n = std.math.lossyCast(i64, x) };
        }
        fn o(x: f64) Ref.Of(0) {
            return old.zInst(Ref, val(x), "f");
        }
        fn n(x: f64) Ref.Of(0) {
            return sk.math.zInst(Ref, val(x), "f");
        }
        fn oi(x: f64) i64 {
            return old.zInstI(Ref, val(x), "n");
        }
        fn ni(x: f64) i64 {
            return sk.math.zInstI(Ref, val(x), "n");
        }
    };
    cmp(rep, "math.zInst", inst.o, inst.n, .{}, .{R});
    cmp(rep, "math.zInstI", inst.oi, inst.ni, .{}, .{R});
    rep.record("math.zLeads", if (old.zLeads(Ref) == sk.math.zLeads(Ref)) 0 else std.math.maxInt(u64), .{});
    const strs = struct {
        const pool = [_][]const u8{ "", "a", "ab", "abc", "b", "\x00", "zz", "Ab", "aB", "abd" };
        const Str = struct {
            pub const T = []const u8;
            pub fn gen(r: g.Rng, i: usize) []const u8 {
                return pool[if (i < pool.len) i else r.uintLessThan(usize, pool.len)];
            }
        };
    };
    cmp(rep, "math.zStrCmp", old.zStrCmp, sk.math.zStrCmp, .{}, .{ strs.Str, strs.Str });
}

fn familyText(rep: *g.Report) void {
    cmp(rep, "family.zAbs", old.zAbs, Fam.zAbs, .{Ref}, .{RefSpec});
    cmp(rep, "family.zV", old.zV, Fam.zV, .{}, .{RefSpec});
    inline for (.{ true, false }) |ve| {
        const pw = struct {
            fn o(a: RefV, b: RefV) RefV {
                return old.zPowL(Ref, 3, a, b, ve);
            }
            fn n(a: RefV, b: RefV) RefV {
                return Fam.zPowL(Ref, 3, a, b, ve);
            }
        };
        cmp(rep, if (ve) "family.zPowL.varying" else "family.zPowL.fixed", pw.o, pw.n, .{}, .{ RefSpec, RefSpec });
    }
    // `zL`'s methods: the same family value as each `zL`.
    inline for (.{ "neg", "exp", "log", "expm1", "log1p", "sqrt", "sin", "cos", "tanh", "sinh", "cosh", "atan", "abs" }) |m|
        cmp(rep, "family.zL." ++ m, Method(m, 1).old, Method(m, 1).new, .{}, .{RefSpec});
    inline for (.{ "add", "sub", "mul", "div", "lt", "le", "eq", "min", "max" }) |m|
        cmp(rep, "family.zL." ++ m, Method(m, 2).old, Method(m, 2).new, .{}, .{ RefSpec, RefSpec });
    inline for (.{ "scale", "addC", "pow", "minC", "maxC" }) |m|
        cmp(rep, "family.zL." ++ m, MethodC(m).old, MethodC(m).new, .{}, .{ RefSpec, R });
    const sel = struct {
        fn o(c: RefV, a: RefV, b: RefV) RefV {
            return OldL.sel(.{ .v = c }, .{ .v = a }, .{ .v = b }).v;
        }
        fn n(c: RefV, a: RefV, b: RefV) RefV {
            return K.sel(.{ .v = c }, .{ .v = a }, .{ .v = b }).v;
        }
    };
    cmp(rep, "family.zL.sel", sel.o, sel.n, .{}, .{ RefSpec, RefSpec, RefSpec });
}

fn opsText(rep: *g.Report) void {
    cmp(rep, "ops.zIdt", old.zIdt, sk.ops.zIdt, .{K}, .{ KSpec, R, R, R });
    cmp(rep, "ops.zIdtHold", old.zIdtHold, sk.ops.zIdtHold, .{K}, .{ KSpec, R, R, R });
    cmp(rep, "ops.zIdtAcc", old.zIdtAcc, sk.ops.zIdtAcc, .{}, .{ R, R, R, R });
    cmp(rep, "ops.zIdtmod", old.zIdtmod, sk.ops.zIdtmod, .{K}, .{ KSpec, R, R, R, R, R });
    cmp(rep, "ops.zWrap", old.zWrap, sk.ops.zWrap, .{}, .{ R, R, R });
    cmp(rep, "ops.zSlew", old.zSlew, sk.ops.zSlew, .{K}, .{ KSpec, R, R, R, R });
    cmp(rep, "ops.zLastCross", old.zLastCross, sk.ops.zLastCross, .{K}, .{ KSpec, R, R, R, R, g.Of(bool) });
    cmp(rep, "ops.zCrossDir", old.zCrossDir, sk.ops.zCrossDir, .{}, .{ R, R, R });
    cmp(rep, "ops.zCrossRetry", old.zCrossRetry, sk.ops.zCrossRetry, .{}, .{ R, R, R, R, R, R });
    cmp(rep, "ops.zTransFrac", old.zTransFrac, sk.ops.zTransFrac, .{}, .{ R, R, R, R, R, R });
    cmp(rep, "ops.zTransition", old.zTransition, sk.ops.zTransition, .{K}, .{ KSpec, R, R, R, R, R, R, R });
    cmp(rep, "ops.zTransStep", stepPair(old.zTransStep), stepPair(sk.ops.zTransStep), .{}, .{ R, R, R, R, R, R, R, R, R });
    // storage
    cmp(rep, "storage.zTpKey", old.zTpKey, sk.storage.zTpKey, .{}, .{SimSpec});
    cmp(rep, "storage.zTpHit", old.zTpHit, sk.storage.zTpHit, .{}, .{ R, g.Of(u8), SimSpec });
    const arr = struct {
        const a = [5]f64{ 1, -2, 3.5, std.math.nan(f64), -0.0 };
        fn ldO(i: i64, z: f64) f64 {
            return old.zArrLd(f64, &a, i, z);
        }
        fn ldN(i: i64, z: f64) f64 {
            return sk.storage.zArrLd(f64, &a, i, z);
        }
        fn st(comptime f: anytype, i: i64, v: f64) [5]f64 {
            var b = a;
            f(f64, &b, i, v);
            return b;
        }
        fn stO(i: i64, v: f64) [5]f64 {
            return st(old.zArrSt, i, v);
        }
        fn stN(i: i64, v: f64) [5]f64 {
            return st(sk.storage.zArrSt, i, v);
        }
        fn stD(comptime f: anytype, i: i64, v: f64, lo: i64) struct { [5]f64, [2]i64 } {
            var b = a;
            var d = [2]i64{ lo, lo + 1 };
            f(f64, &b, &d, i, v);
            return .{ b, d };
        }
        fn stDO(i: i64, v: f64, lo: i64) struct { [5]f64, [2]i64 } {
            return stD(old.zArrStD, i, v, lo);
        }
        fn stDN(i: i64, v: f64, lo: i64) struct { [5]f64, [2]i64 } {
            return stD(sk.storage.zArrStD, i, v, lo);
        }
    };
    const Idx = g.Int(i64, -8, 8);
    cmp(rep, "storage.zArrLd", arr.ldO, arr.ldN, .{}, .{ Idx, R });
    cmp(rep, "storage.zArrSt", arr.stO, arr.stN, .{}, .{ Idx, R });
    cmp(rep, "storage.zArrStD", arr.stDO, arr.stDN, .{}, .{ Idx, R, g.Int(i64, -2, 6) });
}

fn lib(rep: *g.Report) void {
    const L = ok.limit_kernels;
    const Fin = g.RealIn(-1e3, 1e3);
    cmp(rep, "limit.zPnjlim", L.zPnjlim, sk.limit.zPnjlim, .{}, .{ R, R, g.RealIn(1e-3, 1), g.RealIn(0.1, 2) });
    cmp(rep, "limit.zFetlim", L.zFetlim, sk.limit.zFetlim, .{}, .{ R, R, R });
    cmp(rep, "limit.zLimvds", L.zLimvds, sk.limit.zLimvds, .{}, .{ R, R });
    cmp(rep, "limit.zSteplim", L.zSteplim, sk.limit.zSteplim, .{}, .{ Fin, Fin, g.RealIn(0, 10) });
    const OT = ok.timer_kernels;
    cmp(rep, "timer.zNextTimer", OT.zNextTimer, sk.ops.zNextTimer, .{}, .{ R, R, R });
    cmp(rep, "timer.zTimerPending", OT.zTimerPending, sk.ops.zTimerPending, .{}, .{ Fin, R, Fin, R, R, R });
    const due = struct {
        fn call(comptime f: anytype, back: f64, period: f64, t: f64, os: f64, op: f64, pend: f64) bool {
            return f(t - @abs(back), period, t, os, op, pend);
        }
        fn o(back: f64, period: f64, t: f64, os: f64, op: f64, pend: f64) bool {
            return call(OT.zTimerDue, back, period, t, os, op, pend);
        }
        fn n(back: f64, period: f64, t: f64, os: f64, op: f64, pend: f64) bool {
            return call(sk.ops.zTimerDue, back, period, t, os, op, pend);
        }
    };
    cmp(rep, "timer.zTimerDue", due.o, due.n, .{}, .{ Fin, R, Fin, R, R, R });
    // rng: inside each distribution's domain (outside it exits, E0816).
    const G = ok.rng_kernels;
    const N = sk.rng;
    const Seed = g.Of(i64);
    const Whole = struct {
        pub const T = f64;
        pub fn gen(r: g.Rng, i: usize) f64 {
            return @floatFromInt(if (i < 4) @as(i32, @intCast(i)) + 1 else r.intRangeAtMost(i32, 1, 60));
        }
    };
    const Lo = g.RealIn(-1e6, -1e-3);
    const Hi = g.RealIn(1e-3, 1e6);
    const Pos = g.RealIn(1e-3, 1e3);
    const IntR = struct {
        pub const T = f64;
        pub fn gen(r: g.Rng, _: usize) f64 {
            return @floatFromInt(r.intRangeAtMost(i32, -1_000_000, 1_000_000));
        }
    };
    cmp(rep, "rng.zRngCheck", G.zRngCheck, N.zRngCheck, .{}, .{ R, g.Int(u4, 0, 0), R, R });
    cmp(rep, "rng.zRngNext", G.zRngNext, N.zRngNext, .{}, .{Seed});
    cmp(rep, "rng.zRngRand", G.zRngRand, N.zRngRand, .{}, .{Seed});
    cmp(rep, "rng.zRngIUniform", G.zRngIUniform, N.zRngIUniform, .{}, .{ Seed, IntR, IntR });
    cmp(rep, "rng.zRngIUniformNext", G.zRngIUniformNext, N.zRngIUniformNext, .{}, .{ Seed, IntR, IntR });
    cmp(rep, "rng.zRngUniform", G.zRngUniform, N.zRngUniform, .{}, .{ Seed, Lo, Hi });
    cmp(rep, "rng.zRngUniformNext", G.zRngUniformNext, N.zRngUniformNext, .{}, .{ Seed, Lo, Hi });
    cmp(rep, "rng.zRngNormal", G.zRngNormal, N.zRngNormal, .{}, .{ Seed, Fin, Fin });
    cmp(rep, "rng.zRngNormalNext", G.zRngNormalNext, N.zRngNormalNext, .{}, .{ Seed, Fin, Fin });
    cmp(rep, "rng.zRngExponential", G.zRngExponential, N.zRngExponential, .{}, .{ Seed, Pos });
    cmp(rep, "rng.zRngExponentialNext", G.zRngExponentialNext, N.zRngExponentialNext, .{}, .{ Seed, Pos });
    cmp(rep, "rng.zRngPoisson", G.zRngPoisson, N.zRngPoisson, .{}, .{ Seed, g.RealIn(1e-3, 60) });
    cmp(rep, "rng.zRngPoissonNext", G.zRngPoissonNext, N.zRngPoissonNext, .{}, .{ Seed, g.RealIn(1e-3, 60) });
    cmp(rep, "rng.zRngChiSquare", G.zRngChiSquare, N.zRngChiSquare, .{}, .{ Seed, Whole });
    cmp(rep, "rng.zRngChiSquareNext", G.zRngChiSquareNext, N.zRngChiSquareNext, .{}, .{ Seed, Whole });
    cmp(rep, "rng.zRngT", G.zRngT, N.zRngT, .{}, .{ Seed, Whole });
    cmp(rep, "rng.zRngTNext", G.zRngTNext, N.zRngTNext, .{}, .{ Seed, Whole });
    cmp(rep, "rng.zRngErlang", G.zRngErlang, N.zRngErlang, .{}, .{ Seed, Whole, Pos });
    cmp(rep, "rng.zRngErlangNext", G.zRngErlangNext, N.zRngErlangNext, .{}, .{ Seed, Whole, Pos });
    // filter: the pure section arithmetic.
    const Q = ok.filter_kernels;
    const F = sk.filter;
    cmp(rep, "filter.zZiDue", Q.zZiDue, F.zZiDue, .{}, .{ R, g.Real(0, 1e4), R });
    cmp(rep, "filter.zZiRamp", Q.zZiRamp, F.zZiRamp, .{}, .{ R, R, R, R, R });
    cmp(rep, "filter.zBilin", Q.zBilin, F.zBilin, .{3}, .{ Arr(R, 4), R, g.Int(usize, 0, 3) });
    cmp(rep, "filter.zDeg", Q.zDeg, F.zDeg, .{2}, .{Sec(2)});
    cmp(rep, "filter.zH0", Q.zH0, F.zH0, .{2}, .{Sec(2)});
    cmp(rep, "filter.zSsForm", Q.zSsForm, F.zSsForm, .{2}, .{Sec(2)});
    cmp(rep, "filter.zLaplaceH0", Q.zLaplaceH0, F.zLaplaceH0, .{ 2, 2 }, .{Arr(Sec(2), 2)});
    cmp(rep, "filter.zZiGain", Q.zZiGain, F.zZiGain, .{ 2, 2 }, .{Arr(Sec(2), 2)});
    cmp(rep, "filter.zRootSecs.s", Q.zRootSecs, F.zRootSecs, .{ 3, false }, .{Arr(R, 6)});
    cmp(rep, "filter.zRootSecs.z", Q.zRootSecs, F.zRootSecs, .{ 3, true }, .{Arr(R, 6)});
    const hist = struct {
        fn secR(comptime f: anytype, u: f64, b: [3]f64, a: [3]f64, h: [4]f64) f64 {
            return f(2, u, b, a, h[0..2], h[2..4]);
        }
        fn o(u: f64, b: [3]f64, a: [3]f64, h: [4]f64) f64 {
            return secR(Q.zSecR, u, b, a, h);
        }
        fn n(u: f64, b: [3]f64, a: [3]f64, h: [4]f64) f64 {
            return secR(F.zSecR, u, b, a, h);
        }
        fn step(comptime f: anytype, u: f64, sec: [2][2][3]f64, h: [8]f64) struct { f64, [8]f64 } {
            var b = h;
            const y = f(2, 2, u, sec, b[0..4], b[4..8]);
            return .{ y, b };
        }
        fn so(u: f64, sec: [2][2][3]f64, h: [8]f64) struct { f64, [8]f64 } {
            return step(Q.zZiStep, u, sec, h);
        }
        fn sn(u: f64, sec: [2][2][3]f64, h: [8]f64) struct { f64, [8]f64 } {
            return step(F.zZiStep, u, sec, h);
        }
        fn eval(comptime f: anytype, u: K, sec: [2][2][3]f64, dt: f64, out: f64, t: f64, nk: f64, h: [8]f64) K {
            return f(K, 2, 2, u, sec, dt, out, t, nk, 1e-3, h[0..4], h[4..8]);
        }
        fn eo(u: K, sec: [2][2][3]f64, dt: f64, out: f64, t: f64, nk: f64, h: [8]f64) K {
            return eval(Q.zZiEval, u, sec, dt, out, t, nk, h);
        }
        fn en(u: K, sec: [2][2][3]f64, dt: f64, out: f64, t: f64, nk: f64, h: [8]f64) K {
            return eval(F.zZiEval, u, sec, dt, out, t, nk, h);
        }
        fn lap(comptime f: anytype, u: K, sec: [2][2][3]f64, dt: f64, h: [8]f64) K {
            return f(K, 2, 2, u, sec, dt, h[0..4], h[4..8]);
        }
        fn lo(u: K, sec: [2][2][3]f64, dt: f64, h: [8]f64) K {
            return lap(Q.zLaplace, u, sec, dt, h);
        }
        fn ln(u: K, sec: [2][2][3]f64, dt: f64, h: [8]f64) K {
            return lap(F.zLaplace, u, sec, dt, h);
        }
    };
    cmp(rep, "filter.zSecR", hist.o, hist.n, .{}, .{ R, Arr(R, 3), Arr(R, 3), Arr(R, 4) });
    cmp(rep, "filter.zZiStep", hist.so, hist.sn, .{}, .{ R, Arr(Sec(2), 2), Arr(R, 8) });
    cmp(rep, "filter.zZiEval", hist.eo, hist.en, .{}, .{ KSpec, Arr(Sec(2), 2), g.Real(0, 1e-3), R, g.RealIn(0, 1), g.RealIn(0, 1000), Arr(R, 8) });
    cmp(rep, "filter.zLaplace", hist.lo, hist.ln, .{}, .{ KSpec, Arr(Sec(2), 2), g.Real(0, 1e-3), Arr(R, 8) });
    // ac: the complex helpers (`zAcDelay`/`zAcLaplace`/`zAcZi` read `Ac`'s
    // lanes, held in `ac` part of `state.zig`).
    const C = std.math.Complex(f64);
    const CSpec = struct {
        pub const T = C;
        pub fn gen(r: g.Rng, i: usize) C {
            return .init(R.gen(r, i), R.gen(r, i +% 3));
        }
    };
    cmp(rep, "ac.zCDiv", old.zCDiv, sk.ac.zCDiv, .{f64}, .{ CSpec, CSpec });
    cmp(rep, "ac.zPolyC", old.zPolyC, sk.ac.zPolyC, .{ f64, 2 }, .{ Arr(R, 3), CSpec });
}

fn wide(rep: *g.Report) void {
    const W = ok.wide_kernels;
    const N = sk.wide;
    inline for (.{ 1, 8, 31, 32, 33, 63, 64, 65, 100, 128, 129, 200 }) |n| {
        const Z = WSpec(n);
        const p = std.fmt.comptimePrint("wide.{d}.", .{n});
        inline for (.{ "zwAdd", "zwSub", "zwMul", "zwAnd", "zwOr", "zwXor", "zwXnor", "zwEq" }) |f|
            cmp(rep, p ++ f, @field(W, f), @field(N, f), .{n}, .{ Z, Z });
        inline for (.{ "zwNeg", "zwNot", "zwIsZero", "zwAll", "zwParity", "zwToLimbs" }) |f|
            cmp(rep, p ++ f, @field(W, f), @field(N, f), .{n}, .{Z});
        inline for (.{ false, true }) |s| {
            const q = p ++ (if (s) "signed." else "unsigned.");
            inline for (.{ "zwDiv", "zwRem", "zwLt" }) |f|
                cmp(rep, q ++ f, @field(W, f), @field(N, f), .{ n, s }, .{ Z, Z });
            cmp(rep, q ++ "zwToReal", W.zwToReal, N.zwToReal, .{ n, s }, .{Z});
            if (n < 64) cmp(rep, q ++ "zwInt", W.zwInt, N.zwInt, .{ n, s }, .{Z});
            cmp(rep, q ++ "zwResize", W.zwResize, N.zwResize, .{ 77, n, s }, .{Z});
            const ws = struct {
                fn powO(a: Z.T, e: W.ZW(9)) Z.T {
                    return W.zwPow(n, s, a, 9, s, e);
                }
                fn powN(a: Z.T, e: W.ZW(9)) Z.T {
                    return N.zwPow(n, s, a, 9, s, e);
                }
                fn shrO(a: Z.T, c: W.ZW(9)) Z.T {
                    return W.zwShr(n, s, a, 9, c);
                }
                fn shrN(a: Z.T, c: W.ZW(9)) Z.T {
                    return N.zwShr(n, s, a, 9, c);
                }
            };
            cmp(rep, q ++ "zwPow", ws.powO, ws.powN, .{}, .{ Z, WSpec(9) });
            cmp(rep, q ++ "zwShr", ws.shrO, ws.shrN, .{}, .{ Z, WSpec(9) });
        }
        const wl = struct {
            fn o(a: Z.T, c: W.ZW(9)) Z.T {
                return W.zwShl(n, a, 9, c);
            }
            fn n_(a: Z.T, c: W.ZW(9)) Z.T {
                return N.zwShl(n, a, 9, c);
            }
        };
        cmp(rep, p ++ "zwShl", wl.o, wl.n_, .{}, .{ Z, WSpec(9) });
        cmp(rep, p ++ "zwBit", W.zwBit, N.zwBit, .{n}, .{ Z, g.Int(u32, 0, n - 1) });
        cmp(rep, p ++ "zwFromReal", W.zwFromReal, N.zwFromReal, .{n}, .{g.Real(-1e40, 1e40)});
        cmp(rep, p ++ "zwLeaf", W.zwLeaf, N.zwLeaf, .{n}, .{I64});
    }
}

/// `[n]Sp.T`, each element its own draw.
fn Arr(comptime Sp: type, comptime n: usize) type {
    return struct {
        pub const T = [n]Sp.T;
        pub fn gen(r: g.Rng, i: usize) T {
            var a: T = undefined;
            for (&a, 0..) |*x, k| x.* = Sp.gen(r, if (i < g.specials.len) (i + k) % g.specials.len else i);
            return a;
        }
    };
}

/// A filter section `[2][D + 1]f64`: numerator and denominator.
fn Sec(comptime D: usize) type {
    return Arr(Arr(g.Real(-10, 10), D + 1), 2);
}

/// A width-`n` two-state integer: zero, all ones, one, the sign bit, then
/// random limbs.
fn WSpec(comptime n: u32) type {
    const W = ok.wide_kernels;
    return struct {
        pub const T = W.ZW(n);
        pub fn gen(r: g.Rng, i: usize) T {
            const k = comptime W.zwLimbs(n);
            var l: [k]u32 = undefined;
            for (&l) |*x| x.* = switch (i) {
                0 => 0,
                1 => std.math.maxInt(u32),
                else => r.int(u32),
            };
            if (i == 2) l = @splat(0);
            if (i == 2) l[0] = 1;
            if (i == 3) {
                l = @splat(0);
                l[k - 1] = @as(u32, 1) << @intCast((n - 1) % 32);
            }
            if (i > 3 and r.boolean()) for (l[1..]) |*x| {
                x.* = 0;
            };
            // The bits past `n` stay zero, as every wide value keeps them.
            if (n % 32 != 0) l[k - 1] &= (@as(u32, 1) << @intCast(n % 32)) - 1;
            return W.zwFromLimbs(n, l);
        }
    };
}

/// `zL`'s unary or binary method `name`, the old and the new, over family values.
fn Method(comptime name: []const u8, comptime arity: u8) type {
    return if (arity == 1) struct {
        fn old(a: RefV) RefV {
            return @field(OldL, name)(.{ .v = a }).v;
        }
        fn new(a: RefV) RefV {
            return @field(K, name)(.{ .v = a }).v;
        }
    } else struct {
        fn old(a: RefV, b: RefV) RefV {
            return @field(OldL, name)(.{ .v = a }, .{ .v = b }).v;
        }
        fn new(a: RefV, b: RefV) RefV {
            return @field(K, name)(.{ .v = a }, .{ .v = b }).v;
        }
    };
}

/// `zL`'s method `name` with a real constant.
fn MethodC(comptime name: []const u8) type {
    return struct {
        fn old(a: RefV, c: f64) RefV {
            return @field(OldL, name)(.{ .v = a }, c).v;
        }
        fn new(a: RefV, c: f64) RefV {
            return @field(K, name)(.{ .v = a }, c).v;
        }
    };
}

fn stepPair(comptime f: anytype) fn (f64, f64, f64, f64, f64, f64, f64, f64, f64) [3]f64 {
    return struct {
        fn run(in: f64, from: f64, to: f64, t0: f64, t: f64, dt: f64, td: f64, rise: f64, fall: f64) [3]f64 {
            var s = [3]f64{ from, to, t0 };
            f(in, &s[0], &s[1], &s[2], t, dt, td, rise, fall);
            return s;
        }
    }.run;
}
