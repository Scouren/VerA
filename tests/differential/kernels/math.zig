//! `diff-kernels` part 2, the math swap: every function `contract.gm`
//! provides against `std_kernels.math` (Gompute 2.0.0's, and VerA's four
//! over it), scalar and vector, each difference judged by the f128
//! reference (`reference.zig`) so the log says which side is wrong; then
//! the compiler's folds (`fold.math`, `unary`, `binary`, ...) and the
//! small-signal family `Ac`, old against new, since both now call Gompute.
//! Cites: VAMS §4.2, §4.3 (Tables 4-14, 4-15); C99 F.10.
//!
//! Contents:
//! - `pub fn run(rep: *g.Report) void`
//! - `pub fn judgeAt(comptime name: []const u8, x: f64, y: f64, old_v: f64, new_v: f64) ?g.Judgement`
//! - argument specs: each a struct with `pub const T` (the argument's type) and `pub fn gen`

const std = @import("std");
const g = @import("gen.zig");
const reference = @import("reference.zig");
const contract = @import("contract");
const gm = contract.gm;
const gmath = @import("gompute_math");
const sk = @import("std_kernels");
const ok = @import("kernels");
const old = @import("old_text");
const fold_device = @import("fold_device.zig");

const R = g.AnyReal;

const Draw = union(enum) { int: i64, real: f64 };

/// Gompute's documented accuracy (its `math.zig` header) for each function
/// where it differs from gm; a function absent here is not settled.
const bounds = std.StaticStringMap(f64).initComptime(.{
    .{ "cosh", 0.998 },
    .{ "sinh", 1.75 },
    // "<= 2 ulp vs glibc (log10's slack is glibc's own)"
    .{ "log10", 2.0 },
    // gm's atan2, which Gompute's is bit for bit: "under 2 ulp" (VD-123,
    // contract/gm.zig).
    .{ "atan2", 2.0 },
});

pub fn run(rep: *g.Report) void {
    scalar(rep);
    vector(rep);
    folds(rep);
    ac(rep);
}

/// The f128 reference's verdict on `name` at `x` (and `y`) between the old
/// value and the new: null when the reference has no value there or the
/// function has no documented bound.
pub fn judgeAt(comptime name: []const u8, x: f64, y: f64, old_v: f64, new_v: f64) ?g.Judgement {
    const q = reference.of(name, x, y) orelse return null;
    return .{ .old_err = reference.ulpErr(old_v, q), .new_err = reference.ulpErr(new_v, q), .bound = bounds.get(name) orelse return null };
}

// ---- private ----

fn scalar(rep: *g.Report) void {
    const m = sk.math;
    cmpRef(rep, "exp", gm.exp, m.exp, .{g.Real(-750, 750)});
    cmpRef(rep, "log", gm.log, m.log, .{g.Real(1e-300, 1e300)});
    cmpRef(rep, "pow", gm.pow, m.pow, .{ g.Real(-1e3, 1e3), g.Real(-40, 40) });
    cmpRef(rep, "sin", gm.sin, m.sin, .{g.Real(-1e6, 1e6)});
    cmpRef(rep, "cos", gm.cos, m.cos, .{g.Real(-1e6, 1e6)});
    cmpRef(rep, "tan", gm.tan, m.tan, .{g.Real(-1e6, 1e6)});
    cmpRef(rep, "tanh", gm.tanh, m.tanh, .{g.Real(-40, 40)});
    cmpRef(rep, "sinh", gm.sinh, m.sinh, .{g.Real(-720, 720)});
    cmpRef(rep, "cosh", gm.cosh, m.cosh, .{g.Real(-720, 720)});
    cmpRef(rep, "expm1", gm.expm1, m.expm1, .{g.Real(-40, 710)});
    cmpRef(rep, "log1p", gm.log1p, m.log1p, .{g.Real(-1, 1e10)});
    cmpRef(rep, "atan", gm.atan, m.atan, .{g.Real(-1e10, 1e10)});
    cmpRef(rep, "log10", gm.log10, m.log10, .{g.Real(1e-300, 1e300)});
    cmpRef(rep, "asinh", gm.asinh, m.asinh, .{g.Real(-1e300, 1e300)});
    cmpRef(rep, "acosh", gm.acosh, m.acosh, .{g.Real(1, 1e300)});
    cmpRef(rep, "atanh", gm.atanh, m.atanh, .{g.Real(-1, 1)});
    cmpRef(rep, "atan2", gm.atan2, m.atan2, .{ g.Real(-1e3, 1e3), g.Real(-1e3, 1e3) });
}

/// The vector forms `RefFamily` and a batch family call: lane for lane the
/// scalar's bits on both sides, so any difference is the scalar's.
fn vector(rep: *g.Report) void {
    const V = @Vector(4, f64);
    const Vec = struct {
        pub const T = V;
        pub fn gen(r: g.Rng, i: usize) V {
            var v: V = undefined;
            inline for (0..4) |k| v[k] = R.gen(r, if (i < g.specials.len) (i + k) % g.specials.len else i);
            return v;
        }
    };
    const f = struct {
        fn powO(x: V, y: f64) V {
            return gm.powV(x, y);
        }
        fn powN(x: V, y: f64) V {
            return gmath.pow(x, @as(V, @splat(y)));
        }
    };
    g.cmp(rep, "exp.vec4", gm.hexp, gmath.exp, .{}, .{Vec});
    g.cmp(rep, "log.vec4", gm.hlog, gmath.log, .{}, .{Vec});
    g.cmp(rep, "pow.vec4", f.powO, f.powN, .{}, .{ Vec, g.Real(-40, 40) });
}

/// `g.cmp`, plus each difference judged by the f128 reference of `name`.
fn cmpRef(rep: *g.Report, comptime name: []const u8, comptime old_f: anytype, comptime new_f: anytype, comptime Specs: anytype) void {
    const r = rep.random();
    const n = g.specials.len * g.specials.len + g.random_per_fn;
    for (0..n) |i| {
        const x = Specs[0].gen(r, if (i < g.specials.len * g.specials.len) i % g.specials.len else n);
        const y = if (Specs.len > 1) Specs[1].gen(r, if (i < g.specials.len * g.specials.len) i / g.specials.len else n) else 0;
        const a = if (Specs.len > 1) old_f(x, y) else old_f(x);
        const b = if (Specs.len > 1) new_f(x, y) else new_f(x);
        const d = g.ulps(a, b);
        rep.record(name, d, .{ x, y });
        if (d == 0) continue;
        // atan2's reference takes (y, x) in the call's order.
        rep.judge(name, judgeAt(name, x, y, a, b));
    }
}

fn folds(rep: *g.Report) void {
    const OF = ok.fold;
    const NF = sk.fold;
    const r = rep.random();
    const n = g.random_per_fn;
    inline for (comptime std.enums.values(OF.MathFn)) |f| {
        const nf = @field(NF.MathFn, @tagName(f));
        for (0..n) |i| {
            var oa: [OF.MathFn.arity_max]OF.Const = undefined;
            var na: [NF.MathFn.arity_max]NF.Const = undefined;
            for (0..f.arity()) |k| {
                const c = constDraw(r, i *% 3 +% k);
                oa[k] = switch (c) {
                    .int => |v| .{ .int = v },
                    .real => |v| .{ .real = v },
                };
                na[k] = switch (c) {
                    .int => |v| .{ .int = v },
                    .real => |v| .{ .real = v },
                };
            }
            const a = OF.math(f, oa[0..f.arity()]);
            const b = NF.math(nf, na[0..f.arity()]);
            const d = g.dist(a, b);
            rep.record("fold.math." ++ @tagName(f), d, .{ oa[0], oa[1 % f.arity()] });
            if (d != 0) rep.judge("fold.math." ++ @tagName(f), foldJudge(f, oa[0..f.arity()], a, b));
        }
    }
    inline for (comptime std.enums.values(OF.UnaryOp)) |op| {
        for (0..n) |i| {
            const c = constDraw(r, i);
            const a = OF.unary(op, oldConst(c));
            const b = NF.unary(@field(NF.UnaryOp, @tagName(op)), newConst(c));
            rep.record("fold.unary." ++ @tagName(op), g.dist(a, b), .{c});
        }
    }
    inline for (comptime std.enums.values(OF.BinaryOp)) |op| {
        for (0..n) |i| {
            const c0 = constDraw(r, i);
            const c1 = constDraw(r, i +% 1);
            const signed: ?bool = switch (r.uintLessThan(u8, 3)) {
                0 => null,
                1 => true,
                else => false,
            };
            const a = OF.binary(op, oldConst(c0), oldConst(c1), signed);
            const b = NF.binary(@field(NF.BinaryOp, @tagName(op)), newConst(c0), newConst(c1), signed);
            rep.record("fold.binary." ++ @tagName(op), g.dist(a, b), .{ c0, c1 });
        }
    }
    g.cmp(rep, "fold.wrap32", OF.wrap32, NF.wrap32, .{}, .{g.Of(i64)});
    g.cmp(rep, "fold.ipow32", OF.ipow32, NF.ipow32, .{}, .{ g.Int(i64, -1000, 1000), g.Int(i64, -40, 40) });
    g.cmp(rep, "fold.clog2", OF.clog2, NF.clog2, .{}, .{ g.Of(i64), g.Int(u32, 1, 200) });
}

/// A fold's difference judged as its function: VAMS `log` is base 10, and
/// an integer operand is its real value; null for any other function or a
/// non-real answer.
fn foldJudge(comptime f: ok.fold.MathFn, args: []const ok.fold.Const, a: ?ok.fold.Const, b: ?sk.fold.Const) ?g.Judgement {
    for (args) |c| if (c == .str) return null;
    const x = args[0].asReal();
    const y = if (args.len > 1) args[1].asReal() else 0;
    const name = switch (f) {
        .cosh => "cosh",
        .sinh => "sinh",
        .log => "log10",
        // A fold that now gives the device's value (lib/TODO.md §7).
        .abs => return byDevice(.fabs, x, y, a, b),
        else => return null,
    };
    const av = a orelse return null;
    const bv = b orelse return null;
    if (av != .real or bv != .real) return null;
    return judgeAt(name, x, 0, av.real, bv.real);
}

/// A fold difference judged by the device (`fold_device.value`): the new
/// fold settles it by equalling the device's value where the old does not
/// (0 or 1 "ulp", bound 0); null for a non-real answer.
fn byDevice(comptime t: @import("air").Inst.Tag, x: f64, y: f64, a: anytype, b: ?sk.fold.Const) ?g.Judgement {
    const av = a orelse return null;
    const bv = b orelse return null;
    if (av != .real or bv != .real) return null;
    const dev = fold_device.value(t, x, y);
    const err = struct {
        fn of(v: f64, want: f64) f64 {
            return if (same(v, want) and std.math.signbit(v) == std.math.signbit(want)) 0 else 1;
        }
    }.of;
    return .{ .old_err = err(av.real, dev), .new_err = err(bv.real, dev), .bound = 0 };
}

/// Equal, or both NaN.
fn same(x: f64, y: f64) bool {
    return x == y or (std.math.isNan(x) and std.math.isNan(y));
}

/// A fold operand: one in four an integer (its specials first), else a real.
fn constDraw(r: g.Rng, i: usize) Draw {
    if (r.uintLessThan(u8, 4) == 0) return .{ .int = g.Int(i64, std.math.minInt(i64), std.math.maxInt(i64)).gen(r, i) };
    return .{ .real = R.gen(r, if (i < g.specials.len) i else i +% g.specials.len) };
}

fn oldConst(c: Draw) ok.fold.Const {
    return switch (c) {
        .int => |v| .{ .int = v },
        .real => |v| .{ .real = v },
    };
}

fn newConst(c: Draw) sk.fold.Const {
    return switch (c) {
        .int => |v| .{ .int = v },
        .real => |v| .{ .real = v },
    };
}

/// The small-signal family, old (`ac_fam_txt`'s `zAc`) against new (`Ac`),
/// at the unknown count `kernels_text.zig` compiled the old one at, each
/// operation on the same lanes; and the operators' H(jω) kernels over it.
fn ac(rep: *g.Report) void {
    const OT = old.zAc(f64).T;
    const New = sk.ac.Ac(old.n_u, f64);
    const NT = New.T;
    comptime std.debug.assert(@sizeOf(OT) == @sizeOf(NT));
    const S = struct {
        var omega: f64 = 2.0 * std.math.pi * 1e3;
        const Spec = struct {
            pub const T = NT;
            pub fn gen(r: g.Rng, i: usize) NT {
                var t: NT = .{ .v = R.gen(r, i), .w = if (r.boolean()) &omega else null };
                for (&t.d, 0..) |*d, k| d.* = g.Real(-10, 10).gen(r, i +% k);
                return t;
            }
        };
        fn o(a: NT) OT {
            return .{ .v = a.v, .d = a.d, .w = a.w };
        }
        fn U(comptime name: []const u8) type {
            return struct {
                fn old_(a: NT) OT {
                    return @field(OT, name)(o(a));
                }
                fn new_(a: NT) NT {
                    return @field(NT, name)(a);
                }
            };
        }
        fn B(comptime name: []const u8) type {
            return struct {
                fn old_(a: NT, b: NT) OT {
                    return @field(OT, name)(o(a), o(b));
                }
                fn new_(a: NT, b: NT) NT {
                    return @field(NT, name)(a, b);
                }
            };
        }
        fn C(comptime name: []const u8) type {
            return struct {
                fn old_(a: NT, c: f64) OT {
                    return @field(OT, name)(o(a), c);
                }
                fn new_(a: NT, c: f64) NT {
                    return @field(NT, name)(a, c);
                }
            };
        }
    };
    inline for (.{ "exp", "log", "expm1", "log1p", "sqrt", "sin", "cos", "tanh", "atan", "neg" }) |f|
        g.cmp(rep, "ac.Ac." ++ f, S.U(f).old_, S.U(f).new_, .{}, .{S.Spec});
    // sinh and cosh: the value is the function's, each lane the input lane
    // times the other one (`map`); both judged by the reference, and each
    // side's lanes held to its own factor bit for bit.
    inline for (.{ .{ "sinh", "cosh" }, .{ "cosh", "sinh" } }) |fc| {
        const J = struct {
            fn judge(args: struct { NT }, o: OT, n: NT) ?g.Judgement {
                const a = args[0];
                const oc = @field(gm, fc[1])(a.v);
                const nc = @field(sk.math, fc[1])(a.v);
                for (a.d, o.d, n.d) |d, od, nd| if (!same(od, d * oc) or !same(nd, d * nc)) return null;
                return g.both(judgeAt(fc[0], a.v, 0, o.v, n.v), if (oc == nc) g.Judgement{ .old_err = 0, .new_err = 0, .bound = 0 } else judgeAt(fc[1], a.v, 0, oc, nc));
            }
        };
        g.cmpJudged(rep, "ac.Ac." ++ fc[0], S.U(fc[0]).old_, S.U(fc[0]).new_, .{}, .{S.Spec}, J.judge);
    }
    inline for (.{ "add", "sub", "mul", "div", "lt", "le", "eq" }) |f|
        g.cmp(rep, "ac.Ac." ++ f, S.B(f).old_, S.B(f).new_, .{}, .{ S.Spec, S.Spec });
    inline for (.{ "pow", "scale", "addC" }) |f|
        g.cmp(rep, "ac.Ac." ++ f, S.C(f).old_, S.C(f).new_, .{}, .{ S.Spec, R });
    // The operators over one shared kernel scalar whose lanes are `Ac`'s.
    const KA = sk.family.Family(old.n_u, ~@as(u64, 0)).zL(New, 1);
    const KSpec = struct {
        pub const T = KA;
        pub fn gen(r: g.Rng, i: usize) KA {
            return .{ .v = S.Spec.gen(r, i) };
        }
    };
    const Sec2 = struct {
        pub const T = [2][2][3]f64;
        pub fn gen(r: g.Rng, i: usize) T {
            var s: T = undefined;
            for (&s, 0..) |*a, k| for (a, 0..) |*b, l| for (b, 0..) |*c, j| {
                c.* = g.Real(-10, 10).gen(r, i +% (k * 6 + l * 3 + j));
            };
            return s;
        }
    };
    const H0 = struct {
        pub const T = [2][2]f64;
        pub fn gen(r: g.Rng, i: usize) T {
            return .{ .{ R.gen(r, i), R.gen(r, i +% 1) }, .{ R.gen(r, i +% 2), R.gen(r, i +% 3) } };
        }
    };
    const kind = struct {
        pub const T = contract.AnalysisKind;
        pub fn gen(r: g.Rng, i: usize) T {
            return g.Of(contract.AnalysisKind).gen(r, i);
        }
    };
    g.cmp(rep, "ac.zSs", old.zSs, sk.ac.zSs, .{KA}, .{ kind, KSpec });
    g.cmp(rep, "ac.zAcDelay", old.zAcDelay, sk.ac.zAcDelay, .{KA}, .{ KSpec, R });
    g.cmp(rep, "ac.zAcLaplace", old.zAcLaplace, sk.ac.zAcLaplace, .{ KA, 2, 2 }, .{ KSpec, Sec2, H0 });
    g.cmp(rep, "ac.zAcZi", old.zAcZi, sk.ac.zAcZi, .{ KA, 2, 2 }, .{ KSpec, Sec2, g.Real(1e-9, 1) });
}
